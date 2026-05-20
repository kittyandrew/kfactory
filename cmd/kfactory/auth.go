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
	"syscall"
	"time"

	"github.com/zitadel/oidc/v3/pkg/client/rp"
	"github.com/zitadel/oidc/v3/pkg/oidc"
)

// authFileSchemaVersion is the on-disk schema version of auth.json.
// The patched opencode TUI (see patches/opencode-kfactory-refresh.patch's
// readAuthFile + assertion in attach.ts) reads this field and must
// understand the version it sees. Bump in lockstep with the TS reader.
//
// History:
//
//	1: initial published schema (server, issuer, client_id, audience,
//	   access_token, refresh_token, expires_at).
const authFileSchemaVersion = 1

// tokenFile is the on-disk schema. Endpoint config (issuer/clientID/audience/server)
// is persisted next to the tokens so a refresh works without re-reading
// the operator's args, and so `kfactory list` etc. don't need any flags
// after `kfactory auth login`.
//
// SchemaVersion is the cross-component contract between this struct and
// the TS reader in the patched opencode TUI. Missing/zero on disk means
// "legacy pre-version file" -- loadTokens treats that as v1 for
// back-compat; saveTokens always writes the current version.
type tokenFile struct {
	SchemaVersion int       `json:"schema_version"`
	Server        string    `json:"server"` // factory API base URL
	Issuer        string    `json:"issuer"`
	ClientID      string    `json:"client_id"`
	Audience      string    `json:"audience"`
	AccessToken   string    `json:"access_token"`
	RefreshToken  string    `json:"refresh_token"`
	ExpiresAt     time.Time `json:"expires_at"`
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
	// Missing/zero version on a legacy file is treated as v1; saveTokens
	// upgrades the field on next write. A future version > current means
	// the user has a NEWER kfactory build's auth.json and downgraded the
	// binary -- refuse rather than risk a partial-field misread.
	if t.SchemaVersion > authFileSchemaVersion {
		return nil, fmt.Errorf(
			"%s: schema_version %d > supported %d (downgrade?)",
			p, t.SchemaVersion, authFileSchemaVersion)
	}
	return &t, nil
}

func saveTokens(t *tokenFile) error {
	p, err := tokenPath()
	if err != nil {
		return err
	}
	dir := filepath.Dir(p)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return fmt.Errorf("mkdir %s: %w", dir, err)
	}
	t.SchemaVersion = authFileSchemaVersion
	b, err := json.MarshalIndent(t, "", "  ")
	if err != nil {
		return err
	}
	// Atomicity + durability: write to tmp, fsync the data, rename, then
	// fsync the parent directory so a power loss after the rename can't
	// resurrect the pre-rotation file. Refresh tokens rotate at the IdP,
	// so a "phantom rollback" would silently lock the operator out --
	// worth two extra fsyncs to avoid.
	//
	// @NOTE: durability claim holds only if the dir-fsync step succeeds.
	//   If os.Open(dir) fails AFTER the rename, the new content IS on
	//   disk (rename's atomicity covers visibility) but the directory
	//   entry hasn't been fsync'd, so a crash within the kernel's
	//   writeback window could observe the pre-rename state on next
	//   boot. We return the open/fsync error in that case rather than
	//   silently downgrading; the operator's next successful login
	//   re-establishes durability.
	tmp := p + ".tmp"
	f, err := os.OpenFile(tmp, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600)
	if err != nil {
		return err
	}
	if _, err := f.Write(b); err != nil {
		_ = f.Close()
		_ = os.Remove(tmp)
		return err
	}
	if err := f.Sync(); err != nil {
		_ = f.Close()
		_ = os.Remove(tmp)
		return fmt.Errorf("fsync %s: %w", tmp, err)
	}
	if err := f.Close(); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	if err := os.Rename(tmp, p); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	d, err := os.Open(dir)
	if err != nil {
		return fmt.Errorf("open %s for fsync: %w", dir, err)
	}
	if err := d.Sync(); err != nil {
		_ = d.Close()
		return fmt.Errorf("fsync %s: %w", dir, err)
	}
	return d.Close()
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
// time. The audience-scope `template` binds the configured audience
// into the access-token `aud[]` claim; the package-level
// defaultAudienceScopeTemplate carries the deployment-wide default
// (Zitadel's URN scheme out of the box, ldflag-injectable for other
// providers). When the template is empty, no audience scope is sent
// and the issuer's default aud[] behavior applies.
//
// Threaded as a parameter rather than read off the package-level var
// directly so tests can exercise the empty-template path without
// mutating shared state -- keeps tests safe for `t.Parallel()`.
func loginScopes(audience, template string) []string {
	scopes := []string{"openid", "profile", "email", "offline_access"}
	if template != "" {
		scopes = append(scopes, fmt.Sprintf(template, audience))
	}
	return scopes
}

