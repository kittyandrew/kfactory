// HTTP helpers for kfactory's opencode-facing workspace/session APIs.
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"sort"
	"strconv"
	"strings"
	"time"
)

func serverFor(t *tokenFile) string {
	if t != nil && t.Server != "" {
		return strings.TrimRight(t.Server, "/")
	}
	return os.Getenv("KFACTORY_SERVER")
}

type Workspace struct {
	ID        string `json:"id"`
	Type      string `json:"type"`
	Name      string `json:"name"`
	Branch    string `json:"branch"`
	Directory string `json:"directory"`
	ProjectID string `json:"projectID"`
	TimeUsed  int64  `json:"timeUsed"`
}

type vcsInfo struct {
	Branch string `json:"branch"`
}

// Builds an HTTP request with optional bearer (nil/empty AccessToken
// skips the header for pre-login pings) and JSON body.
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

// Shared across calls so multi-step paths (dispatch: create workspace
// -> session -> prompt) reuse keep-alive.
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

func workspaceBranch(ctx context.Context, t *tokenFile, server, workspaceID string) (string, error) {
	path := "/vcs?workspace=" + url.QueryEscape(workspaceID)
	req, err := newRequest(ctx, t, server, http.MethodGet, path, nil)
	if err != nil {
		return "", err
	}
	var info vcsInfo
	if err := doJSON(req, &info); err != nil {
		return "", err
	}
	return info.Branch, nil
}

func enrichWorkspaceBranches(ctx context.Context, t *tokenFile, server string, ws []Workspace) {
	for i := range ws {
		branch, err := workspaceBranch(ctx, t, server, ws[i].ID)
		if err == nil && branch != "" {
			ws[i].Branch = branch
		}
	}
}

func workspaceDirty(ctx context.Context, t *tokenFile, server, workspaceID string) (bool, error) {
	path := "/vcs/status?workspace=" + url.QueryEscape(workspaceID)
	req, err := newRequest(ctx, t, server, http.MethodGet, path, nil)
	if err != nil {
		return false, err
	}
	var status []json.RawMessage
	if err := doJSON(req, &status); err != nil {
		return false, err
	}
	return len(status) > 0, nil
}

// `type: "kfactory"` selects the kfactory-adapter (plugins/kfactory-
// adapter registers under that key).
func createWorkspace(ctx context.Context, t *tokenFile, server, repoURL string) (*Workspace, error) {
	return createWorkspaceWithStableID(ctx, t, server, repoURL, "")
}

func scheduledWorkspaceID(taskID string) string {
	return "wrk_kfactory_" + taskID
}

type createWorkspaceExtra struct {
	RepoURL    string `json:"repoUrl"`
	SlugSuffix string `json:"slugSuffix,omitempty"`
}

type createWorkspaceRequest struct {
	ID    string               `json:"id,omitempty"`
	Type  string               `json:"type"`
	Extra createWorkspaceExtra `json:"extra"`
}

func newCreateWorkspaceRequest(repoURL, taskID string) (createWorkspaceRequest, error) {
	payload := createWorkspaceRequest{
		Type: "kfactory",
		Extra: createWorkspaceExtra{
			RepoURL: repoURL,
		},
	}
	if taskID == "" {
		return payload, nil
	}
	if !taskIDPattern.MatchString(taskID) {
		return createWorkspaceRequest{}, fmt.Errorf("invalid scheduled task id %q", taskID)
	}
	payload.ID = scheduledWorkspaceID(taskID)
	payload.Extra.SlugSuffix = taskID
	return payload, nil
}

