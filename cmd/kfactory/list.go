package main

import (
	"context"
	"fmt"
	"os"
	"text/tabwriter"
	"time"
)

func runList(args []string) {
	if len(args) != 0 {
		fail("list: unexpected args: %v", args)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	tok, err := ensureFresh(ctx)
	if err != nil {
		failAuth(err)
	}
	server := serverFor(tok)

	ws, err := listWorkspaces(ctx, tok, server)
	if err != nil {
		fail("list: %v", err)
	}

	if len(ws) == 0 {
		fmt.Fprintln(os.Stderr, "kfactory: no workspaces. create one with `kfactory dispatch <repo-url>`")
		return
	}

	// Stable order: by id ascending = creation order. The 1-based index
	// shown here is the same one `kfactory attach <n>` resolves -- pick a
	// row by its leading number.
	sortWorkspaces(ws)

	tw := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)
	_, _ = fmt.Fprintln(tw, "#\tID\tNAME\tBRANCH\tLAST USED")
	for i, w := range ws {
		when := time.UnixMilli(w.TimeUsed).Format(time.RFC3339)
		branch := w.Branch
		if branch == "" {
			branch = "-"
		}
		_, _ = fmt.Fprintf(tw, "%d\t%s\t%s\t%s\t%s\n", i+1, w.ID, w.Name, branch, when)
	}
	if err := tw.Flush(); err != nil {
		fail("list: write output: %v", err)
	}
}
