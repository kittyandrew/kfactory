package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestScheduledLockPathUsesStableUserCacheDir(t *testing.T) {
	cacheDir := t.TempDir()
	runtimeDir := t.TempDir()
	t.Setenv("XDG_CACHE_HOME", cacheDir)
	t.Setenv("XDG_RUNTIME_DIR", runtimeDir)
	t.Setenv("KFACTORY_SCHEDULED_DIR", "/etc/kfactory/scheduled")

	path, err := scheduledLockPath("7a3f")
	if err != nil {
		t.Fatal(err)
	}

	wantPrefix := filepath.Join(cacheDir, "kfactory", "locks") + string(os.PathSeparator)
	if !strings.HasPrefix(path, wantPrefix) {
		t.Fatalf("scheduledLockPath() = %q, want prefix %q", path, wantPrefix)
	}
	if strings.HasPrefix(path, runtimeDir) {
		t.Fatalf("scheduledLockPath() = %q, must not depend on XDG_RUNTIME_DIR %q", path, runtimeDir)
	}
	if filepath.Base(path) == "" || filepath.Base(path) == ".lock" {
		t.Fatalf("scheduledLockPath() produced invalid lock filename: %q", path)
	}
}

func TestScheduledLockPathIsKeyedByTaskIDNotConfigDir(t *testing.T) {
	cacheDir := t.TempDir()
	t.Setenv("XDG_CACHE_HOME", cacheDir)
	t.Setenv("KFACTORY_SCHEDULED_DIR", "/etc/kfactory/scheduled")

	first, err := scheduledLockPath("7a3f")
	if err != nil {
		t.Fatal(err)
	}

	t.Setenv("KFACTORY_SCHEDULED_DIR", filepath.Join(t.TempDir(), "scheduled"))
	second, err := scheduledLockPath("7a3f")
	if err != nil {
		t.Fatal(err)
	}

	if second != first {
		t.Fatalf("scheduledLockPath changed with config dir: first=%q second=%q", first, second)
	}
	if filepath.Base(first) != "tick-7a3f.lock" {
		t.Fatalf("scheduledLockPath() basename = %q, want tick-7a3f.lock", filepath.Base(first))
	}
}

func TestAcquireScheduledTaskRunCreatesPrivateCacheDir(t *testing.T) {
	cacheDir := t.TempDir()
	t.Setenv("XDG_CACHE_HOME", cacheDir)
	t.Setenv("KFACTORY_SCHEDULED_DIR", "/etc/kfactory/scheduled")

	run, err := acquireScheduledTaskRun("7a3f")
	if err != nil {
		t.Fatal(err)
	}
	run.Close()

	info, err := os.Stat(filepath.Join(cacheDir, "kfactory", "locks"))
	if err != nil {
		t.Fatal(err)
	}
	if got := info.Mode().Perm(); got != 0o700 {
		t.Fatalf("lock dir mode = %o, want 0700", got)
	}
}

func TestAcquireScheduledTaskRunReportsContention(t *testing.T) {
	lockDir := t.TempDir()
	t.Setenv("KFACTORY_LOCK_DIR", lockDir)

	first, err := acquireScheduledTaskRun("7a3f")
	if err != nil {
		t.Fatal(err)
	}
	second := acquireContendedScheduledTaskRun(t, "7a3f", first)
	defer second.Close()

	if !second.waited {
		t.Fatalf("second run waited = false, want true")
	}
}

func TestAcquireScheduledTaskRunKeepsLockFileAsMutexOnly(t *testing.T) {
	lockDir := t.TempDir()
	t.Setenv("KFACTORY_LOCK_DIR", lockDir)

	run, err := acquireScheduledTaskRun("7a3f")
	if err != nil {
		t.Fatal(err)
	}
	run.Close()

	path, err := scheduledLockPath("7a3f")
	if err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if len(data) != 0 {
		t.Fatalf("lock file contains state %q, want empty mutex-only file", string(data))
	}
}

