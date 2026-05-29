// `kfactory dispatch <repo-url> <prompt...>`: create workspace, open
// session, queue prompt; returns once accepted. Operator can `attach
// <id>` to watch (always --continue, lands on the dispatched session).
package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
	"unicode"
)

func runDispatch(args []string) {
	if len(args) < 2 {
		fail("dispatch: usage: kfactory dispatch <repo-url> <prompt...>")
	}
	repoURL := args[0]
	prompt, err := resolveDispatchPrompt(args[1:])
	if err != nil {
		fail("dispatch: %v", err)
	}

	// 3min budget mostly for the clone step (~5-10s for a fresh repo).
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Minute)
	defer cancel()

	tok, err := ensureFresh(ctx)
	if err != nil {
		failAuth(err)
	}
	server := serverFor(tok)

	fmt.Fprintf(os.Stderr, "kfactory: creating workspace for %s\n", repoURL)
	ws, err := createWorkspace(ctx, tok, server, repoURL)
	if err != nil {
		fail("dispatch: create workspace: %v", err)
	}
	fmt.Fprintf(os.Stderr, "kfactory: workspace %s (%s)\n", ws.ID, ws.Name)

	fmt.Fprintf(os.Stderr, "kfactory: opening session\n")
	sess, err := createSession(ctx, tok, server, ws.ID)
	if err != nil {
		fail("dispatch: create session: %v\n"+
			"       workspace %s was created but no session attached.\n"+
			"       clean it up with: kfactory delete %s",
			err, ws.ID, ws.ID)
	}
	fmt.Fprintf(os.Stderr, "kfactory: session %s\n", sess.ID)

	fmt.Fprintf(os.Stderr, "kfactory: sending prompt (async)\n")
	if err := sendPromptAsync(ctx, tok, server, ws.ID, sess.ID, prompt); err != nil {
		fail("dispatch: send prompt: %v\n"+
			"       workspace %s + session %s exist but no prompt was queued.\n"+
			"       you can attach and re-send, or delete with: kfactory delete %s",
			err, ws.ID, sess.ID, ws.ID)
	}

	fmt.Fprintf(os.Stderr, "kfactory: dispatched. attach with: kfactory attach %s\n", ws.ID)
	fmt.Println(ws.ID) // stdout = workspace id (pipeable)
}

func resolveDispatchPrompt(args []string) (string, error) {
	if len(args) == 1 && isDispatchPromptPath(args[0]) {
		path, err := expandPromptPath(args[0])
		if err != nil {
			return "", err
		}
		abs, err := filepath.Abs(path)
		if err != nil {
			return "", err
		}
		info, err := os.Stat(abs)
		switch {
		case err == nil && info.IsDir():
			return "", fmt.Errorf("prompt path is a directory: %s", abs)
		case err == nil:
			body, err := os.ReadFile(abs)
			if err != nil {
				return "", fmt.Errorf("read prompt file %s: %w", abs, err)
			}
			prompt := strings.TrimSpace(string(body))
			if prompt == "" {
				return "", fmt.Errorf("prompt is required (file %s is empty after trim)", abs)
			}
			return prompt, nil
		case errors.Is(err, os.ErrNotExist):
			return "", fmt.Errorf("no such file: %s. was that supposed to be a prompt?", abs)
		default:
			return "", fmt.Errorf("stat prompt file %s: %w", abs, err)
		}
	}

	prompt := strings.TrimSpace(strings.Join(args, " "))
	if prompt == "" {
		return "", fmt.Errorf("prompt is required (got empty after trim)")
	}
	return prompt, nil
}

func isDispatchPromptPath(arg string) bool {
	if strings.ContainsFunc(arg, unicode.IsSpace) {
		return false
	}
	return strings.HasPrefix(arg, "./") ||
		strings.HasPrefix(arg, "../") ||
		strings.HasPrefix(arg, "/") ||
		strings.HasPrefix(arg, "~/")
}

func expandPromptPath(path string) (string, error) {
	if !strings.HasPrefix(path, "~/") {
		return path, nil
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("expand %s: %w", path, err)
	}
	return filepath.Join(home, path[2:]), nil
}
