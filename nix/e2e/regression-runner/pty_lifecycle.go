package main

import (
	"fmt"
	"regexp"
	"strings"
)

var ptyIDPattern = regexp.MustCompile(`^pty_[a-f0-9]{8}$`)

func (r *runner) latestNotifyOnExitPtyID(workspaceID string) (string, error) {
	ptyID, err := r.sql(`SELECT substr(json_extract(p.data, '$.state.output'), instr(json_extract(p.data, '$.state.output'), 'ID: pty_') + 4, 12) FROM part p JOIN message m ON p.message_id = m.id JOIN session s ON m.session_id = s.id WHERE s.workspace_id = '` + workspaceID + `' AND json_extract(p.data, '$.tool') = 'pty_spawn' AND json_extract(p.data, '$.state.input.notifyOnExit') = 1 ORDER BY p.time_created DESC LIMIT 1;`)
	if err != nil {
		return "", err
	}
	ptyID = strings.TrimSpace(ptyID)
	if !ptyIDPattern.MatchString(ptyID) {
		return "", fmt.Errorf("opencode-pty id format drift: %q", ptyID)
	}
	return ptyID, nil
}

func (r *runner) notifyOnExitPtySpawnCount(workspaceID string) (int, error) {
	out, err := r.sql("SELECT count(*) FROM part p JOIN message m ON p.message_id = m.id JOIN session s ON m.session_id = s.id WHERE s.workspace_id = '" + workspaceID + "' AND json_extract(p.data, '$.type') = 'tool' AND json_extract(p.data, '$.tool') = 'pty_spawn' AND json_extract(p.data, '$.state.input.notifyOnExit') = 1;")
	if err != nil {
		return 0, err
	}
	return atoi(out), nil
}
