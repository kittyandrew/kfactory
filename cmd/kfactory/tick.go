// `kfactory tick <ref>` is idempotent dispatch.
//
// Scheduled: `/etc/kfactory/scheduled/<id>.json` drives repo, mode,
// initial_prompt, continuation_prompt, and stable workspace ID
// `wrk_kfactory_<id>`. Missing or incomplete first runs always
// create/repair with initial_prompt before mode-specific continuation.
//
// Ad-hoc: no scheduled config exists; `--prompt TEXT` posts to an
// existing workspace ID or 4-hex slug suffix. It never creates workspaces.
//
// Modes after first-run completion:
//   - skip-if-exists: no-op; print workspace ID.
//   - skip-if-dirty: continue only when git status is clean.
//   - continue: always continue; no dirty-worktree guard.
//
// JSON schema owner: scheduledTaskConfig below.
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"syscall"
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

// Scheduled task IDs are embedded in stable workspace IDs.
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
					"  - ad-hoc:    <ref> is a workspace ID or 4-hex slug suffix; --prompt is required\n")
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

	// Route task-shaped refs before ad-hoc recovery so scheduled-task
	// mistakes fail against their config instead of a workspace lookup.
	if taskIDPattern.MatchString(ref) {
		cfg, err := loadScheduledConfig(ref)
		switch {
		case err == nil:
			ctx, cancel := context.WithTimeout(context.Background(), 3*time.Minute)
			defer cancel()
			tok, err := ensureFresh(ctx)
			if err != nil {
				failAuth(err)
			}
			server := serverFor(tok)
			run, err := acquireScheduledTaskRun(ref)
			if err != nil {
				fail("tick: acquire scheduled-task run: %v", err)
			}
			defer run.Close()
			if run.waited {
				progress, err := readScheduledTaskProgress(ctx, tok, server, ref)
				if err != nil {
					fail("tick: inspect scheduled-task progress: %v", err)
				}
				if progress.firstRunComplete {
					printOverlappingTickSuccess(ref, progress.workspaceID)
					return
				}
			}
			workspaceID := tickScheduled(ctx, tok, server, ref, cfg)
			if workspaceID == "" {
				fail("tick: scheduled task %s completed without workspace id", ref)
			}
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
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Minute)
	defer cancel()
	tok, err := ensureFresh(ctx)
	if err != nil {
		failAuth(err)
	}
	server := serverFor(tok)
	tickAdhoc(ctx, tok, server, ref, prompt)
}

func scheduledConfigPath(taskID string) string {
	return filepath.Join(scheduledConfigDir(), taskID+".json")
}

func scheduledLockDir() (string, error) {
	if lockDir := os.Getenv("KFACTORY_LOCK_DIR"); lockDir != "" {
		return lockDir, nil
	}
	cacheDir, err := os.UserCacheDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(cacheDir, "kfactory", "locks"), nil
}

func scheduledLockPath(taskID string) (string, error) {
	lockDir, err := scheduledLockDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(lockDir, "tick-"+taskID+".lock"), nil
}

type scheduledTaskRun struct {
	file   *os.File
	waited bool
}

