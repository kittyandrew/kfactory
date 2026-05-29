package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// fixture used across findWorkspace tests. Order matters: caller sorts
// before delegating, so tests pre-sort to match production behavior.
func sampleWorkspaces() []Workspace {
	ws := []Workspace{
		{ID: "wrk_aaaa1111", Name: "acme--widget--1111"},
		{ID: "wrk_bbbb2222", Name: "acme--gadget--2222"},
		{ID: "wrk_cccc3333", Name: "other--thing--3333"},
	}
	sortWorkspaces(ws)
	return ws
}

func TestFindWorkspaceExactID(t *testing.T) {
	ws := sampleWorkspaces()
	got, err := findWorkspace(ws, "wrk_bbbb2222")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got.Name != "acme--gadget--2222" {
		t.Fatalf("wrong workspace: %s", got.Name)
	}
}

func TestFindWorkspaceExactSlug(t *testing.T) {
	ws := sampleWorkspaces()
	got, err := findWorkspace(ws, "other--thing--3333")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got.ID != "wrk_cccc3333" {
		t.Fatalf("wrong workspace: %s", got.ID)
	}
}

func TestFindWorkspaceNumericIndex(t *testing.T) {
	ws := sampleWorkspaces()
	// Sorted by id ascending: aaaa, bbbb, cccc.
	got, err := findWorkspace(ws, "2")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got.ID != "wrk_bbbb2222" {
		t.Fatalf("index 2 should be bbbb, got %s", got.ID)
	}
}

func TestFindWorkspaceIndexOutOfRange(t *testing.T) {
	ws := sampleWorkspaces()
	_, err := findWorkspace(ws, "99")
	if err == nil || !strings.Contains(err.Error(), "out of range") {
		t.Fatalf("expected out-of-range error, got %v", err)
	}
}

func TestFindWorkspaceSlugPrefix(t *testing.T) {
	ws := sampleWorkspaces()
	// "other" is a unique slug prefix.
	got, err := findWorkspace(ws, "other")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got.ID != "wrk_cccc3333" {
		t.Fatalf("wrong workspace: %s", got.ID)
	}
}

func TestFindWorkspaceAmbiguousSlugPrefix(t *testing.T) {
	ws := sampleWorkspaces()
	// "acme" matches both acme--widget and acme--gadget -> ambiguous.
	_, err := findWorkspace(ws, "acme")
	if err == nil {
		t.Fatalf("expected ambiguity error")
	}
	if !strings.Contains(err.Error(), "2 workspaces match") {
		t.Fatalf("expected 'N workspaces match' message, got %q", err.Error())
	}
}

func TestFindWorkspaceIDPrefixStripsWrk(t *testing.T) {
	ws := sampleWorkspaces()
	// operator never types "wrk_"; the prefix is stripped before comparing.
	got, err := findWorkspace(ws, "cccc")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got.ID != "wrk_cccc3333" {
		t.Fatalf("wrong workspace: %s", got.ID)
	}
}

func TestFindWorkspaceNumericIDPrefixBeatsIndex(t *testing.T) {
	for index := 2; index <= 50; index++ {
		index := index
		t.Run(fmt.Sprintf("%03d", index), func(t *testing.T) {
			ref := fmt.Sprintf("%03d", index)
			targetID := "wrk_" + ref + "abcdef"

			ws := []Workspace{{ID: targetID, Name: "target--repo--0000"}}
			for i := 0; i < index+2; i++ {
				ws = append(ws, Workspace{
					ID:   fmt.Sprintf("wrk_a%08x", i),
					Name: fmt.Sprintf("other--repo--%04x", i),
				})
			}
			sortWorkspaces(ws)

			got, err := findWorkspace(ws, ref)
			if err != nil {
				t.Fatal(err)
			}
			if got == nil || got.ID != targetID {
				t.Fatalf("findWorkspace(%q) = %#v, want %s", ref, got, targetID)
			}
		})
	}
}

