package main

import (
	"errors"
	"fmt"
	"regexp"
	"strings"
	"time"
)

func (r *runner) phaseNtfyIdle() error {
	msgs, raw, err := r.ntfyPoll(time.Now().Add(-1 * time.Hour).Unix())
	if err != nil {
		return err
	}
	if len(msgs) == 0 {
		return fmt.Errorf("no ntfy messages on topic; raw=%s", tail(raw, 500))
	}
	body := msgs[0].Message
	if body == "" || regexp.MustCompile(`\{(project|branch|session_id|event|time)\}`).MatchString(body) {
		return fmt.Errorf("ntfy body not substituted: %q", body)
	}
	fmt.Printf("      ✓ ntfy fired %d message(s); first body=%q\n", len(msgs), body)
	return nil
}

func (r *runner) phaseNtfyPermissionAsked() error {
	ws, err := r.kfactoryDispatch("wait for instructions")
	if err != nil {
		return err
	}
	time.Sleep(2 * time.Second)
	since := time.Now().Unix()
	if _, err := r.cli("kfactory", "tick", ws, "--prompt", "Use the webfetch tool to fetch https://example.com. Do nothing else."); err != nil {
		return err
	}
	time.Sleep(12 * time.Second)
	msgs, raw, err := r.ntfyPoll(since)
	if err != nil {
		return err
	}
	for _, msg := range msgs {
		if msg.Time >= since && msg.Title == "Permission Asked" {
			if regexp.MustCompile(`\{(project|branch|session_id|event|time|permission_type|permission_patterns)\}`).MatchString(msg.Message) {
				return fmt.Errorf("permission body contains placeholders: %q", msg.Message)
			}
			if !strings.Contains(msg.Message, "webfetch") {
				return fmt.Errorf("permission body does not mention webfetch: %q", msg.Message)
			}
			fmt.Println("      ✓ permission.asked notification fired", msg.Message)
			return nil
		}
	}
	return fmt.Errorf("no permission notification after %d; raw=%s", since, tail(raw, 1000))
}

func (r *runner) phaseNtfyPtyFalseIdle() error {
	sinceDispatch := time.Now().Unix()
	ws, err := r.kfactoryDispatch("wait for instructions")
	if err != nil {
		return err
	}
	slug, err := r.slugForWorkspace(ws)
	if err != nil {
		return err
	}
	_ = retry(15*time.Second, 500*time.Millisecond, func() error {
		msgs, _, err := r.ntfyPoll(sinceDispatch)
		if err != nil {
			return err
		}
		for _, msg := range msgs {
			if msg.Time >= sinceDispatch && msg.Title == "Agent Idle" && strings.Contains(msg.Message, slug) {
				return nil
			}
		}
		return errors.New("dispatch idle not yet landed")
	})
	time.Sleep(1 * time.Second)
	sinceTick := time.Now().Unix()
	if _, err := r.cli("kfactory", "tick", ws, "--prompt", "Use the pty_spawn tool to start the bash command 'sleep 8 && echo PTY_DONE'. Set notifyOnExit to true. Then stop immediately -- do not call any other tools, do not say anything else."); err != nil {
		return err
	}
	time.Sleep(7 * time.Second)
	ptyID, err := r.latestNotifyOnExitPtyID(ws)
	if err != nil {
		return err
	}
	deadline := sinceTick + 10
	msgs, raw, err := r.ntfyPoll(sinceTick)
	if err != nil {
		return err
	}
	falseCount := 0
	for _, msg := range msgs {
		if msg.Time < deadline && msg.Title == "Agent Idle" && strings.Contains(msg.Message, slug) {
			falseCount++
		}
	}
	if falseCount != 0 {
		return fmt.Errorf("%d false idle messages while PTY running; raw=%s", falseCount, tail(raw, 1000))
	}
	fmt.Println("      ✓ no false idle while PTY pending; pty id", ptyID)
	return nil
}
