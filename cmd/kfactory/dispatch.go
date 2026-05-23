// `kfactory dispatch <repo-url> <prompt...>`: create workspace, open
// session, queue prompt; returns once accepted. Operator can `attach
// <id>` to watch (always --continue, lands on the dispatched session).
package main

import (
	"context"
	"fmt"
	"os"
	"strings"
	"time"
)

func runDispatch(args []string) {
	if len(args) < 2 {
		fail("dispatch: usage: kfactory dispatch <repo-url> <prompt...>")
	}
	repoURL := args[0]
	prompt := strings.TrimSpace(strings.Join(args[1:], " "))
	if prompt == "" {
		fail("dispatch: prompt is required (got empty after trim)")
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
