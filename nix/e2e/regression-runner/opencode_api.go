package main

import (
	"encoding/json"
	"fmt"
	"sort"
	"strings"
	"time"
)

// Resolve a workspace's clone directory from its /experimental/workspace
// row. Since opencode v1.17.x every clone of the same repo shares one
// worktree-hashed project row, so deriving the directory from /project
// ("first git project's worktree") returns whichever workspace
// materialized the project first -- the workspace row is the only
// per-workspace source of truth.
func (r *runner) workspaceDirectory(workspaceID string) (string, error) {
	rows, err := r.workspaces()
	if err != nil {
		return "", err
	}
	for _, row := range rows {
		if row.ID == workspaceID && row.Directory != "" {
			return row.Directory, nil
		}
	}
	return "", fmt.Errorf("no workspace directory for %s", workspaceID)
}

func (r *runner) sessionWorkspaceIDs(workspaceID, path string) ([]string, error) {
	var sessions []session
	if err := r.apiJSON(workspaceID, path, &sessions); err != nil {
		return nil, err
	}
	set := map[string]bool{}
	for _, s := range sessions {
		if s.WorkspaceID != "" {
			set[s.WorkspaceID] = true
		}
	}
	var out []string
	for id := range set {
		out = append(out, id)
	}
	sort.Strings(out)
	return out, nil
}

func onlyOrEmpty(ids []string, want string, allowEmpty bool) bool {
	if allowEmpty && len(ids) == 0 {
		return true
	}
	return len(ids) == 1 && ids[0] == want
}

func (r *runner) workspaces() ([]workspace, error) {
	var rows []workspace
	if err := r.apiJSON("", "/experimental/workspace", &rows); err != nil {
		return nil, err
	}
	return rows, nil
}

func (r *runner) workspacesWithSuffix(suffix string) []workspace {
	rows, _ := r.workspaces()
	var out []workspace
	for _, row := range rows {
		if strings.HasSuffix(row.Name, "--"+suffix) {
			out = append(out, row)
		}
	}
	return out
}

func (r *runner) cleanupTaskSuffix(suffix string) {
	for _, row := range r.workspacesWithSuffix(suffix) {
		_, _ = r.cli("kfactory", "delete", "-y", row.ID)
	}
}

func (r *runner) slugForWorkspace(id string) (string, error) {
	rows, err := r.listRows()
	if err != nil {
		return "", err
	}
	row := rowByID(rows, id)
	if row == nil || row.Name == "" {
		return "", fmt.Errorf("no slug for %s", id)
	}
	return row.Name, nil
}

func (r *runner) rootSession(workspaceID string) (string, error) {
	var sessions []session
	if err := r.apiJSON(workspaceID, "/experimental/session?workspace="+workspaceID, &sessions); err != nil {
		return "", err
	}
	var roots []session
	for _, s := range sessions {
		if s.ParentID == "" {
			roots = append(roots, s)
		}
	}
	if len(roots) == 0 {
		return "", fmt.Errorf("no root session for %s", workspaceID)
	}
	sort.Slice(roots, func(i, j int) bool { return roots[i].Time.Updated > roots[j].Time.Updated })
	return roots[0].ID, nil
}

func (r *runner) messageCount(workspaceID, sessionID string) (int, error) {
	msgs, err := r.messages(workspaceID, sessionID)
	return len(msgs), err
}

func (r *runner) messages(workspaceID, sessionID string) ([]message, error) {
	var msgs []message
	if err := r.apiJSON(workspaceID, "/session/"+sessionID+"/message", &msgs); err != nil {
		return nil, err
	}
	return msgs, nil
}

func (r *runner) lastUserText(workspaceID, sessionID string) (string, error) {
	msgs, err := r.messages(workspaceID, sessionID)
	if err != nil {
		return "", err
	}
	for i := len(msgs) - 1; i >= 0; i-- {
		if msgs[i].Info.Role == "user" {
			return joinText(msgs[i]), nil
		}
	}
	return "", nil
}

func joinText(msg message) string {
	var parts []string
	for _, p := range msg.Parts {
		if p.Type == "text" {
			parts = append(parts, p.Text)
		}
	}
	return strings.Join(parts, "")
}

func (r *runner) workspaceDirty(id string) (string, error) {
	var status []json.RawMessage
	if err := r.apiJSON("", "/vcs/status?workspace="+id, &status); err != nil {
		return "", err
	}
	if len(status) > 0 {
		return "true", nil
	}
	return "false", nil
}

func (r *runner) workspaceBranch(id string) (string, error) {
	var info struct {
		Branch string `json:"branch"`
	}
	if err := r.apiJSON("", "/vcs?workspace="+id, &info); err != nil {
		return "", err
	}
	return info.Branch, nil
}

func (r *runner) ntfyPoll(since int64) ([]ntfyMessage, string, error) {
	url := fmt.Sprintf("%s/%s/json?poll=1&since=%d", r.ntfyInternal, r.ntfyTopic, since)
	out, err := r.cli("curl", "-sf", url)
	if err != nil {
		return nil, out, nil
	}
	var msgs []ntfyMessage
	dec := json.NewDecoder(strings.NewReader(out))
	for dec.More() {
		var msg ntfyMessage
		if err := dec.Decode(&msg); err != nil {
			return nil, out, err
		}
		msgs = append(msgs, msg)
	}
	return msgs, out, nil
}

func (r *runner) waitHealth(timeout time.Duration) error {
	return retry(timeout, time.Second, func() error {
		_, err := r.cli("curl", "-fsS", "-m", "2", r.opencodeBase+"/global/health")
		return err
	})
}

func (r *runner) apiJSON(workspaceID, path string, into any) error {
	args := []string{"curl", "-sf", "-H", "Authorization: Bearer " + r.token}
	if workspaceID != "" {
		args = append(args, "-H", "x-opencode-workspace: "+workspaceID)
	}
	out, err := r.cli(append(args, r.opencodeBase+path)...)
	if err != nil {
		return err
	}
	if err := json.Unmarshal([]byte(out), into); err != nil {
		return fmt.Errorf("decode %s: %w body=%s", path, err, tail(out, 500))
	}
	return nil
}