func createWorkspaceWithStableID(ctx context.Context, t *tokenFile, server, repoURL, taskID string) (*Workspace, error) {
	payload, err := newCreateWorkspaceRequest(repoURL, taskID)
	if err != nil {
		return nil, err
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

// Adapter's remove() wipes the on-disk clone; opencode drops the DB row.
func deleteWorkspace(ctx context.Context, t *tokenFile, server, id string) error {
	req, err := newRequest(ctx, t, server, http.MethodDelete, "/experimental/workspace/"+id, nil)
	if err != nil {
		return err
	}
	return doJSON(req, nil)
}

type Session struct {
	ID string `json:"id"`
}

// `?workspace=` routes through workspace-routing middleware so the
// session row gets workspace_id = wid (otherwise it lands in the
// front-opencode's project with no workspace binding).
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

type SessionInfo struct {
	ID          string `json:"id"`
	WorkspaceID string `json:"workspaceID"`
	ParentID    string `json:"parentID,omitempty"`
	Time        struct {
		Updated int64 `json:"updated"`
	} `json:"time"`
}

type SessionMessage struct {
	Info struct {
		Role string `json:"role"`
	} `json:"info"`
	Parts []struct {
		Type string `json:"type"`
		Text string `json:"text"`
	} `json:"parts"`
}

// Most-recent ROOT session (parentID == ""); subagent sessions excluded
// since we never want to inject the continuation prompt into a child
// agent's context. Matches opencode's `--continue` semantics.
func findMostRecentSession(ctx context.Context, t *tokenFile, server, workspaceID string) (*SessionInfo, error) {
	path := "/experimental/session?workspace=" + url.QueryEscape(workspaceID)
	req, err := newRequest(ctx, t, server, http.MethodGet, path, nil)
	if err != nil {
		return nil, err
	}
	var sessions []SessionInfo
	if err := doJSON(req, &sessions); err != nil {
		return nil, err
	}
	var best *SessionInfo
	for i := range sessions {
		if sessions[i].ParentID != "" {
			continue
		}
		if best == nil || sessions[i].Time.Updated > best.Time.Updated {
			best = &sessions[i]
		}
	}
	return best, nil
}

func listSessionMessages(ctx context.Context, t *tokenFile, server, workspaceID, sessionID string) ([]SessionMessage, error) {
	path := "/session/" + url.PathEscape(sessionID) + "/message?workspace=" + url.QueryEscape(workspaceID)
	req, err := newRequest(ctx, t, server, http.MethodGet, path, nil)
	if err != nil {
		return nil, err
	}
	var messages []SessionMessage
	if err := doJSON(req, &messages); err != nil {
		return nil, err
	}
	return messages, nil
}

func sessionMessageText(msg SessionMessage) string {
	var parts []string
	for _, part := range msg.Parts {
		if part.Type == "text" {
			parts = append(parts, part.Text)
		}
	}
	return strings.Join(parts, "")
}

// Returns immediately; server starts the model loop in the background.
// Payload mirrors PromptPayload in opencode/session.ts.
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

func resolveWorkspace(ctx context.Context, t *tokenFile, server, ref string) (*Workspace, error) {
	ws, err := listWorkspaces(ctx, t, server)
	if err != nil {
		return nil, err
	}
	sortWorkspaces(ws)
	return findWorkspace(ws, ref)
}

// Resolution order: exact ID, exact slug, 1-2 digit list index, unique slug
// prefix, unique ID prefix, then 3+ digit index fallback. Ambiguous prefixes
// report candidates.
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
	// Keep the ergonomic common case: `kfactory attach 1` means the
	// printed list index, not every workspace whose ID happens to start
	// with "1". Longer numeric refs are plausible copied ID prefixes,
	// so let prefix resolution run before falling back to index parsing.
	shortNumericIndex := len(ref) < 3
	if shortNumericIndex {
		if n, err := strconv.Atoi(ref); err == nil {
			if n >= 1 && n <= len(ws) {
				return &ws[n-1], nil
			}
			return nil, fmt.Errorf("index %d out of range (have %d workspace%s)", n, len(ws), plural(len(ws)))
		}
	}
	resolved, err := findWorkspacePrefix(ws, ref)
	if resolved != nil || err != nil {
		return resolved, err
	}
	if !shortNumericIndex {
		if n, err := strconv.Atoi(ref); err == nil {
			if n >= 1 && n <= len(ws) {
				return &ws[n-1], nil
			}
			return nil, fmt.Errorf("index %d out of range (have %d workspace%s)", n, len(ws), plural(len(ws)))
		}
	}
	return nil, fmt.Errorf("no workspace matches %q (try `kfactory list`)", ref)
}

func findWorkspacePrefix(ws []Workspace, ref string) (*Workspace, error) {
	// Slug prefix first, then id prefix.
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
		return nil, nil
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

// opencode's Identifier.ascending is monotonic-prefix, so id-lex order
// = creation order. Stable across runs (existing indices don't shift);
// sorting by timeUsed would make today's `attach 1` tomorrow's `attach 3`.
func sortWorkspaces(ws []Workspace) {
	sort.Slice(ws, func(i, j int) bool {
		return ws[i].ID < ws[j].ID
	})
}
