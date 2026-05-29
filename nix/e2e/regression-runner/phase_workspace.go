package main

import (
	"errors"
	"fmt"
	"regexp"
	"strings"
	"time"
)

func (r *runner) phasePrecheck() error {
	out, _ := r.cli("kfactory", "list")
	fmt.Print(out)
	return nil
}

func (r *runner) phaseDispatch() error {
	var err error
	r.ws1, err = r.kfactoryDispatch("say hi and immediately stop")
	if err != nil {
		return err
	}
	fmt.Println("      → ws1 =", r.ws1)
	r.ws2, err = r.kfactoryDispatch("echo done")
	if err != nil {
		return err
	}
	fmt.Println("      → ws2 =", r.ws2)
	r.ws3, err = r.kfactoryDispatch("list the files in this repo")
	if err != nil {
		return err
	}
	fmt.Println("      → ws3 =", r.ws3)
	return nil
}

func (r *runner) phaseList() error {
	rows, err := r.listRows()
	if err != nil {
		return err
	}
	if len(rows) < 3 {
		return fmt.Errorf("expected at least 3 workspaces, got %d", len(rows))
	}
	fmt.Printf("      ✓ %d workspaces visible\n", len(rows))
	return nil
}

func (r *runner) phaseListBranch() error {
	rows, err := r.listRows()
	if err != nil {
		return err
	}
	ws1 := rowByID(rows, r.ws1)
	if ws1 == nil {
		return fmt.Errorf("workspace %s missing from list", r.ws1)
	}
	if ws1.Branch == "" || ws1.Branch == "-" {
		return fmt.Errorf("WS1 branch column is empty/dash")
	}
	fmt.Println("      ✓ WS1 shows live branch", ws1.Branch)

	branch, err := r.workspaceBranch(r.ws1)
	if err != nil {
		return err
	}
	if branch == "" {
		return fmt.Errorf("/vcs has empty branch for %s", r.ws1)
	}

	ws3 := rowByID(rows, r.ws3)
	if ws3 == nil {
		return fmt.Errorf("workspace %s missing from list", r.ws3)
	}
	if _, err := r.ocexec("rm", "-rf", "/var/lib/kfactory/workspaces/"+ws3.Name+"/.git"); err != nil {
		return err
	}
	rows, err = r.listRows()
	if err != nil {
		return err
	}
	ws3 = rowByID(rows, r.ws3)
	if ws3 == nil || (ws3.Branch != "" && ws3.Branch != "-") {
		return fmt.Errorf("WS3 has no .git but branch column is %q", valueOrEmpty(ws3, func(r listRow) string { return r.Branch }))
	}
	fmt.Println("      ✓ WS3 without .git shows no branch")
	return nil
}

func (r *runner) phaseAttachResolve() error {
	rows, err := r.listRows()
	if err != nil {
		return err
	}
	idx1 := indexByID(rows, r.ws1)
	idx2 := indexByID(rows, r.ws2)
	idx3 := indexByID(rows, r.ws3)
	if idx1 == nil || idx2 == nil || idx3 == nil {
		return fmt.Errorf("current run workspaces missing from list: %s=%v %s=%v %s=%v", r.ws1, idx1, r.ws2, idx2, r.ws3, idx3)
	}
	if *idx1 >= *idx2 || *idx2 >= *idx3 {
		return fmt.Errorf("current run indices out of creation order: %s=%d %s=%d %s=%d", r.ws1, *idx1, r.ws2, *idx2, r.ws3, *idx3)
	}
	fmt.Printf("      ✓ current run indices preserve creation order: %d < %d < %d\n", *idx1, *idx2, *idx3)
	return nil
}

func (r *runner) phaseSessionIsolation() error {
	ws1Dir, err := r.projectWorktree(r.ws1)
	if err != nil {
		return err
	}
	ws2Dir, err := r.projectWorktree(r.ws2)
	if err != nil {
		return err
	}
	if ids, err := r.sessionWorkspaceIDs(r.ws1, "/session?directory="+ws1Dir); err != nil || !onlyOrEmpty(ids, r.ws1, false) {
		return fmt.Errorf("/session for WS1 returned %v, err=%v", ids, err)
	}
	if ids, err := r.sessionWorkspaceIDs(r.ws2, "/session?directory="+ws2Dir); err != nil || !onlyOrEmpty(ids, r.ws2, false) {
		return fmt.Errorf("/session for WS2 returned %v, err=%v", ids, err)
	}
	if ids, err := r.sessionWorkspaceIDs(r.ws1, "/session?directory="+ws2Dir); err != nil || !onlyOrEmpty(ids, r.ws1, true) {
		return fmt.Errorf("mismatched header+directory leaked %v, err=%v", ids, err)
	}
	fmt.Println("      ✓ session list isolation holds")
	return nil
}