func TestFindWorkspaceAmbiguousNumericIDPrefixDoesNotFallBackToIndex(t *testing.T) {
	ws := []Workspace{
		{ID: "wrk_0042aaaa", Name: "alpha--repo--aaaa"},
		{ID: "wrk_0042bbbb", Name: "beta--repo--bbbb"},
	}
	for i := 0; i < 45; i++ {
		ws = append(ws, Workspace{ID: fmt.Sprintf("wrk_a%08x", i), Name: fmt.Sprintf("other--repo--%04x", i)})
	}
	sortWorkspaces(ws)

	_, err := findWorkspace(ws, "0042")
	if err == nil || !strings.Contains(err.Error(), "workspaces match") {
		t.Fatalf("expected numeric ID-prefix ambiguity, got %v", err)
	}
}

func TestFindWorkspaceIDPrefixWithWrk(t *testing.T) {
	ws := sampleWorkspaces()
	got, err := findWorkspace(ws, "wrk_aaaa")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got.ID != "wrk_aaaa1111" {
		t.Fatalf("wrong workspace: %s", got.ID)
	}
}

func TestFindWorkspaceNoMatch(t *testing.T) {
	ws := sampleWorkspaces()
	_, err := findWorkspace(ws, "nonexistent")
	if err == nil || !strings.Contains(err.Error(), "no workspace matches") {
		t.Fatalf("expected no-match error, got %v", err)
	}
}

func TestFindWorkspaceExactBeatsPrefix(t *testing.T) {
	// If an exact slug ALSO is a prefix of another slug, exact wins.
	ws := []Workspace{
		{ID: "wrk_aaaa1111", Name: "acme"},
		{ID: "wrk_bbbb2222", Name: "acme--widget"},
	}
	sortWorkspaces(ws)
	got, err := findWorkspace(ws, "acme")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got.ID != "wrk_aaaa1111" {
		t.Fatalf("exact match should win; got %s", got.ID)
	}
}

func TestSortWorkspacesByIDAscending(t *testing.T) {
	ws := []Workspace{
		{ID: "wrk_cccc"},
		{ID: "wrk_aaaa"},
		{ID: "wrk_bbbb"},
	}
	sortWorkspaces(ws)
	if ws[0].ID != "wrk_aaaa" || ws[1].ID != "wrk_bbbb" || ws[2].ID != "wrk_cccc" {
		t.Fatalf("wrong sort order: %v", ws)
	}
}

func TestWorkspaceDirtyUsesVcsStatus(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/vcs/status" {
			http.NotFound(w, r)
			return
		}
		if got := r.URL.Query().Get("workspace"); got != "wrk_test" {
			t.Fatalf("workspace query = %q, want wrk_test", got)
		}
		_, _ = w.Write([]byte(`[{"file":"dirty.txt","additions":1,"deletions":0,"status":"added"}]`))
	}))
	defer server.Close()

	dirty, err := workspaceDirty(context.Background(), nil, server.URL, "wrk_test")
	if err != nil {
		t.Fatal(err)
	}
	if !dirty {
		t.Fatal("workspaceDirty() = false, want true")
	}
}

func TestCreateWorkspaceWithStableIDSendsStableWorkspaceIDAndSlugSuffix(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost || r.URL.Path != "/experimental/workspace" {
			t.Fatalf("unexpected request %s %s", r.Method, r.URL.Path)
		}
		var payload struct {
			ID    string `json:"id"`
			Type  string `json:"type"`
			Extra struct {
				RepoURL    string `json:"repoUrl"`
				SlugSuffix string `json:"slugSuffix"`
			} `json:"extra"`
		}
		if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
			t.Fatal(err)
		}
		if payload.ID != scheduledWorkspaceID("7a3f") {
			t.Fatalf("id = %q, want %q", payload.ID, scheduledWorkspaceID("7a3f"))
		}
		if payload.Type != "kfactory" || payload.Extra.RepoURL != "file:///repo" {
			t.Fatalf("unexpected payload: %#v", payload)
		}
		if payload.Extra.SlugSuffix != "7a3f" {
			t.Fatalf("slugSuffix = %q, want 7a3f", payload.Extra.SlugSuffix)
		}
		_ = json.NewEncoder(w).Encode(Workspace{ID: payload.ID, Name: "owner--repo--7a3f"})
	}))
	defer server.Close()

	ws, err := createWorkspaceWithStableID(context.Background(), nil, server.URL, "file:///repo", "7a3f")
	if err != nil {
		t.Fatal(err)
	}
	if ws.ID != scheduledWorkspaceID("7a3f") {
		t.Fatalf("workspace id = %q, want %q", ws.ID, scheduledWorkspaceID("7a3f"))
	}
}