func acquireScheduledTaskRun(taskID string) (*scheduledTaskRun, error) {
	lockDir, err := scheduledLockDir()
	if err != nil {
		return nil, err
	}
	if err := os.MkdirAll(lockDir, 0o700); err != nil {
		return nil, err
	}
	if err := os.Chmod(lockDir, 0o700); err != nil {
		return nil, err
	}
	lockPath, err := scheduledLockPath(taskID)
	if err != nil {
		return nil, err
	}
	f, err := os.OpenFile(lockPath, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, err
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err == nil {
		return &scheduledTaskRun{file: f}, nil
	} else if !errors.Is(err, syscall.EWOULDBLOCK) && !errors.Is(err, syscall.EAGAIN) {
		_ = f.Close()
		return nil, err
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX); err != nil {
		_ = f.Close()
		return nil, err
	}
	return &scheduledTaskRun{file: f, waited: true}, nil
}

func (r *scheduledTaskRun) Close() {
	_ = syscall.Flock(int(r.file.Fd()), syscall.LOCK_UN)
	_ = r.file.Close()
}

type scheduledTaskProgress struct {
	workspaceID      string
	rootSessionID    string
	firstRunComplete bool
}

func readScheduledTaskProgress(ctx context.Context, tok *tokenFile, server, taskID string) (scheduledTaskProgress, error) {
	all, err := listWorkspaces(ctx, tok, server)
	if err != nil {
		return scheduledTaskProgress{}, err
	}
	existing := findWorkspaceByID(all, scheduledWorkspaceID(taskID))
	if existing == nil {
		return scheduledTaskProgress{}, nil
	}
	progress := scheduledTaskProgress{workspaceID: existing.ID}
	sess, err := findMostRecentSession(ctx, tok, server, existing.ID)
	if err != nil {
		return progress, err
	}
	if sess == nil {
		return progress, nil
	}
	progress.rootSessionID = sess.ID
	complete, err := sessionHasUserPrompt(ctx, tok, server, existing.ID, sess.ID)
	if err != nil {
		return progress, err
	}
	progress.firstRunComplete = complete
	return progress, nil
}

func scheduledWorkspaceFirstRunComplete(ctx context.Context, tok *tokenFile, server, workspaceID string) (bool, error) {
	sess, err := findMostRecentSession(ctx, tok, server, workspaceID)
	if err != nil {
		return false, err
	}
	if sess == nil {
		return false, nil
	}
	return sessionHasUserPrompt(ctx, tok, server, workspaceID, sess.ID)
}

func sessionHasUserPrompt(ctx context.Context, tok *tokenFile, server, workspaceID, sessionID string) (bool, error) {
	messages, err := listSessionMessages(ctx, tok, server, workspaceID, sessionID)
	if err != nil {
		return false, err
	}
	for _, msg := range messages {
		if msg.Info.Role == "user" && strings.TrimSpace(sessionMessageText(msg)) != "" {
			return true, nil
		}
	}
	return false, nil
}

// Missing configs return fs.ErrNotExist; task-ID shape validation lives in runTick.
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
	var extra json.RawMessage
	if err := dec.Decode(&extra); err != io.EOF {
		if err == nil {
			return nil, fmt.Errorf("%s: invalid json: multiple json values", path)
		}
		return nil, fmt.Errorf("%s: invalid json: %w", path, err)
	}
	if strings.TrimSpace(cfg.Repo) == "" {
		return nil, fmt.Errorf("%s: missing required field `repo`", path)
	}
	if strings.TrimSpace(cfg.InitialPrompt) == "" {
		return nil, fmt.Errorf("%s: missing required field `initial_prompt`", path)
	}
	if cfg.Mode == "" {
		cfg.Mode = "skip-if-dirty"
	} else if strings.TrimSpace(cfg.Mode) != cfg.Mode {
		return nil, fmt.Errorf("%s: invalid mode %q (skip-if-exists|skip-if-dirty|continue)", path, cfg.Mode)
	}
	switch cfg.Mode {
	case "skip-if-exists", "skip-if-dirty", "continue":
		// ok
	default:
		return nil, fmt.Errorf("%s: invalid mode %q (skip-if-exists|skip-if-dirty|continue)", path, cfg.Mode)
	}
	if cfg.ContinuationPrompt == "" {
		cfg.ContinuationPrompt = cfg.InitialPrompt
	} else if strings.TrimSpace(cfg.ContinuationPrompt) == "" {
		return nil, fmt.Errorf("%s: continuation_prompt must not be whitespace-only", path)
	}
	return &cfg, nil
}

func findWorkspaceByID(workspaces []Workspace, id string) *Workspace {
	for i := range workspaces {
		if workspaces[i].ID == id {
			return &workspaces[i]
		}
	}
	return nil
}

func findUniqueWorkspaceBySuffix(workspaces []Workspace, suffixID string) (*Workspace, error) {
	suffix := "--" + suffixID
	var hits []*Workspace
	for i := range workspaces {
		if strings.HasSuffix(workspaces[i].Name, suffix) {
			hits = append(hits, &workspaces[i])
		}
	}
	switch len(hits) {
	case 0:
		return nil, fmt.Errorf("no workspace has slug suffix %q (expected workspace name ending in %s)", suffixID, suffix)
	case 1:
		return hits[0], nil
	default:
		var names []string
		for _, hit := range hits {
			names = append(names, hit.Name)
		}
		return nil, fmt.Errorf("%d workspaces have slug suffix %q: %s", len(hits), suffixID, strings.Join(names, ", "))
	}
}

func printOverlappingTickSuccess(taskID, workspaceID string) {
	fmt.Fprintf(os.Stderr,
		"kfactory: tick %s skipped (workspace %s already handled by overlapping tick)\n",
		taskID, workspaceID)
	fmt.Println(workspaceID)
}

