// OIDC device-flow login (RFC 8628), token persistence with rotation,
// and the "ensure fresh access token" helper every other subcommand
// goes through.
//
// Token file: $XDG_CONFIG_HOME/kfactory/auth.json (mode 0600). Server URL
// + issuer + client_id + audience are persisted alongside the tokens
// so subsequent invocations don't need any flags. Refresh fires when
// the access token is within 30s of expiry; refresh is coordinated
// across processes via POSIX flock on `auth.json.lock`.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/zitadel/oidc/v3/pkg/client/rp"
	"github.com/zitadel/oidc/v3/pkg/oidc"
)

// tokenFile is the on-disk schema. Endpoint config (issuer/clientID/audience/server)
// is persisted next to the tokens so a refresh works without re-reading
// the operator's args, and so `kfactory list` etc. don't need any flags
// after `kfactory login`.
type tokenFile struct {
	Server       string    `json:"server"` // factory API base URL
	Issuer       string    `json:"issuer"`
	ClientID     string    `json:"client_id"`
	Audience     string    `json:"audience"`
	AccessToken  string    `json:"access_token"`
	RefreshToken string    `json:"refresh_token"`
	ExpiresAt    time.Time `json:"expires_at"`
}

func (t *tokenFile) expired() bool {
	return time.Now().After(t.ExpiresAt.Add(-30 * time.Second))
}

func tokenPath() (string, error) {
	dir, err := os.UserConfigDir()
	if err != nil {
		return "", fmt.Errorf("resolve config dir: %w", err)
	}
	return filepath.Join(dir, "kfactory", "auth.json"), nil
}

func loadTokens() (*tokenFile, error) {
	p, err := tokenPath()
	if err != nil {
		return nil, err
	}
	b, err := os.ReadFile(p)
	if err != nil {
		return nil, err
	}
	var t tokenFile
	if err := json.Unmarshal(b, &t); err != nil {
		return nil, fmt.Errorf("parse %s: %w", p, err)
	}
	return &t, nil
}

func saveTokens(t *tokenFile) error {
	p, err := tokenPath()
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(p), 0o700); err != nil {
		return fmt.Errorf("mkdir %s: %w", filepath.Dir(p), err)
	}
	b, err := json.MarshalIndent(t, "", "  ")
	if err != nil {
		return err
	}
	// Write to tmp + rename for atomicity; the file lives in $HOME so
	// the rename is on the same filesystem.
	tmp := p + ".tmp"
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, p)
}

func deleteTokens() error {
	p, err := tokenPath()
	if err != nil {
		return err
	}
	if err := os.Remove(p); err != nil && !os.IsNotExist(err) {
		return err
	}
	return nil
}

// loginScopes returns the OIDC scopes requested at device-authorization
// time. The audience-scope template binds the configured audience into
// the access-token `aud[]` claim; defaults to Zitadel's URN scheme.
// Consumers on Keycloak/Authentik/Dex/etc. can override or disable it
// via ldflags (see defaultAudienceScopeTemplate below). When the
// template is empty, no audience scope is sent and the issuer's default
// aud[] behavior applies.
func loginScopes(audience string) []string {
	scopes := []string{"openid", "profile", "email", "offline_access"}
	if defaultAudienceScopeTemplate != "" {
		scopes = append(scopes, fmt.Sprintf(defaultAudienceScopeTemplate, audience))
	}
	return scopes
}

// errNotLoggedIn is the sentinel surface for "no usable credentials".
// Callers translate this into a clean "run kfactory login" exit, not a
// stack trace.
var errNotLoggedIn = errors.New("not logged in")

