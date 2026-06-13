package main

import (
	"fmt"
	"regexp"
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
