package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/zitadel/oidc/v3/pkg/oidc"
)

func TestTokenFileExpired(t *testing.T) {
	now := time.Now()

	cases := []struct {
		name string
		exp  time.Time
		want bool
	}{
		{"future, comfortably fresh", now.Add(1 * time.Hour), false},
		{"future, inside 30s skew", now.Add(20 * time.Second), true},
		{"future, exactly 30s away", now.Add(30 * time.Second), true},
		{"already past", now.Add(-1 * time.Minute), true},
		{"zero value", time.Time{}, true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			tok := &tokenFile{ExpiresAt: tc.exp}
			if got := tok.expired(); got != tc.want {
				t.Errorf("expired()=%v want %v", got, tc.want)
			}
		})
	}
}

// withTempHome points os.UserConfigDir() at a temp dir for the duration
// of the test by setting XDG_CONFIG_HOME (Linux) and HOME (fallback).
func withTempHome(t *testing.T) string {
	t.Helper()
	tmp := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", tmp)
	t.Setenv("HOME", tmp)
	return tmp
}

func TestAcquireLockCtxCancel(t *testing.T) {
	withTempHome(t)

	// Hold the lock on a background fd.
	f1, err := acquireLock(context.Background())
	if err != nil {
		t.Fatalf("first acquire: %v", err)
	}
	defer releaseLock(f1)

	// Second acquire with a short ctx must return ctx.Err() promptly
	// (not block until the holder releases).
	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()
	start := time.Now()
	f2, err := acquireLock(ctx)
	elapsed := time.Since(start)
	if err == nil {
		releaseLock(f2)
		t.Fatalf("expected ctx-cancel error while holder still holds")
	}
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("expected DeadlineExceeded, got %v", err)
	}
	// Allow up to one poll interval of slack on the cancel responsiveness.
	if elapsed > 100*time.Millisecond+lockPollInterval+50*time.Millisecond {
		t.Fatalf("ctx-cancel took %v; expected ~100ms (poll interval %v)", elapsed, lockPollInterval)
	}
}

func TestAcquireLockContention(t *testing.T) {
	withTempHome(t)

	ctx := context.Background()
	f1, err := acquireLock(ctx)
	if err != nil {
		t.Fatalf("first acquire: %v", err)
	}

	// Second acquire from a goroutine should block while f1 holds the lock.
	type result struct {
		f   *os.File
		err error
	}
	resCh := make(chan result, 1)
	go func() {
		f, err := acquireLock(ctx)
		resCh <- result{f, err}
	}()

	// Confirm the second acquire is blocked.
	select {
	case r := <-resCh:
		if r.err == nil {
			releaseLock(r.f)
		}
		t.Fatalf("second acquire did not block while first held lock: err=%v", r.err)
	case <-time.After(150 * time.Millisecond):
		// good: blocked as expected
	}

	// Release f1; the second acquire should complete shortly after.
	releaseLock(f1)
	select {
	case r := <-resCh:
		if r.err != nil {
			t.Fatalf("second acquire errored after release: %v", r.err)
		}
		releaseLock(r.f)
	case <-time.After(2 * time.Second):
		t.Fatalf("second acquire did not complete after release")
	}
}

func TestAcquireLockReleaseAndReacquire(t *testing.T) {
	withTempHome(t)

	ctx := context.Background()
	f1, err := acquireLock(ctx)
	if err != nil {
		t.Fatalf("first acquire: %v", err)
	}
	releaseLock(f1)

	// After release, a second acquire must succeed promptly.
	ctx2, cancel := context.WithTimeout(context.Background(), 500*time.Millisecond)
	defer cancel()
	f2, err := acquireLock(ctx2)
	if err != nil {
		t.Fatalf("reacquire after release: %v", err)
	}
	releaseLock(f2)
}

func TestAcquireLockAllWaitersEventuallyWin(t *testing.T) {
	withTempHome(t)

	ctx := context.Background()
	f1, err := acquireLock(ctx)
	if err != nil {
		t.Fatalf("first acquire: %v", err)
	}

	const N = 3
	var winners int32
	done := make(chan struct{}, N)
	for i := 0; i < N; i++ {
		go func() {
			defer func() { done <- struct{}{} }()
			f, err := acquireLock(ctx)
			if err == nil {
				atomic.AddInt32(&winners, 1)
				releaseLock(f)
			}
		}()
	}

	// Release after a brief hold; each waiter acquires, releases, hands
	// off to the next.
	time.Sleep(50 * time.Millisecond)
	releaseLock(f1)

	for i := 0; i < N; i++ {
		select {
		case <-done:
		case <-time.After(2 * time.Second):
			t.Fatalf("only %d/%d waiters finished within deadline", i, N)
		}
	}
	if atomic.LoadInt32(&winners) != int32(N) {
		t.Fatalf("expected %d waiters to win, got %d", N, winners)
	}
}