// runLogin parses login-specific flags (--server, --issuer, --client-id,
// --audience), runs RFC 8628 device authorization, and persists the
// resulting tokens + endpoint config.
func runLogin(args []string) {
	fs := flag.NewFlagSet("kfactory auth login", flag.ExitOnError)
	server := fs.String("server", defaultServer, "factory API base URL")
	issuer := fs.String("issuer", defaultIssuer, "OIDC issuer URL")
	clientID := fs.String("client-id", defaultClientID, "OIDC client id")
	audience := fs.String("audience", defaultAudience, "OIDC audience / project id")
	_ = fs.Parse(args)
	if fs.NArg() > 0 {
		fail("login: unexpected positional args: %v", fs.Args())
	}
	if *server == "" || *issuer == "" || *clientID == "" || *audience == "" {
		fail("login: missing required endpoint config.\n" +
			"       this build has no compiled-in defaults; pass all four:\n" +
			"       kfactory auth login --server URL --issuer URL --client-id ID --audience ID\n" +
			"       (consumers can also embed defaults via -ldflags -X)")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Minute)
	defer cancel()

	scopes := loginScopes(*audience)
	relying, err := rp.NewRelyingPartyOIDC(ctx, *issuer, *clientID, "", "", scopes)
	if err != nil {
		fail("login: oidc init: %v", err)
	}

	da, err := rp.DeviceAuthorization(ctx, scopes, relying, nil)
	if err != nil {
		fail("login: device authorization: %v", err)
	}

	// Zitadel's device endpoint advertises a verification URL pointing
	// at the legacy v1 login UI (/device, /ui/login/...), which has a
	// known WebAuthn projection bug for org-scoped users: the passkey
	// is in the DB but v1's lookup fails to find it. Rewrite to v2.
	// Harmless against non-Zitadel issuers that don't serve /ui/v2/login.
	verify := strings.TrimRight(*issuer, "/") + "/ui/v2/login/device?user_code=" + url.QueryEscape(da.UserCode)
	fmt.Fprintf(os.Stderr, "kfactory: open %s\n", verify)
	fmt.Fprintf(os.Stderr, "kfactory: code %s\n", da.UserCode)

	tok, err := rp.DeviceAccessToken(ctx, da.DeviceCode, time.Duration(da.Interval)*time.Second, relying)
	if err != nil {
		fail("login: %v", err)
	}

	t := &tokenFile{
		Server:       strings.TrimRight(*server, "/"),
		Issuer:       *issuer,
		ClientID:     *clientID,
		Audience:     *audience,
		AccessToken:  tok.AccessToken,
		RefreshToken: tok.RefreshToken,
		ExpiresAt:    time.Now().Add(time.Duration(tok.ExpiresIn) * time.Second),
	}
	if err := saveTokens(t); err != nil {
		fail("login: save tokens: %v", err)
	}
	fmt.Fprintf(os.Stderr, "kfactory: logged in (server=%s)\n", t.Server)
}

func runLogout() {
	if err := deleteTokens(); err != nil {
		fail("logout: %v", err)
	}
	fmt.Fprintln(os.Stderr, "kfactory: logged out")
}

// lockPath sits next to auth.json. Serializes refresh across processes
// (this CLI process AND the opencode TUI invoked via `kfactory attach`, which
// spawns `kfactory auth refresh` as a subprocess under the bearer-auth patch).
//
// Uses POSIX flock(2) via syscall.Flock: the kernel auto-releases on
// process exit, so SIGTERM/SIGKILL doesn't leave a stale lockfile. No
// stale-detection logic needed. The lockfile itself stays on disk
// between runs (just an empty marker); the lock state lives in the
// kernel's file descriptor.
func lockFilePath() (string, error) {
	p, err := tokenPath()
	if err != nil {
		return "", err
	}
	return p + ".lock", nil
}

// acquireLock blocks until it holds an exclusive POSIX file lock on the
// lockfile. Caller MUST defer releaseLock.
//
// @WARNING: ctx cancellation during a CONTENDED wait does not actually
//
//	interrupt syscall.Flock on Linux -- the watchdog goroutine closes
//	the fd, but the blocked flock syscall does not unblock until the
//	other process releases the lock or this process exits. The
//	cancellation path works only if ctx is already done before the
//	syscall, or in the (rare) case where the lock is acquired and ctx
//	has been cancelled in the meantime. Production-safe fix: switch
//	to polling LOCK_EX|LOCK_NB with select-on-ctx. Deferred to a
//	follow-up; in current usage (kfactory CLI subcommands with 30s
//	context timeouts on operator-driven flows), the gap is rare and
//	shows up as the process appearing hung until the holder exits.
//
// The `closeOnce` sync.Once serializes the close between the watchdog
// goroutine and the parent's error paths. Without it, ctx-cancel exactly
// during flock-success would race: both might call Close(), and a third
// goroutine that opened a file in between could get the same fd number,
// resulting in our Close() targeting an unrelated fd.
func acquireLock(ctx context.Context) (*os.File, error) {
	lp, err := lockFilePath()
	if err != nil {
		return nil, err
	}
	if err := os.MkdirAll(filepath.Dir(lp), 0o700); err != nil {
		return nil, err
	}
	f, err := os.OpenFile(lp, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, err
	}
	var closeOnce sync.Once
	closeFn := func() { closeOnce.Do(func() { _ = f.Close() }) }

	done := make(chan struct{})
	go func() {
		select {
		case <-ctx.Done():
			closeFn()
		case <-done:
		}
	}()
	err = syscall.Flock(int(f.Fd()), syscall.LOCK_EX)
	close(done)
	if err != nil {
		closeFn()
		return nil, fmt.Errorf("flock: %w", err)
	}
	if ctx.Err() != nil {
		closeFn()
		return nil, ctx.Err()
	}
	return f, nil
}

