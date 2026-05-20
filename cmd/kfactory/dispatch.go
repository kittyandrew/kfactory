// `kfactory dispatch <repo-url> <prompt...>` is the autonomous-launch shape:
// create a workspace for the github repo, open a fresh session, fire the
// prompt at it asynchronously. kfactory returns as soon as the prompt is
// accepted (the model loop runs server-side; close kfactory, walk away).
//
// To watch the agent: `kfactory attach <id>` (always adds --continue, so it
// drops into the just-dispatched session).
//
// Both args are required. Empty prompts are rejected: dispatch without a
// prompt has no use case in this CLI's UX -- if you want a bare workspace
// to poke at via the SPA, hit opencode's /experimental/workspace
// endpoint directly.
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

	// Clone is the slow step (~5-10s for a fresh repo). prompt_async
	// returns immediately after the message is queued; the model loop
	// runs server-side in the background.
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
	// stdout = workspace id so callers can pipe it.
	fmt.Println(ws.ID)
}
