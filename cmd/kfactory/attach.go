// `kfactory attach` resolves a ref, refreshes, execs `opencode attach
// <server> --workspace <id> --continue`. Always continues the most-
// recent session; opencode falls back to home view if none exists.
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

	// The patched TUI spawns `kfactory auth refresh` on near-expiry
	// (opencode-kfactory-refresh.patch); without kfactory on PATH the
	// operator only finds out via mid-session 401. Surface early.
	if _, err := exec.LookPath("kfactory"); err != nil {
		fail("attach: kfactory not on PATH for subprocess refresh: %v\n"+
			"       opencode TUI will fail to refresh the access token; reattach won't help",
			err)
	}

	// Shared token cache: TUI reads OPENCODE_SERVER_BEARER_CACHE_PATH,
	// spawns `kfactory auth refresh` on near-expiry (flock-coordinated
	// rewrite), then re-reads. The file is the single source of truth;
	// kfactory never pre-stages the token into the env.
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
