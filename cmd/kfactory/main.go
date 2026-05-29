// kfactory: CLI for an opencode factory deployment.
// See `kfactory --help` for the subcommand list, or docs/spec.md.
//
// Runtime endpoint defaults come from KFACTORY_* env vars or explicit
// `kfactory auth login` flags.
package main

import (
	"fmt"
	"os"
)

const zitadelAudienceScopeTemplate = "urn:zitadel:iam:org:project:id:%s:aud"

func main() {
	args := os.Args[1:]
	if len(args) == 0 {
		usage()
		os.Exit(exitOther)
	}

	cmd, rest := args[0], args[1:]
	switch cmd {
	case "auth":
		runAuth(rest)
	case "list":
		runList(rest)
	case "attach":
		runAttach(rest)
	case "dispatch":
		runDispatch(rest)
	case "tick":
		runTick(rest)
	case "delete":
		runDelete(rest)
	case "-h", "--help", "help":
		usage()
	default:
		fmt.Fprintf(os.Stderr, "kfactory: unknown command %q\n\n", cmd)
		usage()
		os.Exit(exitOther)
	}
}

func runAuth(args []string) {
	if len(args) == 0 {
		fail("auth: usage: kfactory auth <login|logout|status|refresh>")
	}
	sub, rest := args[0], args[1:]
	switch sub {
	case "login":
		runLogin(rest)
	case "logout":
		runLogout()
	case "status":
		runAuthStatus(rest)
	case "refresh":
		runAuthRefresh(rest)
	default:
		fail("auth: unknown subcommand %q (login|logout|status|refresh)", sub)
	}
}

func usage() {
	fmt.Fprint(os.Stderr, "kfactory -- CLI for an opencode factory deployment\n\n"+
		"usage:\n"+
		"  kfactory auth login [--server URL] [--issuer URL] [--client-id ID] [--audience ID]\n"+
		"  kfactory auth logout\n"+
		"  kfactory auth status                # who am i, token state, server reachability\n"+
		"  kfactory auth refresh               # ensure access token is fresh (used by opencode TUI)\n"+
		"  kfactory list                       # show workspaces\n"+
		"  kfactory attach <id|slug|#>         # attach opencode TUI to a workspace\n"+
		"  kfactory dispatch <repo-url> <prompt...>  # create workspace + session + async prompt\n"+
		"  kfactory tick <task-id|ref> [--prompt TEXT]   # idempotent dispatch:\n"+
		"                                                # - scheduled (task-id matches /etc/kfactory/scheduled/<id>.json)\n"+
		"                                                # - ad-hoc nudge (ref + --prompt; for recovery/manual)\n"+
		"  kfactory delete [-y] <id|slug|#>    # delete workspace + wipe clone\n\n"+
		"Tokens persist at $XDG_CONFIG_HOME/kfactory/auth.json (mode 0600).\n"+
		"Runtime defaults: KFACTORY_SERVER, KFACTORY_OIDC_ISSUER, KFACTORY_OIDC_CLIENT_ID, KFACTORY_OIDC_AUDIENCE.\n")
}

func fail(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "kfactory: "+format+"\n", args...)
	os.Exit(exitOther)
}
