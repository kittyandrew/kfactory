package main

import (
	"errors"
	"fmt"
	"regexp"
	"strings"
	"time"
)

func (r *runner) phaseTickCreateOnMiss() error {
	task := "aaaa"
	r.cleanupTaskSuffix(task)
	if _, err := r.cli("mkdir", "-p", "/tmp/kfactory-scheduled"); err != nil {
		return err
	}
	config := `{"repo":"file:///srv/test-repo.git","initial_prompt":"say hi and immediately stop","continuation_prompt":"say bye and immediately stop"}`
	if _, err := r.cliShell("cat > /tmp/kfactory-scheduled/" + task + ".json <<'JSON'\n" + config + "\nJSON"); err != nil {
		return err
	}
	out, err := r.cli("env", "KFACTORY_SCHEDULED_DIR=/tmp/kfactory-scheduled", "kfactory", "tick", task)
	if err != nil {
		return err
	}
	r.tickWS, err = workspaceIDFromOutput(out)
	if err != nil {
		return err
	}
	slug, err := r.slugForWorkspace(r.tickWS)
	if err != nil {
		return err
	}
	if !strings.HasSuffix(slug, "--"+task) {
		return fmt.Errorf("slug %s does not end in --%s", slug, task)
	}
	fmt.Println("      ✓ scheduled tick created", r.tickWS, slug)
	return nil
}

func (r *runner) phaseTickModesExisting() error {
	ws := r.tickWS
	if ws == "" {
		return errors.New("phase 7 did not set tick workspace")
	}
	root, err := r.rootSession(ws)
	if err != nil {
		return err
	}
	time.Sleep(5 * time.Second)
	if err := r.writeSchedule("aaaa", "skip-if-exists"); err != nil {
		return err
	}
	before, _ := r.messageCount(ws, root)
	out, err := r.cli("env", "KFACTORY_SCHEDULED_DIR=/tmp/kfactory-scheduled", "kfactory", "tick", "aaaa")
	if err != nil {
		return err
	}
	if err := expectWorkspaceOutput("skip-if-exists", out, ws); err != nil {
		return err
	}
	time.Sleep(2 * time.Second)
	after, _ := r.messageCount(ws, root)
	if after != before {
		return fmt.Errorf("skip-if-exists appended message: %d -> %d", before, after)
	}
	if err := r.writeSchedule("aaaa", "skip-if-dirty"); err != nil {
		return err
	}
	dirty, err := r.workspaceDirty(ws)
	if err != nil || dirty != "false" {
		return fmt.Errorf("expected clean workspace, dirty=%s err=%v", dirty, err)
	}
	before, _ = r.messageCount(ws, root)
	out, err = r.cli("env", "KFACTORY_SCHEDULED_DIR=/tmp/kfactory-scheduled", "kfactory", "tick", "aaaa")
	if err != nil {
		return err
	}
	if err := expectWorkspaceOutput("skip-if-dirty clean", out, ws); err != nil {
		return err
	}
	time.Sleep(3 * time.Second)
	after, _ = r.messageCount(ws, root)
	if after <= before {
		return fmt.Errorf("skip-if-dirty clean did not append: %d -> %d", before, after)
	}
	last, _ := r.lastUserText(ws, root)
	if last != "say bye and immediately stop" {
		return fmt.Errorf("last user text=%q", last)
	}
	slug, _ := r.slugForWorkspace(ws)
	worktree := "/var/lib/kfactory/workspaces/" + slug
	if _, err := r.ocexec("sh", "-c", "echo 'untracked dirty marker' > "+worktree+"/dirty-test-marker.txt"); err != nil {
		return err
	}
	time.Sleep(time.Second)
	dirty, err = r.workspaceDirty(ws)
	if err != nil || dirty != "true" {
		return fmt.Errorf("expected dirty workspace, dirty=%s err=%v", dirty, err)
	}
	time.Sleep(4 * time.Second)
	before, _ = r.messageCount(ws, root)
	out, err = r.cli("env", "KFACTORY_SCHEDULED_DIR=/tmp/kfactory-scheduled", "kfactory", "tick", "aaaa")
	if err != nil {
		return err
	}
	if err := expectWorkspaceOutput("skip-if-dirty dirty", out, ws); err != nil {
		return err
	}
	time.Sleep(2 * time.Second)
	after, _ = r.messageCount(ws, root)
	if after != before {
		return fmt.Errorf("skip-if-dirty dirty appended message: %d -> %d", before, after)
	}
	if _, err := r.ocexec("rm", "-f", worktree+"/dirty-test-marker.txt"); err != nil {
		return err
	}
	if err := r.writeSchedule("aaaa", "continue"); err != nil {
		return err
	}
	if _, err := r.ocexec("sh", "-c", "echo 'untracked dirty marker' > "+worktree+"/dirty-test-marker.txt"); err != nil {
		return err
	}
	time.Sleep(4 * time.Second)
	before, _ = r.messageCount(ws, root)
	out, err = r.cli("env", "KFACTORY_SCHEDULED_DIR=/tmp/kfactory-scheduled", "kfactory", "tick", "aaaa")
	if err != nil {
		return err
	}
	if err := expectWorkspaceOutput("continue", out, ws); err != nil {
		return err
	}
	time.Sleep(3 * time.Second)
	after, _ = r.messageCount(ws, root)
	if after <= before {
		return fmt.Errorf("continue did not append: %d -> %d", before, after)
	}
	_, _ = r.ocexec("rm", "-f", worktree+"/dirty-test-marker.txt")
	fmt.Println("      ✓ scheduled tick modes behave correctly")
	return nil
}

