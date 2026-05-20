package main

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"
)

// fakeIdP serves the OIDC discovery + token endpoints kfactory hits
// during a refresh round-trip. Behavior is steered by setting the
// `tokenHandler` field; each test installs the response shape it wants.
//
// Implements only the surface NewRelyingPartyOIDC needs: discovery doc
// pointing at /token, and a /token POST handler that either returns a
// fresh token response or an OAuth error payload.
type fakeIdP struct {
	srv          *httptest.Server
	tokenCalls   atomic.Int32
	tokenHandler func(w http.ResponseWriter, r *http.Request) // installed by each test
}

func newFakeIdP(t *testing.T) *fakeIdP {
	t.Helper()
	f := &fakeIdP{}
	mux := http.NewServeMux()
	mux.HandleFunc("/.well-known/openid-configuration", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		issuer := f.srv.URL
		_ = json.NewEncoder(w).Encode(map[string]any{
			"issuer":                                issuer,
			"authorization_endpoint":                issuer + "/authorize",
			"token_endpoint":                        issuer + "/token",
			"device_authorization_endpoint":         issuer + "/device",
			"userinfo_endpoint":                     issuer + "/userinfo",
			"jwks_uri":                              issuer + "/jwks",
			"response_types_supported":              []string{"code"},
			"subject_types_supported":               []string{"public"},
			"id_token_signing_alg_values_supported": []string{"RS256"},
			"grant_types_supported":                 []string{"authorization_code", "refresh_token", "urn:ietf:params:oauth:grant-type:device_code"},
		})
	})
	mux.HandleFunc("/token", func(w http.ResponseWriter, r *http.Request) {
		f.tokenCalls.Add(1)
		if f.tokenHandler != nil {
			f.tokenHandler(w, r)
			return
		}
		http.Error(w, "no handler installed", http.StatusInternalServerError)
	})
	mux.HandleFunc("/jwks", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"keys":[]}`))
	})
	f.srv = httptest.NewServer(mux)
	t.Cleanup(f.srv.Close)
	return f
}

// successResponse writes an OAuth2 token response with rotated tokens.
func successResponse(w http.ResponseWriter, newAccess, newRefresh string, expiresInSec int) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{
		"access_token":  newAccess,
		"refresh_token": newRefresh,
		"token_type":    "Bearer",
		"expires_in":    expiresInSec,
	})
}

// errorResponse writes an OAuth2 error payload. error_code "invalid_grant"
// is the signal kfactory uses to classify as errNotLoggedIn.
func errorResponse(w http.ResponseWriter, status int, errorCode, desc string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(map[string]any{
		"error":             errorCode,
		"error_description": desc,
	})
}

// stagedExpiredToken writes an expired token file to the temp config dir
// so ensureFresh will hit the IdP.
func stagedExpiredToken(t *testing.T, idp *fakeIdP) {
	t.Helper()
	tok := &tokenFile{
		Server:       "https://factory.example",
		Issuer:       idp.srv.URL,
		ClientID:     "test-client",
		Audience:     "test-aud",
		AccessToken:  "old-at",
		RefreshToken: "old-rt",
		ExpiresAt:    time.Now().Add(-1 * time.Minute), // expired
	}
	if err := saveTokens(tok); err != nil {
		t.Fatalf("saveTokens: %v", err)
	}
}

func TestEnsureFreshRotatesOnSuccess(t *testing.T) {
	withTempHome(t)
	idp := newFakeIdP(t)
	idp.tokenHandler = func(w http.ResponseWriter, r *http.Request) {
		if err := r.ParseForm(); err != nil {
			http.Error(w, err.Error(), 400)
			return
		}
		if r.PostForm.Get("grant_type") != "refresh_token" {
			http.Error(w, "wrong grant_type", 400)
			return
		}
		if r.PostForm.Get("refresh_token") != "old-rt" {
			http.Error(w, "wrong refresh_token", 400)
			return
		}
		successResponse(w, "new-at", "new-rt", 3600)
	}
	stagedExpiredToken(t, idp)

	got, err := ensureFresh(context.Background())
	if err != nil {
		t.Fatalf("ensureFresh: %v", err)
	}
	if got.AccessToken != "new-at" || got.RefreshToken != "new-rt" {
		t.Fatalf("tokens not rotated: %+v", got)
	}
	if got.expired() {
		t.Fatalf("rotated token reports expired")
	}
	if n := idp.tokenCalls.Load(); n != 1 {
		t.Fatalf("expected 1 token call, got %d", n)
	}
	// File on disk should also have the rotated tokens.
	persisted, err := loadTokens()
	if err != nil {
		t.Fatalf("loadTokens: %v", err)
	}
	if persisted.AccessToken != "new-at" {
		t.Fatalf("persisted access token is stale: %s", persisted.AccessToken)
	}
}

func TestEnsureFreshInvalidGrantToNotLoggedIn(t *testing.T) {
	withTempHome(t)
	idp := newFakeIdP(t)
	idp.tokenHandler = func(w http.ResponseWriter, r *http.Request) {
		errorResponse(w, http.StatusBadRequest, "invalid_grant", "refresh_token expired")
	}
	stagedExpiredToken(t, idp)

	_, err := ensureFresh(context.Background())
	if err == nil {
		t.Fatalf("expected error, got nil")
	}
	if !errors.Is(err, errNotLoggedIn) {
		t.Fatalf("expected errNotLoggedIn for invalid_grant, got %v", err)
	}
}

func TestEnsureFreshTransientNotNotLoggedIn(t *testing.T) {
	withTempHome(t)
	idp := newFakeIdP(t)
	idp.tokenHandler = func(w http.ResponseWriter, r *http.Request) {
		// 500 with no OAuth error envelope -- pure transient failure.
		http.Error(w, "upstream timeout", http.StatusInternalServerError)
	}
	stagedExpiredToken(t, idp)

	_, err := ensureFresh(context.Background())
	if err == nil {
		t.Fatalf("expected error, got nil")
	}
	if errors.Is(err, errNotLoggedIn) {
		t.Fatalf("transient 500 should NOT collapse to errNotLoggedIn (would burn the operator's refresh_token), got: %v", err)
	}
	// File on disk should still hold the OLD refresh_token -- transient
	// failure must not corrupt persisted state.
	persisted, err := loadTokens()
	if err != nil {
		t.Fatalf("loadTokens: %v", err)
	}
	if persisted.RefreshToken != "old-rt" {
		t.Fatalf("refresh_token rotated on transient failure: %s", persisted.RefreshToken)
	}
}

// @NOTE: deliberately no concurrent-ensureFresh race test. Proving the
// lock-then-re-read invariant (only ONE IdP call when two ensureFresh
// goroutines contend) requires deterministic synchronization that the
// production code doesn't expose. Earlier sleep-based attempts were
// flaky under CI load. The contention is exercised indirectly by
// TestAcquireLockContention + TestAcquireLockAllWaitersEventuallyWin
// (in auth_test.go). Don't reintroduce a sleep-based variant here.

func TestEnsureFreshNotExpiredSkipsLockAndIdP(t *testing.T) {
	withTempHome(t)
	idp := newFakeIdP(t)
	idp.tokenHandler = func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "should not be called", 500)
	}
	// Fresh token; should short-circuit before touching the lock or IdP.
	tok := &tokenFile{
		Server: "https://factory.example", Issuer: idp.srv.URL,
		ClientID: "c", Audience: "a",
		AccessToken: "fresh-at", RefreshToken: "fresh-rt",
		ExpiresAt: time.Now().Add(1 * time.Hour),
	}
	if err := saveTokens(tok); err != nil {
		t.Fatalf("saveTokens: %v", err)
	}
	got, err := ensureFresh(context.Background())
	if err != nil {
		t.Fatalf("ensureFresh: %v", err)
	}
	if got.AccessToken != "fresh-at" {
		t.Fatalf("got %s", got.AccessToken)
	}
	if n := idp.tokenCalls.Load(); n != 0 {
		t.Fatalf("fresh-token path hit IdP %d times", n)
	}
}