func TestReadScheduledTaskProgressDerivesFirstRunFromAnyUserPrompt(t *testing.T) {
	server := scheduledProgressServer(t, `[{
		"info":{"role":"user"},
		"parts":[{"type":"text","text":"previous configured prompt"}]
	}]`)
	defer server.Close()

	progress, err := readScheduledTaskProgress(context.Background(), nil, server.URL, "7a3f")
	if err != nil {
		t.Fatal(err)
	}
	if progress.workspaceID != scheduledWorkspaceID("7a3f") {
		t.Fatalf("workspaceID = %q, want %q", progress.workspaceID, scheduledWorkspaceID("7a3f"))
	}
	if progress.rootSessionID != "ses_root" {
		t.Fatalf("rootSessionID = %q, want ses_root", progress.rootSessionID)
	}
	if !progress.firstRunComplete {
		t.Fatal("firstRunComplete = false, want true when root session contains a user prompt")
	}
}

func TestReadScheduledTaskProgressTreatsNoUserPromptAsIncomplete(t *testing.T) {
	server := scheduledProgressServer(t, `[{
		"info":{"role":"assistant"},
		"parts":[{"type":"text","text":"different"}]
	}]`)
	defer server.Close()

	progress, err := readScheduledTaskProgress(context.Background(), nil, server.URL, "7a3f")
	if err != nil {
		t.Fatal(err)
	}
	if progress.firstRunComplete {
		t.Fatal("firstRunComplete = true, want false without a user prompt")
	}
	if progress.workspaceID != scheduledWorkspaceID("7a3f") || progress.rootSessionID != "ses_root" {
		t.Fatalf("progress lost canonical ids: %#v", progress)
	}
}

func scheduledProgressServer(t *testing.T, messages string) *httptest.Server {
	t.Helper()

	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.Method == http.MethodGet && r.URL.Path == "/experimental/workspace":
			_, _ = w.Write([]byte(`[{"id":"` + scheduledWorkspaceID("7a3f") + `","name":"owner--repo--7a3f"}]`))
		case r.Method == http.MethodGet && r.URL.Path == "/experimental/session":
			if got := r.URL.Query().Get("workspace"); got != scheduledWorkspaceID("7a3f") {
				t.Fatalf("session workspace query = %q, want %q", got, scheduledWorkspaceID("7a3f"))
			}
			_, _ = w.Write([]byte(`[{"id":"ses_root","workspaceID":"` + scheduledWorkspaceID("7a3f") + `","time":{"updated":1}}]`))
		case r.Method == http.MethodGet && r.URL.Path == "/session/ses_root/message":
			if got := r.URL.Query().Get("workspace"); got != scheduledWorkspaceID("7a3f") {
				t.Fatalf("message workspace query = %q, want %q", got, scheduledWorkspaceID("7a3f"))
			}
			_, _ = w.Write([]byte(messages))
		default:
			t.Fatalf("unexpected request %s %s", r.Method, r.URL.String())
		}
	}))
}

func acquireContendedScheduledTaskRun(t *testing.T, taskID string, first *scheduledTaskRun) *scheduledTaskRun {
	t.Helper()

	type result struct {
		run *scheduledTaskRun
		err error
	}
	got := make(chan result, 1)
	go func() {
		run, err := acquireScheduledTaskRun(taskID)
		got <- result{run: run, err: err}
	}()

	select {
	case res := <-got:
		if res.run != nil {
			res.run.Close()
		}
		t.Fatalf("second run acquired before first released: waited=%v err=%v", res.run != nil && res.run.waited, res.err)
	case <-time.After(50 * time.Millisecond):
	}

	first.Close()

	select {
	case res := <-got:
		if res.err != nil {
			t.Fatal(res.err)
		}
		return res.run
	case <-time.After(time.Second):
		t.Fatal("timed out waiting for contended run")
	}
	return nil
}

func TestScheduledLockPathAllowsExplicitLockDir(t *testing.T) {
	lockDir := t.TempDir()
	t.Setenv("KFACTORY_LOCK_DIR", lockDir)
	t.Setenv("XDG_CACHE_HOME", t.TempDir())
	t.Setenv("XDG_RUNTIME_DIR", t.TempDir())

	path, err := scheduledLockPath("7a3f")
	if err != nil {
		t.Fatal(err)
	}

	want := filepath.Join(lockDir, "tick-7a3f.lock")
	if path != want {
		t.Fatalf("scheduledLockPath() = %q, want %q", path, want)
	}
}

