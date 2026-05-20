// `kfactory attach` resolves a workspace ref (id or slug), refreshes the
// access token, and execs `opencode attach <server> --bearer <token>
// --workspace <id> --continue` in the current terminal. One specific
// way: always continue the most recent session for the workspace. If
// no prior session exists opencode falls back to home view silently.
package main

import (
	"context"
	"os"
	"os/exec"
	"syscall"
	"time"
)

func runAttach(args []string) {
	if len(args) != 1 {
		fail("attach: usage: kfactory attach <id|slug>")
	}
	ref := args[0]

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	tok, err := ensureFresh(ctx)
	if err != nil {
		failAuth(err)
	}
	server := serverFor(tok)

	ws, err := resolveWorkspace(ctx, tok, server, ref)
	if err != nil {
		fail("attach: %v", err)
	}

	opencodePath, err := exec.LookPath("opencode")
	if err != nil {
		fail("attach: opencode not on PATH: %v", err)
	}

	// The patched opencode TUI spawns `kfactory auth refresh` as a
	// subprocess when its bearer nears expiry (see
	// patches/opencode-kfactory-refresh.patch). If `kfactory` itself
	// isn't on PATH at the point the TUI runs, refresh fails forever
	// and the operator only finds out after the first 401 mid-session.
	// Surface early.
	if _, err := exec.LookPath("kfactory"); err != nil {
		fail("attach: kfactory not on PATH for subprocess refresh: %v\n"+
			"       opencode TUI will fail to refresh the access token; reattach won't help",
			err)
	}

	// Shared refresh-token cache: the opencode TUI (patched via
	// patches/opencode-kfactory-refresh.patch) reads
	// OPENCODE_SERVER_BEARER_CACHE_PATH and pulls the access token from
	// the file at attach time. When the token nears expiry the TUI
	// spawns `kfactory auth refresh` (subprocess) which refreshes under a
	// flock-coordinated path in kfactory and rewrites the file; the TUI
	// then re-reads. kfactory never has to pre-stage the token into the
	// environment -- the file IS the single source of truth.
	cachePath, err := tokenPath()
	if err != nil {
		fail("attach: resolve token path: %v", err)
	}
	env := append(os.Environ(),
		"OPENCODE_SERVER_BEARER_CACHE_PATH="+cachePath,
	)

	argv := []string{"opencode", "attach", server, "--workspace", ws.ID, "--continue"}
	if err := syscall.Exec(opencodePath, argv, env); err != nil {
		fail("attach: exec opencode: %v", err)
	}
}