func TestLockFilePath(t *testing.T) {
	tmp := withTempHome(t)
	lp, err := lockFilePath()
	if err != nil {
		t.Fatalf("lockFilePath: %v", err)
	}
	want := filepath.Join(tmp, "kfactory", "auth.json.lock")
	if lp != want {
		t.Fatalf("lockFilePath=%s want %s", lp, want)
	}
}

func TestSaveAndLoadTokensRoundTrip(t *testing.T) {
	withTempHome(t)

	in := &tokenFile{
		Server:       "https://example.com",
		Issuer:       "https://auth.example.com",
		ClientID:     "abc",
		Audience:     "def",
		AccessToken:  "at",
		RefreshToken: "rt",
		ExpiresAt:    time.Now().Add(1 * time.Hour).UTC().Round(time.Second),
	}
	if err := saveTokens(in); err != nil {
		t.Fatalf("saveTokens: %v", err)
	}
	out, err := loadTokens()
	if err != nil {
		t.Fatalf("loadTokens: %v", err)
	}
	if out.Server != in.Server || out.AccessToken != in.AccessToken ||
		out.RefreshToken != in.RefreshToken || !out.ExpiresAt.Equal(in.ExpiresAt) {
		t.Fatalf("round-trip mismatch: in=%+v out=%+v", in, out)
	}

	// Confirm file mode is 0600 (token file may contain a refresh token).
	p, _ := tokenPath()
	info, err := os.Stat(p)
	if err != nil {
		t.Fatalf("stat: %v", err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("token file mode=%o want 0600", info.Mode().Perm())
	}
}

func TestSaveTokensWaitsForAuthLock(t *testing.T) {
	withTempHome(t)
	lock, err := acquireLock(context.Background())
	if err != nil {
		t.Fatalf("acquire lock: %v", err)
	}

	tok := &tokenFile{
		Server:       "https://example.com",
		Issuer:       "https://auth.example.com",
		ClientID:     "abc",
		Audience:     "def",
		AccessToken:  "at",
		RefreshToken: "rt",
		ExpiresAt:    time.Now().Add(time.Hour),
	}
	done := make(chan error, 1)
	go func() { done <- saveTokens(tok) }()

	select {
	case err := <-done:
		releaseLock(lock)
		t.Fatalf("saveTokens completed while auth lock was held: %v", err)
	case <-time.After(150 * time.Millisecond):
	}
	releaseLock(lock)

	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("saveTokens after lock release: %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("saveTokens did not complete after auth lock release")
	}
}

func TestDeleteTokensWaitsForAuthLock(t *testing.T) {
	withTempHome(t)
	tok := &tokenFile{
		Server:       "https://example.com",
		Issuer:       "https://auth.example.com",
		ClientID:     "abc",
		Audience:     "def",
		AccessToken:  "at",
		RefreshToken: "rt",
		ExpiresAt:    time.Now().Add(time.Hour),
	}
	if err := saveTokens(tok); err != nil {
		t.Fatalf("saveTokens: %v", err)
	}
	lock, err := acquireLock(context.Background())
	if err != nil {
		t.Fatalf("acquire lock: %v", err)
	}

	done := make(chan error, 1)
	go func() { done <- deleteTokens() }()

	select {
	case err := <-done:
		releaseLock(lock)
		t.Fatalf("deleteTokens completed while auth lock was held: %v", err)
	case <-time.After(150 * time.Millisecond):
	}
	releaseLock(lock)

	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("deleteTokens after lock release: %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("deleteTokens did not complete after auth lock release")
	}
}

func TestLoadTokensRequiresExactSchemaVersion(t *testing.T) {
	withTempHome(t)
	p, err := tokenPath()
	if err != nil {
		t.Fatalf("tokenPath: %v", err)
	}
	if err := os.MkdirAll(filepath.Dir(p), 0o700); err != nil {
		t.Fatalf("mkdir token dir: %v", err)
	}

	base := tokenFile{
		Server:       "https://example.com",
		Issuer:       "https://auth.example.com",
		ClientID:     "abc",
		Audience:     "def",
		AccessToken:  "at",
		RefreshToken: "rt",
		ExpiresAt:    time.Now().Add(time.Hour),
	}

	for _, schemaVersion := range []int{0, authFileSchemaVersion + 1} {
		t.Run(fmt.Sprintf("schema %d", schemaVersion), func(t *testing.T) {
			out := base
			out.SchemaVersion = schemaVersion
			b, err := json.Marshal(out)
			if err != nil {
				t.Fatalf("marshal: %v", err)
			}
			if err := os.WriteFile(p, b, 0o600); err != nil {
				t.Fatalf("write auth file: %v", err)
			}
			_, err = loadTokens()
			if err == nil || !strings.Contains(err.Error(), "schema_version") {
				t.Fatalf("loadTokens error=%v, want schema_version error", err)
			}
		})
	}
}

func TestLoadTokensRejectsIncompleteAuthState(t *testing.T) {
	withTempHome(t)
	p, err := tokenPath()
	if err != nil {
		t.Fatalf("tokenPath: %v", err)
	}
	if err := os.MkdirAll(filepath.Dir(p), 0o700); err != nil {
		t.Fatalf("mkdir token dir: %v", err)
	}

	base := tokenFile{
		SchemaVersion: authFileSchemaVersion,
		Server:        "https://example.com",
		Issuer:        "https://auth.example.com",
		ClientID:      "abc",
		Audience:      "def",
		AccessToken:   "at",
		RefreshToken:  "rt",
		ExpiresAt:     time.Now().Add(time.Hour),
	}
	cases := []struct {
		name string
		mut  func(*tokenFile)
		want string
	}{
		{"server", func(t *tokenFile) { t.Server = "" }, "server"},
		{"issuer", func(t *tokenFile) { t.Issuer = "" }, "issuer"},
		{"client", func(t *tokenFile) { t.ClientID = "" }, "client_id"},
		{"audience", func(t *tokenFile) { t.Audience = "" }, "audience"},
		{"access", func(t *tokenFile) { t.AccessToken = "" }, "access_token"},
		{"refresh", func(t *tokenFile) { t.RefreshToken = "" }, "refresh_token"},
		{"expiry", func(t *tokenFile) { t.ExpiresAt = time.Time{} }, "expires_at"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			out := base
			tc.mut(&out)
			b, err := json.Marshal(out)
			if err != nil {
				t.Fatalf("marshal: %v", err)
			}
			if err := os.WriteFile(p, b, 0o600); err != nil {
				t.Fatalf("write auth file: %v", err)
			}
			_, err = loadTokens()
			if err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("loadTokens error=%v, want %q", err, tc.want)
			}
		})
	}
}