func (r *runner) phaseTickConcurrentFirstRun() error {
	task := "c0de"
	r.cleanupTaskSuffix(task)
	if _, err := r.cli("mkdir", "-p", "/tmp/kfactory-race-scheduled"); err != nil {
		return err
	}
	config := `{"repo":"file:///srv/test-repo.git","mode":"continue","initial_prompt":"say race and immediately stop","continuation_prompt":"continue race"}`
	if _, err := r.cliShell("cat > /tmp/kfactory-race-scheduled/" + task + ".json <<'JSON'\n" + config + "\nJSON"); err != nil {
		return err
	}
	_, err := r.cliShell("rm -f /tmp/tick-race-*.out /tmp/tick-race-*.err /tmp/tick-race-*.code; for i in $(seq 1 8); do (env KFACTORY_SCHEDULED_DIR=/tmp/kfactory-race-scheduled kfactory tick c0de > /tmp/tick-race-$i.out 2>/tmp/tick-race-$i.err; echo $? > /tmp/tick-race-$i.code) & done; wait || true")
	if err != nil {
		return err
	}
	codes, _ := r.cliShell("for i in $(seq 1 8); do printf '%s:' $i; cat /tmp/tick-race-$i.code 2>/dev/null || echo missing; done")
	if regexp.MustCompile(`(?m):[^0]\s*$|missing`).MatchString(codes) {
		return fmt.Errorf("nonzero race exit codes:\n%s", codes)
	}
	rows := r.workspacesWithSuffix(task)
	if len(rows) != 1 {
		return fmt.Errorf("expected one --%s workspace, got %d", task, len(rows))
	}
	root, err := r.rootSession(rows[0].ID)
	if err != nil {
		return err
	}
	msgs, err := r.messages(rows[0].ID, root)
	if err != nil {
		return err
	}
	prompts := 0
	for _, msg := range msgs {
		if msg.Info.Role == "user" && strings.Contains(joinText(msg), "race") {
			prompts++
		}
	}
	if prompts != 1 {
		return fmt.Errorf("expected one race prompt, got %d", prompts)
	}
	fmt.Println("      ✓ concurrent first-run converged")
	return nil
}

func (r *runner) writeSchedule(task, mode string) error {
	modeField := ""
	if mode != "" {
		modeField = `,"mode":"` + mode + `"`
	}
	config := `{"repo":"file:///srv/test-repo.git"` + modeField + `,"initial_prompt":"say hi and immediately stop","continuation_prompt":"say bye and immediately stop"}`
	_, err := r.cliShell("cat > /tmp/kfactory-scheduled/" + task + ".json <<'JSON'\n" + config + "\nJSON")
	return err
}
