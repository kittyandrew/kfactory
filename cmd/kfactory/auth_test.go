package main

import (
	"context"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"
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

func TestAcquireLockSerializesAllWaiters(t *testing.T) {
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

func TestLoginScopesIncludesAudienceScope(t *testing.T) {
	scopes := loginScopes("project123")
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
	orig := defaultAudienceScopeTemplate
	defaultAudienceScopeTemplate = ""
	defer func() { defaultAudienceScopeTemplate = orig }()

	scopes := loginScopes("project123")
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