func tickScheduled(ctx context.Context, tok *tokenFile, server, taskID string, cfg *scheduledTaskConfig) string {
	all, err := listWorkspaces(ctx, tok, server)
	if err != nil {
		fail("tick: list workspaces: %v", err)
	}
	// The per-task lock prevents local create races; stable workspace ID is
	// the scheduled identity, names are display-only.
	sortWorkspaces(all)
	existing := findWorkspaceByID(all, scheduledWorkspaceID(taskID))

	// Missing workspaces always get initial_prompt; mode applies only after that.
	if existing == nil {
		fmt.Fprintf(os.Stderr, "kfactory: tick %s creating workspace for %s\n", taskID, cfg.Repo)
		ws, err := createWorkspaceWithStableID(ctx, tok, server, cfg.Repo, taskID)
		if err != nil {
			fail("tick: create workspace: %v", err)
		}
		fmt.Fprintf(os.Stderr, "kfactory: tick %s workspace %s (%s)\n", taskID, ws.ID, ws.Name)
		return dispatchSessionAndPrompt(ctx, tok, server, ws.ID, cfg.InitialPrompt)
	}
	firstRunComplete, err := scheduledWorkspaceFirstRunComplete(ctx, tok, server, existing.ID)
	if err != nil {
		fail("tick: inspect first-run completion for workspace %s: %v", existing.ID, err)
	}
	if !firstRunComplete {
		fmt.Fprintf(os.Stderr,
			"kfactory: tick %s workspace %s has no completed first run; sending initial prompt\n",
			taskID, existing.ID)
		return postContinuation(ctx, tok, server,
			existing.ID,
			cfg.InitialPrompt,
			fmt.Sprintf("tick %s first-run recovery ", taskID),
			func() string {
				return dispatchSessionAndPrompt(ctx, tok, server, existing.ID, cfg.InitialPrompt)
			},
		)
	}

	switch cfg.Mode {
	case "skip-if-exists":
		fmt.Fprintf(os.Stderr,
			"kfactory: tick %s skipped (workspace %s exists, mode=skip-if-exists)\n",
			taskID, existing.ID)
		// stdout stays uniform for machine consumers (`$(kfactory tick X)`).
		fmt.Println(existing.ID)
		return existing.ID
	case "skip-if-dirty":
		dirty, err := workspaceDirty(ctx, tok, server, existing.ID)
		if err != nil {
			fail("tick: dirty-check for workspace %s failed: %v", existing.ID, err)
		}
		if dirty {
			fmt.Fprintf(os.Stderr,
				"kfactory: tick %s skipped (workspace %s dirty, mode=skip-if-dirty)\n",
				taskID, existing.ID)
			fmt.Println(existing.ID)
			return existing.ID
		}
		// Clean: continue below.
	case "continue":
		// Continue below.
	}

	return postContinuation(ctx, tok, server,
		existing.ID,
		cfg.ContinuationPrompt,
		fmt.Sprintf("tick %s ", taskID),
		// Existing workspace has no root session: repair first-run in place.
		func() string {
			fmt.Fprintf(os.Stderr,
				"kfactory: tick %s workspace %s has no root session; opening session in existing workspace\n",
				taskID, existing.ID)
			return dispatchSessionAndPrompt(ctx, tok, server, existing.ID, cfg.InitialPrompt)
		},
	)
}

func dispatchSessionAndPrompt(ctx context.Context, tok *tokenFile, server, workspaceID, prompt string) string {
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
	return workspaceID
}

// Posts --prompt to an exact workspace ID or 4-hex suffix; never creates.
func tickAdhoc(ctx context.Context, tok *tokenFile, server, ref, prompt string) {
	all, err := listWorkspaces(ctx, tok, server)
	if err != nil {
		fail("tick: list workspaces: %v", err)
	}
	sortWorkspaces(all)
	ws, err := findAdhocWorkspace(all, ref)
	if err != nil {
		fail("tick: %v", err)
	}
	postContinuation(ctx, tok, server,
		ws.ID,
		prompt,
		"(ad-hoc) ",
		// Ad-hoc refuses if there is nothing to recover into.
		func() string {
			fail("tick: workspace %s has no root session to post into (use `kfactory dispatch` to start one)", ws.ID)
			return ""
		},
	)
}

func findAdhocWorkspace(workspaces []Workspace, ref string) (*Workspace, error) {
	for i := range workspaces {
		if workspaces[i].ID == ref {
			return &workspaces[i], nil
		}
	}
	if !taskIDPattern.MatchString(ref) {
		return nil, fmt.Errorf("ad-hoc ref %q must be an exact workspace id or 4-hex slug suffix, not a list index", ref)
	}
	return findUniqueWorkspaceBySuffix(workspaces, ref)
}

// Shared continuation path; caller owns the no-root-session fallback.
func postContinuation(
	ctx context.Context,
	tok *tokenFile,
	server, workspaceID, prompt, logTag string,
	onNoSession func() string,
) string {
	sess, err := findMostRecentSession(ctx, tok, server, workspaceID)
	if err != nil {
		fail("tick: find session for %s: %v", workspaceID, err)
	}
	if sess == nil {
		return onNoSession()
	}
	fmt.Fprintf(os.Stderr,
		"kfactory: %scontinuing in workspace %s session %s\n",
		logTag, workspaceID, sess.ID)
	if err := sendPromptAsync(ctx, tok, server, workspaceID, sess.ID, prompt); err != nil {
		fail("tick: send prompt: %v", err)
	}
	fmt.Println(workspaceID)
	return workspaceID
}
