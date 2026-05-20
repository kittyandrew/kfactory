// `kfactory delete <id|slug|#>` resolves the workspace ref, confirms with
// the operator (unless --yes), then DELETEs the WorkspaceTable row via
// /experimental/workspace/<id>. The factory adapter's remove() callback
// wipes the on-disk clone at /var/lib/factory/workspaces/<slug>/.
package main

import (
	"bufio"
	"context"
	"flag"
	"fmt"
	"os"
	"strings"
	"time"
)

func runDelete(args []string) {
	fs := flag.NewFlagSet("kfactory delete", flag.ExitOnError)
	var yes bool
	fs.BoolVar(&yes, "y", false, "skip confirmation")
	fs.BoolVar(&yes, "yes", false, "skip confirmation")
	_ = fs.Parse(args)
	if fs.NArg() != 1 {
		fail("delete: usage: kfactory delete [-y|--yes] <id|slug|#>")
	}
	ref := fs.Arg(0)

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	tok, err := ensureFresh(ctx)
	if err != nil {
		failAuth(err)
	}
	server := serverFor(tok)

	ws, err := resolveWorkspace(ctx, tok, server, ref)
	if err != nil {
		fail("delete: %v", err)
	}

	if !yes {
		fmt.Fprintf(os.Stderr, "kfactory: delete workspace %s (%s)?\n", ws.ID, ws.Name)
		fmt.Fprintf(os.Stderr, "       directory: %s\n", ws.Directory)
		fmt.Fprint(os.Stderr, "       all sessions + clone WILL be wiped. [y/N] ")
		answer, _ := bufio.NewReader(os.Stdin).ReadString('\n')
		if a := strings.TrimSpace(strings.ToLower(answer)); a != "y" && a != "yes" {
			fmt.Fprintln(os.Stderr, "kfactory: aborted")
			os.Exit(1)
		}
	}

	if err := deleteWorkspace(ctx, tok, server, ws.ID); err != nil {
		fail("delete: %v", err)
	}
	fmt.Fprintf(os.Stderr, "kfactory: deleted %s (%s)\n", ws.ID, ws.Name)
}
