// `kfactory tick <ref>` is the idempotent-dispatch verb: a tick is
// either a scheduled-task fire or an ad-hoc nudge against an existing
// workspace. Dispatch shape is decided by context:
//
//   - If `/etc/kfactory/scheduled/<ref>.json` exists, the ref is a
//     TASK-ID, and the JSON config drives the run (repo, mode,
//     initial-prompt, continuation-prompt). Tick finds or creates the
//     workspace (slug suffix == task-id, so the create is idempotent),
//     then either dispatches the initial prompt (workspace was new),
//     posts the continuation prompt to the most-recent session
//     (workspace existed and mode != skip), or exits 0 silently
//     (workspace existed and mode == skip).
//
//   - If no such config file exists, the ref is a workspace reference
//     (id / slug / index, same as `kfactory attach`), and the operator
//     must pass `--prompt TEXT` to inject. This is the recovery /
//     ad-hoc path: opencode-serve restarted, a workspace had a
//     mid-flight session, ping it to resume.
//
// The schema for /etc/kfactory/scheduled/<id>.json is owned by THIS
// file; the NixOS module that writes these files generates JSON the
// CLI accepts. Required fields: repo, initial_prompt. Optional:
// mode ("continue" | "skip-if-exists" | "fresh"; default "continue"),
// continuation_prompt (string; defaults to initial_prompt).
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

// scheduledTaskConfig is the on-disk JSON shape /etc/kfactory/scheduled/
// <task-id>.json carries. Kept narrow: every consumer (the NixOS
// module, tests, ad-hoc operator-edited files) targets this exact set.
type scheduledTaskConfig struct {
	Repo               string `json:"repo"`
	Mode               string `json:"mode,omitempty"`
	InitialPrompt      string `json:"initial_prompt"`
	ContinuationPrompt string `json:"continuation_prompt,omitempty"`
}

// Scheduled-task config dir. Overridable via env for tests; the NixOS
// module hardcodes /etc/kfactory/scheduled. Env wins so the e2e
// harness can point at a tmpfs without root.
func scheduledConfigDir() string {
	if d := os.Getenv("KFACTORY_SCHEDULED_DIR"); d != "" {
		return d
	}
	return "/etc/kfactory/scheduled"
}

// Task-id must match the EXACT shape of a workspace slug suffix: 4
// lowercase hex chars. The kfactory-adapter's SLUG_RE requires that
// shape end-to-end (random-mint and scheduled-tick paths produce the
// same slug invariant). A CLI-side error here beats a silent
// slugSuffix-dropped fallback at workspace-create time + a
// downstream 500 from the configure() assert.
//
// @WARNING: pure-numeric 4-hex strings like "0001" / "1234" collide
//
//	with findWorkspace's 1-based-index resolution path. If a
//	scheduled config is missing AND the operator passes --prompt for
//	an ad-hoc tick, the ref falls through to resolveWorkspace where
//	`strconv.Atoi("0001") = 1` resolves as INDEX 1 -- NOT as a
//	slug-suffix prefix. Operators who want to nudge a surviving
//	scheduled workspace via ad-hoc tick should use the full id
//	(`wrk_...`) or full slug (`<owner>--<repo>--0001`) instead of
//	the bare 4-hex.
var taskIDPattern = regexp.MustCompile(`^[a-f0-9]{4}$`)