func TestCreateWorkspaceWithStableIDDoesNotReuseSuffixOnlyWorkspaceAfterDuplicateError(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.Method == http.MethodPost && r.URL.Path == "/experimental/workspace":
			http.Error(w, "UNIQUE constraint failed: workspace.id", http.StatusInternalServerError)
		case r.Method == http.MethodGet && r.URL.Path == "/experimental/workspace":
			_ = json.NewEncoder(w).Encode([]Workspace{{ID: "wrk_legacy", Name: "owner--repo--7a3f"}})
		default:
			t.Fatalf("unexpected request %s %s", r.Method, r.URL.Path)
		}
	}))
	defer server.Close()

	_, err := createWorkspaceWithStableID(context.Background(), nil, server.URL, "file:///repo", "7a3f")
	if err == nil {
		t.Fatal("expected create error when stable workspace ID is absent")
	}
}

func TestCreateWorkspaceWithStableIDFailsClosedAfterCreateError(t *testing.T) {
	requestedList := false
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.Method == http.MethodPost && r.URL.Path == "/experimental/workspace":
			http.Error(w, "UNIQUE constraint failed: workspace.id", http.StatusInternalServerError)
		case r.Method == http.MethodGet && r.URL.Path == "/experimental/workspace":
			requestedList = true
			_ = json.NewEncoder(w).Encode([]Workspace{{ID: scheduledWorkspaceID("7a3f"), Name: "owner--repo--7a3f"}})
		default:
			t.Fatalf("unexpected request %s %s", r.Method, r.URL.Path)
		}
	}))
	defer server.Close()

	_, err := createWorkspaceWithStableID(context.Background(), nil, server.URL, "file:///repo", "7a3f")
	if err == nil {
		t.Fatal("expected create error")
	}
	if requestedList {
		t.Fatal("createWorkspaceWithStableID listed workspaces after failed create")
	}
}

func TestWorkspaceDirtyTreatsEmptyVcsStatusAsClean(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/vcs/status" {
			t.Fatalf("unexpected path %s", r.URL.Path)
		}
		_, _ = w.Write([]byte(`[]`))
	}))
	defer server.Close()

	dirty, err := workspaceDirty(context.Background(), nil, server.URL, "wrk_test")
	if err != nil {
		t.Fatal(err)
	}
	if dirty {
		t.Fatal("workspaceDirty() = true for empty status, want false")
	}
}

func TestWorkspaceDirtyFailsOnVcsStatusError(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "vcs unavailable", http.StatusInternalServerError)
	}))
	defer server.Close()

	dirty, err := workspaceDirty(context.Background(), nil, server.URL, "wrk_test")
	if err == nil {
		t.Fatal("workspaceDirty error = nil, want error")
	}
	if dirty {
		t.Fatal("workspaceDirty dirty = true on status error, want false with error")
	}
}

func TestEnrichWorkspaceBranchesUsesRoutedVcsEndpoint(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/vcs" {
			t.Fatalf("unexpected path %s", r.URL.Path)
		}
		if got := r.URL.Query().Get("workspace"); got != "wrk_test" {
			t.Fatalf("workspace query = %q, want wrk_test", got)
		}
		_ = json.NewEncoder(w).Encode(vcsInfo{Branch: "main"})
	}))
	defer server.Close()

	ws := []Workspace{{ID: "wrk_test", Branch: ""}}
	enrichWorkspaceBranches(context.Background(), nil, server.URL, ws)
	if ws[0].Branch != "main" {
		t.Fatalf("Branch = %q, want main", ws[0].Branch)
	}
}
