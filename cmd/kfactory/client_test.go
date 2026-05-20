package main

import (
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