func runTick(args []string) {
	var (
		ref    string
		prompt string
	)

	// Hand-rolled flag parse to match the rest of this CLI (no external
	// arg-parser dep; see CLAUDE.md). `--prompt` is required for the
	// ad-hoc shape and ignored for the scheduled shape (config owns
	// the prompts). Earlier shapes exposed `--continue-prompt` and
	// `--skip-if-exists` as one-way config overrides; both were dropped
	// per ThermoNuclear review F1+F8: the scheduled config file is the
	// single source of truth for mode + prompts; ad-hoc is for
	// recovery/operator nudges only.
	i := 0
	for i < len(args) {
		a := args[i]
		switch {
		case a == "--prompt":
			if i+1 >= len(args) {
				fail("tick: --prompt requires a value")
			}
			prompt = args[i+1]
			i += 2
		case strings.HasPrefix(a, "--prompt="):
			prompt = strings.TrimPrefix(a, "--prompt=")
			i++
		case a == "-h", a == "--help":
			fmt.Fprint(os.Stderr,
				"usage: kfactory tick <task-id|ref> [--prompt TEXT]\n\n"+
					"Idempotent dispatch. Two shapes:\n"+
					"  - scheduled: <task-id> matches a config file under "+scheduledConfigDir()+"/<task-id>.json;\n"+
					"               --prompt is ignored (config drives mode + prompts)\n"+
					"  - ad-hoc:    <ref> is a workspace ref (id|slug|#); --prompt is required\n")
			return
		case strings.HasPrefix(a, "--"):
			fail("tick: unknown flag %q", a)
		default:
			if ref != "" {
				fail("tick: expected a single ref, got %q after %q", a, ref)
			}
			ref = a
			i++
		}
	}
	if ref == "" {
		fail("tick: usage: kfactory tick <task-id|ref> [--prompt TEXT]")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Minute)
	defer cancel()

	tok, err := ensureFresh(ctx)
	if err != nil {
		failAuth(err)
	}
	server := serverFor(tok)

	// Branch on context: scheduled config or ad-hoc. The two paths are
	// distinguished by SHAPE (is the ref a task-id?), not by an
	// fs.ErrNotExist sentinel from the loader -- earlier the loader
	// itself synthesized fs.ErrNotExist for non-matching refs, which
	// conflated "not a task-id" with "file truly missing" and made
	// typos like `aaa3` (3 hex chars) silently route to ad-hoc with a
	// misleading downstream error. Now the regex precheck happens
	// here, the loader does pure file I/O.
	if taskIDPattern.MatchString(ref) {
		cfg, err := loadScheduledConfig(ref)
		switch {
		case err == nil:
			// Scheduled flow. `--prompt` is silently ignored here; the
			// config file IS the schema contract.
			tickScheduled(ctx, tok, server, ref, cfg)
			return
		case errors.Is(err, fs.ErrNotExist):
			// ref looks like a task-id but no config file exists --
			// fall through to ad-hoc (operator may be ticking a
			// workspace whose slug happens to be 4-hex).
		default:
			fail("tick: read config: %v", err)
		}
	}

	// Ad-hoc flow. Operator must pass --prompt; ref must resolve
	// to an existing workspace.
	if prompt == "" {
		fail("tick: --prompt is required for ad-hoc tick (ref %q does not match a scheduled task config at %s)",
			ref, scheduledConfigDir())
	}
	tickAdhoc(ctx, tok, server, ref, prompt)
}

// scheduledConfigPath returns the on-disk path for a task-id. Pure;
// used both to load the file and to report it in error messages.
func scheduledConfigPath(taskID string) string {
	return filepath.Join(scheduledConfigDir(), taskID+".json")
}