func releaseLock(f *os.File) {
	// Closing the fd releases the flock as a side effect; the explicit
	// LOCK_UN is belt-and-suspenders, the canonical kernel-documented
	// release path is fd close. See man flock(2).
	_ = syscall.Flock(int(f.Fd()), syscall.LOCK_UN)
	_ = f.Close()
}

// ensureFresh loads the persisted tokens, refreshes them if expired,
// persists the rotated set, and returns the unpacked tokenFile.
// errNotLoggedIn means the user must run `kfactory login`.
//
// Cross-process safety: refresh runs under acquireLock so a concurrent
// `kfactory attach` + an opencode TUI mid-refresh can't race. The lock-then-
// re-read pattern means whoever loses the race uses the winner's fresh
// tokens instead of trying their own stale refresh_token (Zitadel rotates,
// the loser's old token is invalid after the winner succeeds).
func ensureFresh(ctx context.Context) (*tokenFile, error) {
	t, err := loadTokens()
	if err != nil {
		if os.IsNotExist(err) {
			return nil, errNotLoggedIn
		}
		return nil, err
	}
	if !t.expired() {
		return t, nil
	}
	if t.RefreshToken == "" {
		return nil, errNotLoggedIn
	}

	lock, err := acquireLock(ctx)
	if err != nil {
		return nil, fmt.Errorf("acquire refresh lock: %w", err)
	}
	defer releaseLock(lock)

	// Re-read under the lock: another process may have refreshed while
	// we were waiting. If so, their result is on disk -- use it.
	t, err = loadTokens()
	if err != nil {
		if os.IsNotExist(err) {
			return nil, errNotLoggedIn
		}
		return nil, err
	}
	if !t.expired() {
		return t, nil
	}
	if t.RefreshToken == "" {
		return nil, errNotLoggedIn
	}

	relying, err := rp.NewRelyingPartyOIDC(ctx, t.Issuer, t.ClientID, "", "", loginScopes(t.Audience))
	if err != nil {
		return nil, fmt.Errorf("oidc init: %w", err)
	}
	refreshed, err := rp.RefreshTokens[*oidc.IDTokenClaims](ctx, relying, t.RefreshToken, "", "")
	if err != nil {
		// Refresh tokens rotate; once Zitadel rejects ours the only
		// recovery is interactive. Surface the canonical sentinel.
		return nil, errNotLoggedIn
	}
	t.AccessToken = refreshed.AccessToken
	if refreshed.RefreshToken != "" {
		t.RefreshToken = refreshed.RefreshToken
	}
	t.ExpiresAt = refreshed.Expiry
	if t.ExpiresAt.IsZero() {
		t.ExpiresAt = time.Now().Add(5 * time.Minute)
	}
	if err := saveTokens(t); err != nil {
		return nil, fmt.Errorf("save refreshed tokens: %w", err)
	}
	return t, nil
}

// runAuthRefresh is invoked by the patched opencode TUI as a subprocess
// when its bearer token nears expiry. It runs the same ensureFresh path
// that every other kfactory subcommand goes through, which means:
//   - acquires auth.json.lock (cross-process serialization)
//   - re-reads auth.json under the lock
//   - if still expired, POSTs Zitadel /oauth/v2/token with refresh_token
//   - writes the rotated tokens back atomically (tmp + rename)
//   - releases the lock
//
// Exits 0 on success, 1 on errNotLoggedIn (refresh_token rejected), 2 on
// any other error. The TUI's `createBearerRefreshFetch` re-reads
// auth.json after this subprocess completes regardless of exit code; a
// non-zero exit just means the next request will likely 401.
func runAuthRefresh(args []string) {
	if len(args) > 0 {
		fail("auth refresh: takes no arguments")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	if _, err := ensureFresh(ctx); err != nil {
		if errors.Is(err, errNotLoggedIn) {
			fmt.Fprintln(os.Stderr, "kfactory: not logged in")
			os.Exit(1)
		}
		fmt.Fprintf(os.Stderr, "kfactory: auth refresh: %v\n", err)
		os.Exit(2)
	}
}

// failAuth distinguishes "no usable credentials" from generic errors so
// the operator gets a concrete next step.
func failAuth(err error) {
	if errors.Is(err, errNotLoggedIn) {
		fmt.Fprintln(os.Stderr, "kfactory: not logged in. run `kfactory login`")
		os.Exit(1)
	}
	fail("auth: %v", err)
}