// errNotLoggedIn is the sentinel surface for "no usable credentials".
// Callers translate this into a clean "run kfactory auth login" exit, not a
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

	scopes := loginScopes(*audience, defaultAudienceScopeTemplate)
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
// lockfile or ctx is cancelled. Caller MUST defer releaseLock.
//
// Implementation: polls LOCK_EX|LOCK_NB on `lockPollInterval` and
// selects on ctx.Done() between attempts. This is genuinely cancellable.
//
// Why not blocking LOCK_EX with an fd-close watchdog from another
// goroutine? On Linux, closing the fd from another thread of the same
// process does NOT unblock a blocked flock(LOCK_EX) syscall: the lock
// is associated with the open file description, not the fd, and the
// kernel keeps the description live while the syscall is in progress.
// Empirically verified -- a blocked flock keeps blocking until the
// other holder releases (or the process exits). So a watchdog design
// can't deliver the cancellation semantics callers need; polling can.
//
// `lockPollInterval` is short enough that ctx-cancel responds quickly
// and long enough that an idle contended lock isn't a busy loop.
//
// @WARNING: callers MUST pass a ctx with a deadline. The poll loop has
//
//	no maxWait of its own; an undeadlined ctx + a stuck holder = forever.
//	Every kfactory subcommand wraps the call in `context.WithTimeout`
//	today; if a new caller doesn't, the lock acquire is unbounded.
const lockPollInterval = 50 * time.Millisecond

func acquireLock(ctx context.Context) (*os.File, error) {
	// Honor a pre-cancelled ctx without even creating the lockfile.
	if err := ctx.Err(); err != nil {
		return nil, err
	}
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
	for {
		err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
		if err == nil {
			return f, nil
		}
		if !errors.Is(err, syscall.EWOULDBLOCK) {
			_ = f.Close()
			return nil, fmt.Errorf("flock: %w", err)
		}
		// Contended -- wait briefly and retry, unless ctx cancels.
		select {
		case <-ctx.Done():
			_ = f.Close()
			return nil, ctx.Err()
		case <-time.After(lockPollInterval):
		}
	}
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
// errNotLoggedIn means the user must run `kfactory auth login`.
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

	relying, err := rp.NewRelyingPartyOIDC(ctx, t.Issuer, t.ClientID, "", "", loginScopes(t.Audience, defaultAudienceScopeTemplate))
	if err != nil {
		return nil, fmt.Errorf("oidc init: %w", err)
	}
	refreshed, err := rp.RefreshTokens[*oidc.IDTokenClaims](ctx, relying, t.RefreshToken, "", "")
	if err != nil {
		// Distinguish "IdP rejected our refresh_token" (only recovery is
		// re-login) from "transient failure" (network, IdP 5xx, etc.).
		// The first burns the refresh_token at the IdP; the second
		// leaves it valid and a retry would work.
		var oidcErr *oidc.Error
		if errors.As(err, &oidcErr) && oidcErr.ErrorType == oidc.InvalidGrant {
			return nil, errNotLoggedIn
		}
		return nil, fmt.Errorf("refresh: %w", err)
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
// Exit codes are part of a cross-component contract -- see exit.go.
// The TUI's `createBearerRefreshFetch` re-reads auth.json after this
// subprocess completes regardless of exit code; a non-zero exit just
// means the next request will likely 401.
//
// @WARNING: stdout MUST stay silent on this code path. The TUI captures
//
//	stderr only (stripVTControlCharacters'd before display); stdout is
//	inherited and would corrupt the Ink alternate-screen mid-render.
func runAuthRefresh(args []string) {
	// Insurance: an unexpected panic (e.g., from upstream zitadel/oidc
	// code) would otherwise dump a multi-line Go stack into stderr,
	// which the TUI's stripVTControlCharacters then displays in the
	// alternate screen as a "refresh hint." Catch the panic and emit
	// one line + exitOther instead. Note: this does NOT catch the
	// normal error paths below (os.Exit bypasses deferred functions);
	// those are already one-line stderr writes.
	defer func() {
		if r := recover(); r != nil {
			fmt.Fprintf(os.Stderr, "kfactory: auth refresh: panic: %v\n", r)
			os.Exit(exitOther)
		}
	}()

	if len(args) > 0 {
		fail("auth refresh: takes no arguments")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	if _, err := ensureFresh(ctx); err != nil {
		if errors.Is(err, errNotLoggedIn) {
			fmt.Fprintln(os.Stderr, "kfactory: not logged in")
			os.Exit(exitNotLoggedIn)
		}
		fmt.Fprintf(os.Stderr, "kfactory: auth refresh: %v\n", err)
		os.Exit(exitOther)
	}
}

// failAuth distinguishes "no usable credentials" from generic errors so
// the operator gets a concrete next step. The exit codes match the
// cross-component contract in exit.go: exitNotLoggedIn for "operator
// must re-login," exitOther (via fail) for everything else.
func failAuth(err error) {
	if errors.Is(err, errNotLoggedIn) {
		fmt.Fprintln(os.Stderr, "kfactory: not logged in. run `kfactory auth login`")
		os.Exit(exitNotLoggedIn)
	}
	fail("auth: %v", err)
}
