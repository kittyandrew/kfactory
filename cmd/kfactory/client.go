// HTTP client for the factory's /experimental/workspace + /session APIs.
// All methods carry a bearer token from the persisted token file (auto-
// refreshing 30s before expiry via ensureFresh).
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"time"
)

// serverFor returns the factory base URL from the persisted auth.json,
// or the baked default if no token file exists.
func serverFor(t *tokenFile) string {
	if t != nil && t.Server != "" {
		return strings.TrimRight(t.Server, "/")
	}
	return defaultServer
}

// Workspace mirrors the WorkspaceInfo shape returned by opencode's
// /experimental/workspace endpoint. Only the fields kfactory consumes;
// unknown fields are dropped by the json decoder.
type Workspace struct {
	ID        string `json:"id"`
	Type      string `json:"type"`
	Name      string `json:"name"`
	Directory string `json:"directory"`
	ProjectID string `json:"projectID"`
	TimeUsed  int64  `json:"timeUsed"`
}

// newRequest builds an HTTP request with the bearer token attached when
// `t` carries one. A nil `t` (or empty AccessToken) skips the Authorization
// header -- mirrors serverFor's tolerance for unauthenticated callers, so
// future "ping the server pre-login" code paths don't nil-deref here.
// `body` may be nil for GET; for POST it's the JSON-marshaled payload.
func newRequest(ctx context.Context, t *tokenFile, server, method, path string, body any) (*http.Request, error) {
	var reader io.Reader
	if body != nil {
		b, err := json.Marshal(body)
		if err != nil {
			return nil, fmt.Errorf("marshal body: %w", err)
		}
		reader = bytes.NewReader(b)
	}
	req, err := http.NewRequestWithContext(ctx, method, server+path, reader)
	if err != nil {
		return nil, err
	}
	if t != nil && t.AccessToken != "" {
		req.Header.Set("Authorization", "Bearer "+t.AccessToken)
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	return req, nil
}

// httpClient is reused across all factory API calls so multi-call paths
// (dispatch: create workspace -> session -> prompt) get HTTP keep-alive
// instead of opening a fresh TCP connection per call.
var httpClient = &http.Client{Timeout: 60 * time.Second}

func doJSON(req *http.Request, into any) error {
	resp, err := httpClient.Do(req)
	if err != nil {
		return fmt.Errorf("%s %s: %w", req.Method, req.URL, err)
	}
	defer func() { _ = resp.Body.Close() }()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode == http.StatusUnauthorized {
		return fmt.Errorf("server returned 401; token rejected -- run `kfactory auth login`")
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("%s %s: %s: %s", req.Method, req.URL, resp.Status, strings.TrimSpace(string(body)))
	}
	if into == nil {
		return nil
	}
	if err := json.Unmarshal(body, into); err != nil {
		return fmt.Errorf("parse response: %w\nbody: %s", err, string(body))
	}
	return nil
}

// listWorkspaces fetches all workspaces.
func listWorkspaces(ctx context.Context, t *tokenFile, server string) ([]Workspace, error) {
	req, err := newRequest(ctx, t, server, http.MethodGet, "/experimental/workspace", nil)
	if err != nil {
		return nil, err
	}
	var ws []Workspace
	if err := doJSON(req, &ws); err != nil {
		return nil, err
	}
	return ws, nil
}

// createWorkspace POSTs a new kfactory workspace for the given repo URL.
// The kfactory-adapter plugin assigns the random 4-hex slug suffix; we
// don't pass branch (clone resolves to remote HEAD).
//
// `type: "kfactory"` is the WorkspaceAdapter registration key used by
// the kfactory-adapter plugin (plugins/kfactory-adapter/src/index.ts);
// opencode dispatches creation through whichever adapter registered that key.
func createWorkspace(ctx context.Context, t *tokenFile, server, repoURL string) (*Workspace, error) {
	payload := map[string]any{
		"type": "kfactory",
		"extra": map[string]any{
			"repoUrl": repoURL,
		},
	}
	req, err := newRequest(ctx, t, server, http.MethodPost, "/experimental/workspace", payload)
	if err != nil {
		return nil, err
	}
	var ws Workspace
	if err := doJSON(req, &ws); err != nil {
		return nil, err
	}
	return &ws, nil
}

// deleteWorkspace DELETEs the workspace row. The factory adapter's
// remove() callback wipes the on-disk clone; opencode drops the
// WorkspaceTable row.
func deleteWorkspace(ctx context.Context, t *tokenFile, server, id string) error {
	req, err := newRequest(ctx, t, server, http.MethodDelete, "/experimental/workspace/"+id, nil)
	if err != nil {
		return err
	}
	return doJSON(req, nil)
}

// Session is a minimal subset of opencode's session shape -- we only
// consume the id field. Everything else is opaque to kfactory.
type Session struct {
	ID string `json:"id"`
}

// createSession opens a fresh session bound to the given workspace.
// Routes via `?workspace=<id>` so opencode dispatches the create into
// the right InstanceStore context (the session row gets workspace_id = wid).
func createSession(ctx context.Context, t *tokenFile, server, workspaceID string) (*Session, error) {
	path := "/session?workspace=" + url.QueryEscape(workspaceID)
	req, err := newRequest(ctx, t, server, http.MethodPost, path, map[string]any{})
	if err != nil {
		return nil, err
	}
	var s Session
	if err := doJSON(req, &s); err != nil {
		return nil, err
	}
	return &s, nil
}

// sendPromptAsync fires a prompt at a session and returns immediately
// (server starts the model loop in the background). Use for `kfactory
// dispatch` -- operator walks away while the agent works.
//
// Payload shape mirrors opencode's PromptPayload (session.ts:66 +
// session/prompt.ts PromptInput): minimum is `{parts:[{type:"text",text}]}`.
func sendPromptAsync(ctx context.Context, t *tokenFile, server, workspaceID, sessionID, prompt string) error {
	path := "/session/" + url.PathEscape(sessionID) + "/prompt_async?workspace=" + url.QueryEscape(workspaceID)
	payload := map[string]any{
		"parts": []map[string]any{
			{"type": "text", "text": prompt},
		},
	}
	req, err := newRequest(ctx, t, server, http.MethodPost, path, payload)
	if err != nil {
		return err
	}
	return doJSON(req, nil)
}

// resolveWorkspace fetches the workspace list and delegates to findWorkspace.
func resolveWorkspace(ctx context.Context, t *tokenFile, server, ref string) (*Workspace, error) {
	ws, err := listWorkspaces(ctx, t, server)
	if err != nil {
		return nil, err
	}
	sortWorkspaces(ws)
	return findWorkspace(ws, ref)
}

// findWorkspace resolves a ref against a pre-sorted workspace slice:
//   - exact ID match (`wrk_e3d1150e2001YHvzDNcrSNPSxV`)
//   - exact slug match (`acme--widget--1144`)
//   - 1-based index into the ordered list (`1`, `2`, ...) -- same order
//     as `kfactory list`, so the operator can `kfactory list` then
//     `kfactory attach 1` without copy-pasting an id
//   - unique prefix of the slug (`acme`, `acme--widget`)
//   - unique prefix of the id (`wrk_e3d1` or just `e3d1` -- `wrk_` is
//     stripped before comparing since operators never type it)
//
// Resolution is in that order: most-specific wins. Ambiguous prefix ->
// error listing the candidates so the operator picks something narrower.
//
// @NOTE: numeric-prefix slugs are unreachable by prefix when the prefix
//
//	parses as a valid index (e.g. slug `12something--repo--1234` cannot
//	be matched by `12` when only ~10 workspaces exist -- the numeric
//	path errors "index out of range" before prefix matching runs).
//	Operators with digit-prefixed slugs must use the full slug or id.
func findWorkspace(ws []Workspace, ref string) (*Workspace, error) {
	// Exact id.
	for i := range ws {
		if ws[i].ID == ref {
			return &ws[i], nil
		}
	}
	// Exact slug.
	for i := range ws {
		if ws[i].Name == ref {
			return &ws[i], nil
		}
	}
	// 1-based index. Pure digits only -- avoid catching e.g. a slug
	// that happens to coincide with a partial number prefix.
	if n, err := strconv.Atoi(ref); err == nil {
		if n >= 1 && n <= len(ws) {
			return &ws[n-1], nil
		}
		return nil, fmt.Errorf("index %d out of range (have %d workspace%s)", n, len(ws), plural(len(ws)))
	}
	// Prefix match (slug first, then id). Ambiguous = error.
	var hits []*Workspace
	for i := range ws {
		if strings.HasPrefix(ws[i].Name, ref) {
			hits = append(hits, &ws[i])
		}
	}
	if len(hits) == 0 {
		for i := range ws {
			id := strings.TrimPrefix(ws[i].ID, "wrk_")
			if strings.HasPrefix(ws[i].ID, ref) || strings.HasPrefix(id, ref) {
				hits = append(hits, &ws[i])
			}
		}
	}
	switch len(hits) {
	case 0:
		return nil, fmt.Errorf("no workspace matches %q (try `kfactory list`)", ref)
	case 1:
		return hits[0], nil
	default:
		var names []string
		for _, h := range hits {
			names = append(names, h.Name)
		}
		return nil, fmt.Errorf("%d workspaces match %q: %s (specify a unique prefix or use the id)", len(hits), ref, strings.Join(names, ", "))
	}
}

// sortWorkspaces orders by id ascending. opencode mints workspace ids
// with a monotonic-prefix scheme (Identifier.ascending in opencode's
// id/id.ts), so lexicographic id sort = creation order, oldest first.
// This is stable across runs: an existing workspace's index in
// `kfactory list` never changes; only newly created ones get appended at
// the bottom. Don't sort by timeUsed -- last-touched changes every
// time the operator opens a session, so today's `attach 1` would be
// tomorrow's `attach 3`.
func sortWorkspaces(ws []Workspace) {
	sort.Slice(ws, func(i, j int) bool {
		return ws[i].ID < ws[j].ID
	})
}
