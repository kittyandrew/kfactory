// Cross-component exit-code contract. The patched opencode TUI's
// `spawnKfactoryRefresh` (patches/opencode-kfactory-refresh.patch)
// branches on these. All operator-facing subcommands honor the same
// contract -- exitNotLoggedIn when ensureFresh returns errNotLoggedIn
// (operator action: `kfactory auth login`), exitOther for everything
// else. Bumping any value requires a matching patch revision.
package main

const (
	exitOK          = 0
	exitNotLoggedIn = 1 // refresh_token rejected; reattach needed
	exitOther       = 2 // network / filesystem / non-credential failure
)
