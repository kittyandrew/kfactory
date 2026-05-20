// kfactory: CLI for an opencode factory deployment (OIDC-protected, multi-
// workspace, factory-adapter on the server side).
//
// Subcommands:
//
//	kfactory auth login [--server URL] [--issuer URL] [--client-id ID] [--audience ID]
//	    OIDC device-flow login. Persists tokens AND endpoint config to
//	    $XDG_CONFIG_HOME/kfactory/auth.json (mode 0600). All four flags are
//	    REQUIRED on first login unless your build embeds defaults via
//	    `-ldflags "-X main.defaultX=Y"` (see below).
//	kfactory auth logout
//	    Delete the token file.
//	kfactory auth status
//	    Print who-am-i + token freshness + server reachability.
//	kfactory auth refresh
//	    Re-up the access token (called by the patched opencode TUI as a
//	    subprocess when its bearer nears expiry).
//
//	kfactory list
//	    Print one row per workspace: <#> <id> <name> <last-used>.
//	kfactory attach <id|slug|#>
//	    Resolve the workspace ref, refresh the access token, exec
//	    `opencode attach <server> --workspace <id> --continue` in the
//	    current terminal. Operator launches their own terminal; kfactory
//	    stays out of window management.
//	kfactory dispatch <repo-url> <prompt...>
//	    Create a workspace for the repo (factory adapter clones remote
//	    HEAD into a per-workspace dir), open a fresh session, fire the
//	    prompt at it asynchronously. Prints the workspace id on stdout.
//	kfactory delete [-y|--yes] <id|slug|#>
//	    DELETE the workspace via /experimental/workspace/<id>; the
//	    factory adapter's remove() wipes the on-disk clone. Confirms
//	    interactively unless -y.
//
// Embedding defaults at build time:
//
//	go build -ldflags "-X main.defaultServer=https://factory.example.com \
//	                   -X main.defaultIssuer=https://auth.example.com \
//	                   -X main.defaultClientID=12345 \
//	                   -X main.defaultAudience=67890" ./cmd/kfactory
//
// Upstream kfactory ships with empty defaults; deployers inject via ldflags
// or rely on operators passing the flags on first `kfactory auth login`.
package main

import (
	"fmt"
	"os"
)

// Defaults are injected at build time via `-ldflags "-X main.defaultX=Y"`.
// Upstream kfactory leaves the four endpoint defaults empty; consumers
// wire their endpoints.
//
// defaultAudienceScopeTemplate is the OIDC scope used to bind the
// audience into the access-token aud[] claim. Defaults to Zitadel's URN
// scheme so existing Zitadel deployments keep working; override via
// `-ldflags "-X main.defaultAudienceScopeTemplate=urn:..."` for other
// providers, or set it to empty to skip audience-scope injection
// entirely. The template must contain exactly one `%s` (replaced with
// the audience value at login time).
var (
	defaultServer                = ""
	defaultIssuer                = ""
	defaultClientID              = ""
	defaultAudience              = ""
	defaultAudienceScopeTemplate = "urn:zitadel:iam:org:project:id:%s:aud"
)

func main() {
	args := os.Args[1:]
	if len(args) == 0 {
		usage()
		os.Exit(1)
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
	case "delete":
		runDelete(rest)
	case "-h", "--help", "help":
		usage()
	default:
		fmt.Fprintf(os.Stderr, "kfactory: unknown command %q\n\n", cmd)
		usage()
		os.Exit(1)
	}
}

// runAuth dispatches `kfactory auth <sub>`. Auth commands live only under
// this subgroup -- one canonical path, no top-level aliases.
func runAuth(args []string) {
	if len(args) == 0 {
		fmt.Fprint(os.Stderr, "kfactory: usage: kfactory auth <login|logout|status|refresh>\n")
		os.Exit(1)
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
		"  kfactory delete [-y] <id|slug|#>    # delete workspace + wipe clone\n\n"+
		"Tokens persist at $XDG_CONFIG_HOME/kfactory/auth.json (mode 0600).\n")
}

func fail(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "kfactory: "+format+"\n", args...)
	os.Exit(1)
}
