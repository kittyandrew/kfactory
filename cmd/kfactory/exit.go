// Cross-component exit-code contract.
//
// `kfactory auth refresh` is spawned as a subprocess by the patched
// opencode TUI (see patches/opencode-kfactory-refresh.patch's
// `spawnKfactoryRefresh` in attach.ts). The TUI branches on the exit
// code to decide whether to surface a one-time hint to the operator:
//
//	exitOK            (0)  command succeeded; auth.json holds a fresh token
//	exitNotLoggedIn   (1)  refresh_token rejected by IdP; reattach needed
//	exitOther         (2)  network / filesystem / non-credential failure
//
// Any change to these values MUST be mirrored in the TS-side comment +
// branch in patches/opencode-kfactory-refresh.patch (search for
// `spawnKfactoryRefresh` + `KFACTORY_EXIT_*`). New exit codes mean a
// new patch revision.
//
// All operator-facing subcommands (not just `auth refresh`) honor this
// contract so scripts wrapping kfactory can branch consistently:
//   - `auth login` -> exitOther on flag-validation / IdP errors
//   - `auth status` -> exitNotLoggedIn on missing token / 401,
//     exitOther on network / build / non-2xx
//   - `auth refresh` -> exitNotLoggedIn / exitOther as above
//   - `list` / `attach` / `dispatch` / `delete` -> exitOther on any
//     failure, exitNotLoggedIn when ensureFresh returns errNotLoggedIn
//     (operator action: `kfactory auth login`)
//
// `fail()` in main.go uses exitOther for generic failures; `failAuth`
// in auth.go branches on errNotLoggedIn for exitNotLoggedIn.
package main

const (
	exitOK          = 0
	exitNotLoggedIn = 1
	exitOther       = 2
)