func TestApplyRefreshedTokenRejectsZeroExpiry(t *testing.T) {
	tok := &tokenFile{
		AccessToken:  "old-at",
		RefreshToken: "old-rt",
		ExpiresAt:    time.Now().Add(-time.Hour),
	}
	err := applyRefreshedToken(tok, "new-at", "new-rt", time.Time{})
	if err == nil || !strings.Contains(err.Error(), "expiry") {
		t.Fatalf("applyRefreshedToken error=%v, want expiry error", err)
	}
	if tok.AccessToken != "old-at" || tok.RefreshToken != "old-rt" {
		t.Fatalf("token mutated after invalid refresh: %+v", tok)
	}
}

func TestApplyRefreshedTokenPreservesRefreshTokenWhenNotRotated(t *testing.T) {
	expiresAt := time.Now().Add(time.Hour)
	tok := &tokenFile{AccessToken: "old-at", RefreshToken: "old-rt"}
	if err := applyRefreshedToken(tok, "new-at", "", expiresAt); err != nil {
		t.Fatalf("applyRefreshedToken: %v", err)
	}
	if tok.AccessToken != "new-at" || tok.RefreshToken != "old-rt" || !tok.ExpiresAt.Equal(expiresAt) {
		t.Fatalf("unexpected token after refresh: %+v", tok)
	}
}

func TestLoginScopesIncludesAudienceScope(t *testing.T) {
	scopes := loginScopes("project123", "urn:zitadel:iam:org:project:id:%s:aud")
	want := "urn:zitadel:iam:org:project:id:project123:aud"
	found := false
	for _, s := range scopes {
		if s == want {
			found = true
		}
	}
	if !found {
		t.Fatalf("audience scope missing: %v", scopes)
	}
}

func TestLoginScopesEmptyTemplateSkipsAudience(t *testing.T) {
	scopes := loginScopes("project123", "")
	for _, s := range scopes {
		if len(s) > 4 && s[:4] == "urn:" {
			t.Fatalf("unexpected urn scope with empty template: %q", s)
		}
	}
	// openid + profile + email + offline_access remain.
	if len(scopes) != 4 {
		t.Fatalf("expected 4 base scopes, got %d: %v", len(scopes), scopes)
	}
}

func TestDeviceVerificationURLPrefersProviderCompleteURL(t *testing.T) {
	da := &oidc.DeviceAuthorizationResponse{
		UserCode:                "ABCD-EFGH",
		VerificationURI:         "https://issuer.example/device",
		VerificationURIComplete: "https://issuer.example/device?user_code=ABCD-EFGH",
	}
	got := deviceVerificationURL("https://issuer.example", da)
	if got != da.VerificationURIComplete {
		t.Fatalf("deviceVerificationURL=%q want %q", got, da.VerificationURIComplete)
	}
}

func TestDeviceVerificationURLAddsUserCodeToProviderURL(t *testing.T) {
	da := &oidc.DeviceAuthorizationResponse{
		UserCode:        "ABCD EFGH",
		VerificationURI: "https://issuer.example/device?existing=1",
	}
	got := deviceVerificationURL("https://issuer.example", da)
	want := "https://issuer.example/device?existing=1&user_code=ABCD+EFGH"
	if got != want {
		t.Fatalf("deviceVerificationURL=%q want %q", got, want)
	}
}