func TestFindUniqueWorkspaceBySuffix(t *testing.T) {
	ws := []Workspace{
		{ID: "wrk_bbbb", Name: "other--repo--bbbb"},
		{ID: "wrk_7a3f", Name: "target--repo--7a3f"},
	}
	sortWorkspaces(ws)

	got, err := findUniqueWorkspaceBySuffix(ws, "7a3f")
	if err != nil {
		t.Fatal(err)
	}
	if got.ID != "wrk_7a3f" {
		t.Fatalf("findUniqueWorkspaceBySuffix() = %s, want wrk_7a3f", got.ID)
	}
}

func TestFindUniqueWorkspaceBySuffixDoesNotTreatNumericRefAsIndex(t *testing.T) {
	ws := []Workspace{
		{ID: "wrk_aaaa", Name: "first--repo--aaaa"},
		{ID: "wrk_bbbb", Name: "second--repo--bbbb"},
	}
	sortWorkspaces(ws)

	_, err := findUniqueWorkspaceBySuffix(ws, "0001")
	if err == nil || !strings.Contains(err.Error(), "no workspace has slug suffix") {
		t.Fatalf("expected suffix miss, got %v", err)
	}
}

func TestFindUniqueWorkspaceBySuffixRejectsDuplicateSuffix(t *testing.T) {
	ws := []Workspace{
		{ID: "wrk_aaaa", Name: "first--repo--7a3f"},
		{ID: "wrk_bbbb", Name: "second--repo--7a3f"},
	}
	sortWorkspaces(ws)

	_, err := findUniqueWorkspaceBySuffix(ws, "7a3f")
	if err == nil || !strings.Contains(err.Error(), "2 workspaces have slug suffix") {
		t.Fatalf("expected duplicate suffix error, got %v", err)
	}
}

func TestLoadScheduledConfigRejectsTrailingJSON(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("KFACTORY_SCHEDULED_DIR", dir)
	path := filepath.Join(dir, "7a3f.json")
	content := `{"repo":"file:///repo","initial_prompt":"start"} {"repo":"file:///other","initial_prompt":"oops"}`
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}

	_, err := loadScheduledConfig("7a3f")
	if err == nil || !strings.Contains(err.Error(), "multiple json values") {
		t.Fatalf("loadScheduledConfig error=%v, want multiple json values", err)
	}
}

func TestLoadScheduledConfigRejectsWhitespaceOnlyFields(t *testing.T) {
	cases := []struct {
		name string
		json string
		want string
	}{
		{"repo", `{"repo":"   ","initial_prompt":"start"}`, "repo"},
		{"initial prompt", `{"repo":"file:///repo","initial_prompt":"  \t"}`, "initial_prompt"},
		{"mode", `{"repo":"file:///repo","initial_prompt":"start","mode":" skip-if-dirty "}`, "invalid mode"},
		{"continuation prompt", `{"repo":"file:///repo","initial_prompt":"start","continuation_prompt":"  "}`, "continuation_prompt"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			dir := t.TempDir()
			t.Setenv("KFACTORY_SCHEDULED_DIR", dir)
			if err := os.WriteFile(filepath.Join(dir, "7a3f.json"), []byte(tc.json), 0o600); err != nil {
				t.Fatal(err)
			}

			_, err := loadScheduledConfig("7a3f")
			if err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("loadScheduledConfig error=%v, want %q", err, tc.want)
			}
		})
	}
}

func TestFindAdhocWorkspaceAcceptsExactWorkspaceID(t *testing.T) {
	ws := []Workspace{
		{ID: "wrk_aaaa", Name: "first--repo--0001"},
		{ID: "wrk_bbbb", Name: "second--repo--0002"},
	}
	sortWorkspaces(ws)

	got, err := findAdhocWorkspace(ws, "wrk_bbbb")
	if err != nil {
		t.Fatal(err)
	}
	if got.Name != "second--repo--0002" {
		t.Fatalf("findAdhocWorkspace() = %s, want second--repo--0002", got.Name)
	}
}

func TestFindAdhocWorkspaceRejectsListIndex(t *testing.T) {
	ws := []Workspace{
		{ID: "wrk_aaaa", Name: "first--repo--0001"},
		{ID: "wrk_bbbb", Name: "second--repo--0002"},
	}
	sortWorkspaces(ws)

	_, err := findAdhocWorkspace(ws, "1")
	if err == nil || !strings.Contains(err.Error(), "not a list index") {
		t.Fatalf("expected index rejection, got %v", err)
	}
}
