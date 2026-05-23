// `kfactory auth status`: identity + expiry + (with --verify, default)
// server-acceptance. Exit codes per exit.go.
//
// @WARNING: NOT side-effect-free -- the verify path goes through
// ensureFresh, which rotates persisted state if the access token is
// expired. Use `--no-verify` for read-only inspection.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"time"
)

func runAuthStatus(args []string) {
	fs := flag.NewFlagSet("kfactory auth status", flag.ExitOnError)
	noVerify := fs.Bool("no-verify", false, "skip server-side token validation")
	_ = fs.Parse(args)
	if fs.NArg() > 0 {
		fail("auth status: unexpected positional args: %v", fs.Args())
	}
	verify := !*noVerify

	t, err := loadTokens()
	if err != nil {
		if os.IsNotExist(err) {
			fmt.Println("kfactory: not logged in (no token file)")
			fmt.Println("       run `kfactory auth login`")
			os.Exit(exitNotLoggedIn)
		}
		fail("auth status: %v", err)
	}

	server := serverFor(t)

	now := time.Now()
	accessLine := "expired"
	if t.ExpiresAt.After(now) {
		accessLine = fmt.Sprintf("valid, expires in %s (%s)",
			truncDur(t.ExpiresAt.Sub(now)),
			t.ExpiresAt.Local().Format(time.RFC3339))
	} else if !t.ExpiresAt.IsZero() {
		accessLine = fmt.Sprintf("expired %s ago (%s)",
			truncDur(now.Sub(t.ExpiresAt)),
			t.ExpiresAt.Local().Format(time.RFC3339))
	}

	refreshLine := "missing"
	if t.RefreshToken != "" {
		refreshLine = "present (silent refresh on next command)"
	}

	fmt.Println("kfactory auth status")
	fmt.Printf("  server:    %s\n", server)
	fmt.Printf("  issuer:    %s\n", t.Issuer)
	fmt.Printf("  client:    %s\n", t.ClientID)
	fmt.Printf("  audience:  %s\n", t.Audience)
	fmt.Printf("  access:    %s\n", accessLine)
	fmt.Printf("  refresh:   %s\n", refreshLine)

	if !verify {
		return
	}

	// ensureFresh refreshes if stale; then GET /experimental/workspace
	// (cheapest bearer-auth'd endpoint) to verify acceptance.
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	fresh, err := ensureFresh(ctx)
	if err != nil {
		fmt.Printf("  server:    ✗ cannot refresh token (%v)\n", err)
		if errors.Is(err, errNotLoggedIn) {
			os.Exit(exitNotLoggedIn)
		}
		os.Exit(exitOther)
	}
	t = fresh

	req, err := newRequest(ctx, t, server, http.MethodGet, "/experimental/workspace", nil)
	if err != nil {
		fmt.Printf("  verify:    ✗ build request: %v\n", err)
		os.Exit(exitOther)
	}
	resp, err := httpClient.Do(req)
	if err != nil {
		fmt.Printf("  verify:    ✗ unreachable (%v)\n", err)
		os.Exit(exitOther)
	}
	defer func() { _ = resp.Body.Close() }()
	body, _ := io.ReadAll(resp.Body)

	switch {
	case resp.StatusCode == http.StatusUnauthorized:
		fmt.Println("  verify:    ✗ 401 -- token rejected (run `kfactory auth login`)")
		os.Exit(exitNotLoggedIn)
	case resp.StatusCode >= 200 && resp.StatusCode < 300:
		count := strings.Count(string(body), "\"id\":")
		fmt.Printf("  verify:    ✓ %s (%d workspace%s)\n", resp.Status, count, plural(count))
	default:
		fmt.Printf("  verify:    ✗ %s: %s\n", resp.Status, strings.TrimSpace(string(body)))
		os.Exit(exitOther)
	}
}

// Second-precision under 5m, minute-precision above. Avoids
// "11h53m42.18s" in the status output.
func truncDur(d time.Duration) string {
	if d < 5*time.Minute {
		return d.Truncate(time.Second).String()
	}
	return d.Truncate(time.Minute).String()
}

func plural(n int) string {
	if n == 1 {
		return ""
	}
	return "s"
}