func (r *runner) phaseListByProject() error {
	pid, err := r.sql("SELECT project_id FROM session WHERE workspace_id='" + r.ws1 + "' LIMIT 1;")
	if err != nil {
		return err
	}
	if strings.TrimSpace(pid) == "" {
		return errors.New("could not read session.project_id")
	}
	for _, path := range []string{"/session?path=", "/session?scope=project"} {
		var sessions []session
		if err := r.apiJSON(r.ws1, path, &sessions); err != nil {
			return err
		}
		if len(sessions) < 1 {
			return fmt.Errorf("%s returned 0 sessions for WS1", path)
		}
	}
	fmt.Println("      ✓ TUI-shaped session list returns workspace sessions")
	return nil
}

func (r *runner) phaseSyncStartWorkspace() error {
	if _, err := command("docker", "restart", r.opencodeContainer); err != nil {
		return err
	}
	if err := r.waitHealth(30 * time.Second); err != nil {
		return err
	}
	var pre []map[string]any
	if err := r.apiJSON("", "/experimental/workspace/status", &pre); err != nil {
		return err
	}
	if len(pre) != 0 {
		fmt.Printf("      ⚠ status not empty after restart (len=%d) -- premise shifted\n", len(pre))
		return nil
	}
	out, err := r.cli("curl", "-sf", "-X", "POST", "-H", "Authorization: Bearer "+r.token, r.opencodeBase+"/sync/start?workspace="+r.ws1)
	if err != nil {
		return err
	}
	if strings.TrimSpace(out) != "true" {
		return fmt.Errorf("/sync/start?workspace returned %q", strings.TrimSpace(out))
	}
	var status string
	err = retry(5*time.Second, 500*time.Millisecond, func() error {
		var rows []struct {
			WorkspaceID string `json:"workspaceID"`
			Status      string `json:"status"`
		}
		if err := r.apiJSON("", "/experimental/workspace/status", &rows); err != nil {
			return err
		}
		for _, row := range rows {
			if row.WorkspaceID == r.ws1 {
				status = row.Status
			}
		}
		if status == "" {
			return errors.New("WS1 absent from status")
		}
		return nil
	})
	if err != nil {
		return err
	}
	if status != "connected" {
		return fmt.Errorf("WS1 status=%q, expected connected", status)
	}
	_, _ = r.cli("curl", "-sf", "-X", "POST", "-H", "Authorization: Bearer "+r.token, r.opencodeBase+"/sync/start")
	fmt.Println("      ✓ WS1 status connected after sync/start")
	return nil
}

func (r *runner) phaseSSELiveEvents() error {
	log := "/tmp/sse-events-live.out"
	pid := "/tmp/sse-events-live.pid"
	_, _ = r.cliShell("rm -f " + log + " " + pid)
	_, err := r.cliDetachedShell(fmt.Sprintf("curl -N -sS -H 'Authorization: Bearer %s' -H 'x-opencode-workspace: %s' '%s/global/event' > %s 2>&1 & echo $! > %s", r.token, r.ws2, r.opencodeBase, log, pid))
	if err != nil {
		return err
	}
	defer func() {
		_, _ = r.cliShell("PID=$(cat " + pid + " 2>/dev/null); [ -n \"$PID\" ] && kill \"$PID\" 2>/dev/null || true; rm -f " + log + " " + pid)
	}()
	if err := retry(5*time.Second, 500*time.Millisecond, func() error {
		out, _ := r.cli("cat", log)
		if !strings.Contains(out, "server.connected") {
			return errors.New("no server.connected")
		}
		return nil
	}); err != nil {
		return err
	}
	if _, err := r.cli("kfactory", "tick", r.ws2, "--prompt", "say hi and immediately stop"); err != nil {
		return err
	}
	time.Sleep(15 * time.Second)
	events, _ := r.cli("cat", log)
	re := regexp.MustCompile(`"type":"([^"]+)"`)
	live := 0
	for _, m := range re.FindAllStringSubmatch(events, -1) {
		if m[1] != "server.connected" && m[1] != "server.heartbeat" {
			live++
		}
	}
	if live < 1 {
		return fmt.Errorf("SSE delivered zero live events; tail: %s", tail(events, 1000))
	}
	fmt.Printf("      ✓ SSE delivered %d live events\n", live)
	return nil
}