// loadScheduledConfig reads + validates the JSON. Returns
// fs.ErrNotExist (unwrapped via errors.Is) when the file is absent --
// caller distinguishes "missing file" from real I/O errors via
// errors.Is. The taskID-shape precheck lives in runTick (so the
// loader's fs.ErrNotExist always means an actual fs absence, never a
// synthesized "ref isn't a task-id" signal).
func loadScheduledConfig(taskID string) (*scheduledTaskConfig, error) {
	path := scheduledConfigPath(taskID)
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var cfg scheduledTaskConfig
	// DisallowUnknownFields so a typo in the NixOS-emitted JSON (e.g.
	// camelCase `continuationPrompt` vs snake_case `continuation_prompt`)
	// is a hard error instead of silently defaulting -- the Nix module
	// and this struct form one schema contract; both halves must be
	// strict.
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&cfg); err != nil {
		return nil, fmt.Errorf("%s: invalid json: %w", path, err)
	}
	if cfg.Repo == "" {
		return nil, fmt.Errorf("%s: missing required field `repo`", path)
	}
	if cfg.InitialPrompt == "" {
		return nil, fmt.Errorf("%s: missing required field `initial_prompt`", path)
	}
	if cfg.Mode == "" {
		cfg.Mode = "continue"
	}
	switch cfg.Mode {
	case "continue", "skip-if-exists", "fresh":
		// ok
	default:
		return nil, fmt.Errorf("%s: invalid mode %q (continue|skip-if-exists|fresh)", path, cfg.Mode)
	}
	// continuation_prompt defaults to initial_prompt -- a task that
	// doesn't differentiate "first time" from "continue" semantics
	// just reuses the same text.
	if cfg.ContinuationPrompt == "" {
		cfg.ContinuationPrompt = cfg.InitialPrompt
	}
	return &cfg, nil
}

// findWorkspaceBySuffix scans the workspace list for one whose Name
// (slug) ends in `--<taskID>`. The kfactory-adapter mints scheduled-
// task workspaces with the task-id AS the slug suffix (passed via
// extra.slugSuffix), so this is the canonical existence check.
// Returns nil if no workspace matches.
//
// `workspaces` MUST be pre-sorted via sortWorkspaces (id ascending =
// creation order). In `fresh` mode, a tick mints a new workspace
// without cleaning up its predecessor -- so multiple workspaces with
// the same `--<task-id>` suffix can accumulate. The sort makes
// "first match" = "oldest workspace with this suffix" deterministic
// instead of relying on the server's unspecified list order.
func findWorkspaceBySuffix(workspaces []Workspace, taskID string) *Workspace {
	suffix := "--" + taskID
	for i := range workspaces {
		if strings.HasSuffix(workspaces[i].Name, suffix) {
			return &workspaces[i]
		}
	}
	return nil
}

func tickScheduled(ctx context.Context, tok *tokenFile, server, taskID string, cfg *scheduledTaskConfig) {
	all, err := listWorkspaces(ctx, tok, server)
	if err != nil {
		fail("tick: list workspaces: %v", err)
	}
	sortWorkspaces(all) // determinism: oldest workspace with the suffix wins on duplicates
	existing := findWorkspaceBySuffix(all, taskID)

	if cfg.Mode == "fresh" {
		// Always mint a new workspace, even if one exists. Operator
		// asked for it; we don't second-guess. The slug suffix is
		// still pinned to taskID so the next tick will find this
		// fresh workspace (the previous one gets orphaned -- operator
		// is expected to `kfactory delete` it).
		dispatchFresh(ctx, tok, server, taskID, cfg)
		return
	}

	if existing == nil {
		dispatchFresh(ctx, tok, server, taskID, cfg)
		return
	}

	// Workspace exists. Branch on mode.
	if cfg.Mode == "skip-if-exists" {
		fmt.Fprintf(os.Stderr,
			"kfactory: tick %s skipped (workspace %s exists, mode=skip-if-exists)\n",
			taskID, existing.ID)
		// F10: print the workspace id on stdout even on skip, so a
		// wrapper that captures `$(kfactory tick foo)` gets a usable
		// reference instead of an empty string. The stderr log
		// distinguishes skip-vs-tick for humans; stdout stays uniform
		// for machine consumers.
		fmt.Println(existing.ID)
		return
	}

	// mode == "continue": post the continuation prompt to the
	// most-recent root session via the shared helper. The "no root
	// session" branch reuses the existing workspace (it's NOT fresh
	// minting -- per F2, the comment must not mislead next reader).
	postContinuation(ctx, tok, server,
		existing.ID,
		cfg.ContinuationPrompt,
		fmt.Sprintf("tick %s ", taskID),
		// onNoSession: workspace exists but never had a turn (prior
		// tick failed mid-create). Open a fresh session in the
		// EXISTING workspace + fire the initial prompt.
		func() {
			fmt.Fprintf(os.Stderr,
				"kfactory: tick %s workspace %s has no root session; opening session in existing workspace\n",
				taskID, existing.ID)
			dispatchSessionAndPrompt(ctx, tok, server, existing.ID, cfg.InitialPrompt)
		},
	)
}

