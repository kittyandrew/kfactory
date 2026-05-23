// `kfactory tick <ref>` -- idempotent dispatch. Two shapes:
//
//   - Scheduled: `/etc/kfactory/scheduled/<ref>.json` exists. The
//     config (repo, mode, initial_prompt, continuation_prompt) drives
//     find-or-create of the workspace (slug suffix = task-id, so
//     create is idempotent), then ALWAYS picks up the existing root
//     session when the workspace exists; mode decides WHETHER to
//     dispatch the continuation prompt.
//
//   - Ad-hoc: ref doesn't match a scheduled config; operator passes
//     `--prompt TEXT` to inject into an existing workspace's session.
//     Recovery path -- opencode-serve restarted, ping a mid-flight
//     workspace to resume.
//
// Scheduled mode semantics (all three CREATE when the workspace
// doesn't exist; the mode only matters when one already does):
//   - skip-if-exists: workspace exists -> no-op (stdout = id, no
//     prompt dispatched). Useful for "set up once, leave it alone."
//   - skip-if-dirty (DEFAULT): workspace exists + git working tree
//     clean -> dispatch continuation. Dirty -> no-op. Protects
//     uncommitted work from being clobbered by the next prompt.
//   - continue: workspace exists -> always dispatch the continuation.
//     Equivalent to the previous behavior; no safety net.
//
// JSON schema is owned by THIS file. Required: repo, initial_prompt.
// Optional: mode ("skip-if-exists" | "skip-if-dirty" | "continue";
// default "skip-if-dirty"), continuation_prompt (defaults to
// initial_prompt).
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

type scheduledTaskConfig struct {
	Repo               string `json:"repo"`
	Mode               string `json:"mode,omitempty"`
	InitialPrompt      string `json:"initial_prompt"`
	ContinuationPrompt string `json:"continuation_prompt,omitempty"`
}

// KFACTORY_SCHEDULED_DIR wins for tests; NixOS module hardcodes
// /etc/kfactory/scheduled.
func scheduledConfigDir() string {
	if d := os.Getenv("KFACTORY_SCHEDULED_DIR"); d != "" {
		return d
	}
	return "/etc/kfactory/scheduled"
}

// Matches the kfactory-adapter SLUG_RE's 4-hex suffix end-to-end.
// CLI-side check fails fast vs silent slugSuffix-dropped fallback +
// downstream configure() assert.
//
// @WARNING: pure-numeric task-ids like "0001"/"1234" collide with
// findWorkspace's 1-based-index path: if the scheduled config is
// missing and the operator passes --prompt, the ref falls through to
// resolveWorkspace where `strconv.Atoi("0001") = 1` resolves as
// INDEX 1, not as a slug suffix. Use the full id (`wrk_...`) or full
// slug to disambiguate.
var taskIDPattern = regexp.MustCompile(`^[a-f0-9]{4}$`)

func runTick(args []string) {
	var (
		ref    string
		prompt string
	)

	// `--prompt` is required for ad-hoc, ignored for scheduled (config
	// owns prompts + mode).
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

	// Shape-based branch (regex precheck here, loader does pure I/O):
	// without it, a 3-hex typo `aaa3` would route to ad-hoc with a
	// misleading downstream error rather than failing here.
	if taskIDPattern.MatchString(ref) {
		cfg, err := loadScheduledConfig(ref)
		switch {
		case err == nil:
			tickScheduled(ctx, tok, server, ref, cfg)
			return
		case errors.Is(err, fs.ErrNotExist):
			// Looks like a task-id but no config -- fall through to
			// ad-hoc (operator may be ticking a workspace whose slug
			// happens to be 4-hex).
		default:
			fail("tick: read config: %v", err)
		}
	}

	if prompt == "" {
		fail("tick: --prompt is required for ad-hoc tick (ref %q does not match a scheduled task config at %s)",
			ref, scheduledConfigDir())
	}
	tickAdhoc(ctx, tok, server, ref, prompt)
}

func scheduledConfigPath(taskID string) string {
	return filepath.Join(scheduledConfigDir(), taskID+".json")
}

// Returns fs.ErrNotExist via errors.Is for missing file (caller
// distinguishes from real I/O errors). Pure file I/O -- taskID-shape
// precheck lives in runTick.
func loadScheduledConfig(taskID string) (*scheduledTaskConfig, error) {
	path := scheduledConfigPath(taskID)
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var cfg scheduledTaskConfig
	// DisallowUnknownFields: NixOS module + this struct form one
	// schema contract; a camelCase/snake_case typo must fail loudly.
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
		cfg.Mode = "skip-if-dirty"
	}
	switch cfg.Mode {
	case "skip-if-exists", "skip-if-dirty", "continue":
		// ok
	default:
		return nil, fmt.Errorf("%s: invalid mode %q (skip-if-exists|skip-if-dirty|continue)", path, cfg.Mode)
	}
	if cfg.ContinuationPrompt == "" {
		cfg.ContinuationPrompt = cfg.InitialPrompt
	}
	return &cfg, nil
}

