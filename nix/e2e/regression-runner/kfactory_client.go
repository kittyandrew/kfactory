package main

import (
	"fmt"
	"strconv"
	"strings"
)

type listRow struct{ Index, ID, Name, Branch string }

func (r *runner) kfactoryDispatch(prompt string) (string, error) {
	out, err := r.cli("kfactory", "dispatch", r.repo, prompt)
	if err != nil {
		return "", err
	}
	id, err := workspaceIDFromOutput(out)
	if err != nil {
		return "", err
	}
	return id, nil
}

func workspaceIDFromOutput(out string) (string, error) {
	for _, line := range strings.Split(out, "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "wrk_") && !strings.ContainsAny(line, " \t") {
			return line, nil
		}
	}
	return "", fmt.Errorf("dispatch output did not contain standalone workspace id: %s", tail(out, 500))
}

func expectWorkspaceOutput(label, out, want string) error {
	got, err := workspaceIDFromOutput(out)
	if err != nil {
		return fmt.Errorf("%s: %w", label, err)
	}
	if got != want {
		return fmt.Errorf("%s workspace=%s, want %s; output=%s", label, got, want, tail(out, 500))
	}
	return nil
}

func (r *runner) listRows() ([]listRow, error) {
	out, err := r.cli("kfactory", "list")
	if err != nil {
		return nil, err
	}
	var rows []listRow
	for _, line := range strings.Split(out, "\n") {
		fields := strings.Fields(line)
		if len(fields) >= 3 && strings.HasPrefix(fields[1], "wrk_") {
			row := listRow{Index: fields[0], ID: fields[1], Name: fields[2]}
			if len(fields) >= 4 {
				row.Branch = fields[3]
			}
			rows = append(rows, row)
		}
	}
	return rows, nil
}

func rowByID(rows []listRow, id string) *listRow {
	for i := range rows {
		if rows[i].ID == id {
			return &rows[i]
		}
	}
	return nil
}

func indexByID(rows []listRow, id string) *int {
	for _, row := range rows {
		if row.ID != id {
			continue
		}
		idx, err := strconv.Atoi(row.Index)
		if err != nil {
			return nil
		}
		return &idx
	}
	return nil
}

func valueOrEmpty(row *listRow, fn func(listRow) string) string {
	if row == nil {
		return ""
	}
	return fn(*row)
}