func dispatchFresh(ctx context.Context, tok *tokenFile, server, taskID string, cfg *scheduledTaskConfig) {
	fmt.Fprintf(os.Stderr, "kfactory: tick %s creating workspace for %s\n", taskID, cfg.Repo)
	ws, err := createWorkspaceWithSuffix(ctx, tok, server, cfg.Repo, taskID)
	if err != nil {
		fail("tick: create workspace: %v", err)
	}
	fmt.Fprintf(os.Stderr, "kfactory: tick %s workspace %s (%s)\n", taskID, ws.ID, ws.Name)
	dispatchSessionAndPrompt(ctx, tok, server, ws.ID, cfg.InitialPrompt)
}

func dispatchSessionAndPrompt(ctx context.Context, tok *tokenFile, server, workspaceID, prompt string) {
	sess, err := createSession(ctx, tok, server, workspaceID)
	if err != nil {
		fail("tick: create session: %v\n"+
			"       workspace %s exists but no session attached.",
			err, workspaceID)
	}
	if err := sendPromptAsync(ctx, tok, server, workspaceID, sess.ID, prompt); err != nil {
		fail("tick: send prompt: %v\n"+
			"       workspace %s + session %s exist but no prompt was queued.",
			err, workspaceID, sess.ID)
	}
	fmt.Println(workspaceID)
}

// tickAdhoc handles the recovery / ad-hoc shape: operator passes a
// workspace ref + `--prompt`, we resolve the workspace + post to its
// most-recent root session. No workspace creation here; if the ref
// doesn't resolve, that's a hard error (operator gave us the wrong id).
func tickAdhoc(ctx context.Context, tok *tokenFile, server, ref, prompt string) {
	ws, err := resolveWorkspace(ctx, tok, server, ref)
	if err != nil {
		fail("tick: %v", err)
	}
	postContinuation(ctx, tok, server,
		ws.ID,
		prompt,
		"(ad-hoc) ",
		// onNoSession: ad-hoc has no "fresh" fallback -- if there's
		// no root session, the workspace was created but never had a
		// turn, so there's nothing to recover into. Refuse instead of
		// silently creating one; ad-hoc is supposed to be safe.
		func() {
			fail("tick: workspace %s has no root session to post into (use `kfactory dispatch` to start one)", ws.ID)
		},
	)
}

// postContinuation resolves the most-recent root session for the
// workspace and posts `prompt` to it. The two scheduled-continue and
// ad-hoc paths share this body; they differ only on what to do when
// no root session exists, which the caller supplies via `onNoSession`.
//
// `logTag` is a short string prepended to the stderr progress log
// (e.g. "tick <task-id> " for scheduled, "(ad-hoc) " for ad-hoc).
// On success, prints the workspace ID to stdout -- callers that take
// a non-default no-session branch (`onNoSession` returns) handle their
// own stdout output.
func postContinuation(
	ctx context.Context,
	tok *tokenFile,
	server, workspaceID, prompt, logTag string,
	onNoSession func(),
) {
	sess, err := findMostRecentSession(ctx, tok, server, workspaceID)
	if err != nil {
		fail("tick: find session for %s: %v", workspaceID, err)
	}
	if sess == nil {
		onNoSession()
		return
	}
	fmt.Fprintf(os.Stderr,
		"kfactory: %scontinuing in workspace %s session %s\n",
		logTag, workspaceID, sess.ID)
	if err := sendPromptAsync(ctx, tok, server, workspaceID, sess.ID, prompt); err != nil {
		fail("tick: send prompt: %v", err)
	}
	fmt.Println(workspaceID)
}
