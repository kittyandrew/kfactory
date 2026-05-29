package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"
)

func (r *runner) phaseLoopPlugin() error {
	ws, err := r.kfactoryDispatch("I am setting up for a loop smoke test; just say hi and wait")
	if err != nil {
		return err
	}
	slug, err := r.slugForWorkspace(ws)
	if err != nil {
		return err
	}
	dir := "/var/lib/kfactory/workspaces/" + slug
	sf := r.loopStateFile(dir)
	time.Sleep(10 * time.Second)
	_, _ = r.ocexec("rm", "-f", sf)
	sid, err := r.createEmptySession(ws)
	if err != nil {
		return err
	}
	if err := r.sendPrompt(ws, sid, "Output the single character 1 on its own line. Then stop. Do not call any tools, do not emit anything else."); err != nil {
		return err
	}
	if err := retry(30*time.Second, time.Second, func() error {
		msgs, err := r.messages(ws, sid)
		if err != nil {
			return err
		}
		for _, msg := range msgs {
			if msg.Info.Role == "assistant" && joinText(msg) != "" {
				return nil
			}
		}
		return errors.New("no assistant text yet")
	}); err != nil {
		return err
	}
	initial, _ := r.messageCount(ws, sid)
	state, err := json.Marshal(struct {
		SchemaVersion       int    `json:"schemaVersion"`
		RunID               string `json:"runID"`
		Iteration           int    `json:"iteration"`
		MaxIterations       int    `json:"maxIterations"`
		Sentinel            string `json:"sentinel"`
		SessionID           string `json:"sessionID"`
		Task                string `json:"task"`
		ConsecutiveFailures int    `json:"consecutiveFailures"`
	}{
		SchemaVersion:       2,
		RunID:               "regression-runner",
		Iteration:           0,
		MaxIterations:       8,
		Sentinel:            "LOOPDONE",
		SessionID:           sid,
		Task:                "You are counting up by one. Your last assistant turn emitted some integer N. Your next response should emit ONLY the integer N+1 on its own line. When you reach 3, emit 3 on one line, then LOOPDONE on the final line.",
		ConsecutiveFailures: 0,
	})
	if err != nil {
		return err
	}
	if _, err := r.ocexec("mkdir", "-p", "/root/.local/state/kfactory-loop"); err != nil {
		return err
	}
	if _, err := r.ocexecStdin([]string{"sh", "-c", "cat > " + sf}, string(state)); err != nil {
		return err
	}
	_, _ = r.cli("curl", "-sf", "-X", "POST", "-H", "Authorization: Bearer "+r.token, "-H", "x-opencode-workspace: "+ws, r.opencodeBase+"/session/"+sid+"/abort")
	if err := retry(120*time.Second, time.Second, func() error {
		_, err := r.ocexec("sh", "-c", "test ! -e "+sf)
		return err
	}); err != nil {
		return err
	}
	final, _ := r.messageCount(ws, sid)
	msgs, _ := r.messages(ws, sid)
	cont := 0
	lastAssistant := ""
	for _, msg := range msgs {
		text := joinText(msg)
		if msg.Info.Role == "user" && strings.HasPrefix(text, "[loop iteration ") {
			cont++
		}
		if msg.Info.Role == "assistant" && text != "" {
			lastAssistant = text
		}
	}
	if final <= initial || cont < 1 || !strings.HasSuffix(strings.TrimSpace(lastAssistant), "LOOPDONE") {
		return fmt.Errorf("loop did not complete: messages %d->%d continuations=%d last=%q", initial, final, cont, lastAssistant)
	}
	_, _ = r.ocexec("rm", "-f", sf)
	fmt.Println("      ✓ loop plugin terminated on sentinel")
	return nil
}

func (r *runner) loopStateFile(directory string) string {
	sum := sha256.Sum256([]byte(directory))
	return "/root/.local/state/kfactory-loop/" + hex.EncodeToString(sum[:])[:16] + ".json"
}
