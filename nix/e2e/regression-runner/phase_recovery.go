package main

import (
	"fmt"
	"regexp"
	"strings"
	"time"
)

func (r *runner) phaseRecovery() error {
	ws := r.ws1
	sess, err := r.sql("SELECT id FROM session WHERE workspace_id='" + ws + "' LIMIT 1;")
	if err != nil {
		return err
	}
	sess = strings.TrimSpace(sess)
	if sess == "" {
		return fmt.Errorf("could not locate a session for %s", ws)
	}
	// The regression environment has no LLM provider, so sessions never
	// contain real assistant turns; synthesize the mid-stream assistant
	// row in the same spirit as the opencode-heal replay fixtures
	// (nix/replay/opencode-heal: v1-stuck-assistant.sql), but with the
	// FULL v1 AssistantMessage shape (packages/core/src/v1/session.ts)
	// so the live /session/<id>/message decode keeps working.
	const msg = "msg_regression_stuck0001"
	stuckData := `{"id":"` + msg + `","sessionID":"` + sess + `","role":"assistant",` +
		`"time":{"created":1},"parentID":"msg_regression_parent01",` +
		`"modelID":"regression","providerID":"regression","mode":"build","agent":"build",` +
		`"path":{"cwd":"/","root":"/"},"cost":0,` +
		`"tokens":{"input":0,"output":0,"reasoning":0,"cache":{"read":0,"write":0}}}`
	if _, err := r.sql("INSERT OR REPLACE INTO message (id, session_id, time_created, time_updated, data) VALUES ('" + msg + "', '" + sess + "', strftime('%s','now')*1000, strftime('%s','now')*1000, json('" + stuckData + "'));"); err != nil {
		return err
	}
	stuck, err := r.sql("SELECT count(*) FROM message WHERE id='" + msg + "' AND json_extract(data, '$.time.completed') IS NULL;")
	if err != nil || strings.TrimSpace(stuck) != "1" {
		return fmt.Errorf("failed to manufacture stuck state count=%q err=%v", stuck, err)
	}
	queue := "/tmp/recovery-queue.json"
	log, err := r.ocexec("env", "KFACTORY_RECOVERY_QUEUE="+queue, "opencode-heal", r.db)
	if err != nil {
		return fmt.Errorf("heal failed: %w log=%s", err, log)
	}
	queueJSON, err := r.ocexec("cat", queue)
	if err != nil {
		return err
	}
	if !jsonArrayContains(queueJSON, ws) {
		return fmt.Errorf("heal queue missing %s: %s", ws, queueJSON)
	}
	finish, _ := r.sql("SELECT json_extract(data, '$.finish') FROM message WHERE id='" + msg + "';")
	errorName, _ := r.sql("SELECT json_extract(data, '$.error.name') FROM message WHERE id='" + msg + "';")
	if strings.TrimSpace(finish) != "interrupted-by-restart" || strings.TrimSpace(errorName) != "MessageAbortedError" {
		return fmt.Errorf("heal row not marked correctly: finish=%q error=%q", finish, errorName)
	}
	syncLog, err := r.ocexec("opencode-sync-kick", "--base", "http://localhost:4096", "--health-timeout", "10")
	if err != nil || !regexp.MustCompile(`kicked [1-9][0-9]* workspace`).MatchString(syncLog) {
		return fmt.Errorf("sync-kick failed/log unexpected: %v %s", err, syncLog)
	}
	prompt := "opencode-serve restarted; resume your last action"
	before, _ := r.messageCount(ws, sess)
	for _, wid := range jsonArray(queueJSON) {
		if _, err := r.cli("kfactory", "tick", wid, "--prompt", prompt); err != nil {
			return err
		}
	}
	time.Sleep(2 * time.Second)
	after, _ := r.messageCount(ws, sess)
	last, _ := r.lastUserText(ws, sess)
	if after <= before || last != prompt {
		return fmt.Errorf("recovery prompt not injected: %d -> %d last=%q", before, after, last)
	}
	fmt.Println("      ✓ heal + recovery round trip succeeded")
	return nil
}