// kfactory-adapter mints scheduled-task workspaces with task-id as the
// slug suffix via extra.slugSuffix; this is the canonical existence
// check.
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
	// Two concurrent ticks of the same task-id (timer vs operator,
	// recovery-sweep vs scheduled fire) can each see existing==nil and
	// both call createWorkspaceWithSuffix -- the kfactory-adapter
	// allows duplicate slug-suffix workspaces. Sort by id ascending so
	// findWorkspaceBySuffix consistently returns the OLDEST match, and
	// every subsequent tick targets the same workspace.
	sortWorkspaces(all)
	existing := findWorkspaceBySuffix(all, taskID)

	// All three modes mint the workspace when missing + fire
	// initial_prompt. Mode only matters when a workspace already
	// exists for this task-id.
	if existing == nil {
		fmt.Fprintf(os.Stderr, "kfactory: tick %s creating workspace for %s\n", taskID, cfg.Repo)
		ws, err := createWorkspaceWithSuffix(ctx, tok, server, cfg.Repo, taskID)
		if err != nil {
			fail("tick: create workspace: %v", err)
		}
		fmt.Fprintf(os.Stderr, "kfactory: tick %s workspace %s (%s)\n", taskID, ws.ID, ws.Name)
		dispatchSessionAndPrompt(ctx, tok, server, ws.ID, cfg.InitialPrompt)
		return
	}

	switch cfg.Mode {
	case "skip-if-exists":
		fmt.Fprintf(os.Stderr,
			"kfactory: tick %s skipped (workspace %s exists, mode=skip-if-exists)\n",
			taskID, existing.ID)
		// stdout stays uniform for machine consumers (`$(kfactory tick X)`).
		fmt.Println(existing.ID)
		return
	case "skip-if-dirty":
		// `dirty` is enriched server-side per request via the
		// opencode-workspace-branch patch (same pattern as branch):
		// the opencode-serve host shells `git status --porcelain`
		// against the workspace directory at list time. A nil/null
		// Dirty (broken probe, missing .git, non-git workspace) is
		// fail-CLOSED -- treat as dirty so we don't dispatch over
		// work whose state we can't confirm.
		if existing.Dirty == nil {
			fmt.Fprintf(os.Stderr,
				"kfactory: tick %s skipped (workspace %s dirty-check returned no signal; treating as dirty)\n",
				taskID, existing.ID)
			fmt.Println(existing.ID)
			return
		}
		if *existing.Dirty {
			fmt.Fprintf(os.Stderr,
				"kfactory: tick %s skipped (workspace %s dirty, mode=skip-if-dirty)\n",
				taskID, existing.ID)
			fmt.Println(existing.ID)
			return
		}
		// Clean -> fall through to dispatch.
	case "continue":
		// Unconditional dispatch into the existing workspace.
	}

	postContinuation(ctx, tok, server,
		existing.ID,
		cfg.ContinuationPrompt,
		fmt.Sprintf("tick %s ", taskID),
		// Workspace exists but never had a turn (prior tick failed
		// mid-create): open a fresh session in the EXISTING workspace.
		func() {
			fmt.Fprintf(os.Stderr,
				"kfactory: tick %s workspace %s has no root session; opening session in existing workspace\n",
				taskID, existing.ID)
			dispatchSessionAndPrompt(ctx, tok, server, existing.ID, cfg.InitialPrompt)
		},
	)
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

// Resolves the ref and posts --prompt to the most-recent root session.
// No workspace creation; unresolvable ref is a hard error.
func tickAdhoc(ctx context.Context, tok *tokenFile, server, ref, prompt string) {
	ws, err := resolveWorkspace(ctx, tok, server, ref)
	if err != nil {
		fail("tick: %v", err)
	}
	postContinuation(ctx, tok, server,
		ws.ID,
		prompt,
		"(ad-hoc) ",
		// No "fresh" fallback -- ad-hoc refuses if there's nothing to
		// recover into (silently creating a session isn't safe).
		func() {
			fail("tick: workspace %s has no root session to post into (use `kfactory dispatch` to start one)", ws.ID)
		},
	)
}

// Shared by scheduled-continue + ad-hoc. Differs only on the no-root-
// session fallback (caller-supplied). `logTag` prepends the stderr
// progress log. On success prints workspace ID to stdout; onNoSession
// callers handle their own stdout.
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
