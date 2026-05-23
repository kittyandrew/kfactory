// OIDC device-flow login (RFC 8628), token rotation, ensureFresh.
//
// Token file: $XDG_CONFIG_HOME/kfactory/auth.json (mode 0600). Endpoint
// config (server/issuer/client_id/audience) persists alongside the
// tokens so post-login invocations need no flags. Refresh fires at
// 30s-before-expiry and serializes across processes via POSIX flock
// on `auth.json.lock`.
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

// authFileSchemaVersion is read by the patched opencode TUI
// (patches/opencode-kfactory-refresh.patch:readAuthFile); bump in
// lockstep with the TS reader.
//
// History:
//
//	1: initial schema (server, issuer, client_id, audience,
//	   access_token, refresh_token, expires_at).
const authFileSchemaVersion = 1

// SchemaVersion is the cross-component contract with the TS reader.
// Missing/zero on disk = legacy pre-version file (loadTokens treats
// as v1); saveTokens always writes the current version.
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
	// Future version > current = the binary was downgraded. Refuse
	// rather than risk a partial-field misread.
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
	// Atomic write + durability: tmp + fsync + rename + dir-fsync.
	// Refresh tokens rotate at the IdP -- a "phantom rollback" from
	// post-rename power loss would silently lock the operator out. The
	// dir-fsync is the second guard (rename's atomicity covers visibility
	// only); we return its error rather than silently downgrade.
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

// `template` binds the audience into the access-token aud[] claim;
// defaultAudienceScopeTemplate is the deployment default (Zitadel URN
// out of the box, ldflag-injectable). Empty template = issuer default.
// Passed as a param (not read off the package var) so tests are
// t.Parallel()-safe.
func loginScopes(audience, template string) []string {
	scopes := []string{"openid", "profile", "email", "offline_access"}
	if template != "" {
		scopes = append(scopes, fmt.Sprintf(template, audience))
	}
	return scopes
}

// "No usable credentials" sentinel; callers map to a clean
// "run kfactory auth login" exit.
var errNotLoggedIn = errors.New("not logged in")

// Parses login flags, runs RFC 8628 device authorization, persists tokens.
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

	// Zitadel v1 device UI has a WebAuthn projection bug for org-scoped
	// users (passkey in DB but v1 lookup misses). Rewrite to v2. Harmless
	// against non-Zitadel issuers that don't serve /ui/v2/login.
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

// Serializes refresh across this CLI + the opencode TUI's `kfactory
// auth refresh` subprocess (per bearer-auth patch). POSIX flock(2)
// auto-releases on process exit -- no stale detection needed.
func lockFilePath() (string, error) {
	p, err := tokenPath()
	if err != nil {
		return "", err
	}
	return p + ".lock", nil
}

// Polling LOCK_EX|LOCK_NB rather than blocking LOCK_EX: on Linux,
// closing the fd from another goroutine doesn't unblock a blocked
// flock (lock is on the open file description, not the fd). Polling
// is the only way to make this genuinely cancellable.
//
// @WARNING: caller MUST pass a ctx with a deadline -- the poll loop
// has no maxWait of its own.
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
		select {
		case <-ctx.Done():
			_ = f.Close()
			return nil, ctx.Err()
		case <-time.After(lockPollInterval):
		}
	}
}

func releaseLock(f *os.File) {
	// fd close releases the flock (man flock(2)); LOCK_UN is
	// belt-and-suspenders.
	_ = syscall.Flock(int(f.Fd()), syscall.LOCK_UN)
	_ = f.Close()
}

// Loads tokens, refreshes if expired, persists rotated set. errNotLoggedIn
// = operator must `kfactory auth login`. Refresh runs under acquireLock
// so concurrent invocations don't race on the rotated refresh_token (the
// loser uses the winner's fresh tokens via lock-then-re-read).
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

	// Re-read under lock: another process may have refreshed during wait.
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
		// IdP-rejected refresh_token (only fix: re-login) vs transient
		// failure (network, 5xx): the first burns the token at the
		// IdP, the second leaves it valid.
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

// Subprocess called by the patched opencode TUI when its bearer
// nears expiry; runs the same ensureFresh path under the cross-process
// lock. Exit codes are a cross-component contract (see exit.go); the
// TUI re-reads auth.json after this returns regardless of exit code.
//
// @WARNING: stdout MUST stay silent. The TUI captures stderr only
// (stripVTControlCharacters'd before display); stdout is inherited
// and would corrupt the alternate-screen mid-render.
func runAuthRefresh(args []string) {
	// Insurance against panic from upstream zitadel/oidc -- a multi-line
	// Go stack would otherwise land in the TUI's alternate screen as a
	// "refresh hint." os.Exit in normal paths bypasses defers; this
	// covers only the panic case.
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

// errNotLoggedIn → exitNotLoggedIn (operator must re-login),
// everything else → exitOther via fail. See exit.go.
func failAuth(err error) {
	if errors.Is(err, errNotLoggedIn) {
		fmt.Fprintln(os.Stderr, "kfactory: not logged in. run `kfactory auth login`")
		os.Exit(exitNotLoggedIn)
	}
	fail("auth: %v", err)
}
