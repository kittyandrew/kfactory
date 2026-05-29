package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestResolveDispatchPromptKeepsMultiWordInlineText(t *testing.T) {
	got, err := resolveDispatchPrompt([]string{"fix", "the", "thing"})
	if err != nil {
		t.Fatal(err)
	}
	if got != "fix the thing" {
		t.Fatalf("resolveDispatchPrompt() = %q, want inline prompt", got)
	}
}

func TestResolveDispatchPromptKeepsBareSingleWordInlineText(t *testing.T) {
	got, err := resolveDispatchPrompt([]string{"prompt.txt"})
	if err != nil {
		t.Fatal(err)
	}
	if got != "prompt.txt" {
		t.Fatalf("resolveDispatchPrompt() = %q, want bare single word inline", got)
	}
}

func TestResolveDispatchPromptKeepsSpacedPathInlineText(t *testing.T) {
	got, err := resolveDispatchPrompt([]string{"./my prompt.txt"})
	if err != nil {
		t.Fatal(err)
	}
	if got != "./my prompt.txt" {
		t.Fatalf("resolveDispatchPrompt() = %q, want spaced path-looking arg inline", got)
	}
}

func TestResolveDispatchPromptReadsPathShapedFile(t *testing.T) {
	tmp := chdirTemp(t)
	if err := os.WriteFile(filepath.Join(tmp, "prompt.txt"), []byte("  hello\nworld\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	got, err := resolveDispatchPrompt([]string{"./prompt.txt"})
	if err != nil {
		t.Fatal(err)
	}
	if got != "hello\nworld" {
		t.Fatalf("resolveDispatchPrompt() = %q, want file contents after trim", got)
	}
}

func TestResolveDispatchPromptExpandsTildePath(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	if err := os.WriteFile(filepath.Join(home, "prompt.txt"), []byte("from home\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	got, err := resolveDispatchPrompt([]string{"~/prompt.txt"})
	if err != nil {
		t.Fatal(err)
	}
	if got != "from home" {
		t.Fatalf("resolveDispatchPrompt() = %q, want tilde-expanded file contents", got)
	}
}

func TestResolveDispatchPromptErrorsForMissingPathShapedFile(t *testing.T) {
	tmp := chdirTemp(t)
	wantPath := filepath.Join(tmp, "missing.txt")

	_, err := resolveDispatchPrompt([]string{"./missing.txt"})
	if err == nil {
		t.Fatal("resolveDispatchPrompt() error = nil, want missing file error")
	}
	msg := err.Error()
	if !strings.Contains(msg, "no such file: "+wantPath) || !strings.Contains(msg, "was that supposed to be a prompt?") {
		t.Fatalf("resolveDispatchPrompt() error = %q, want missing file hint for %s", msg, wantPath)
	}
}

func TestResolveDispatchPromptErrorsForDirectoryPath(t *testing.T) {
	tmp := chdirTemp(t)
	wantPath := filepath.Join(tmp, "prompts")
	if err := os.Mkdir(wantPath, 0o700); err != nil {
		t.Fatal(err)
	}

	_, err := resolveDispatchPrompt([]string{"./prompts"})
	if err == nil {
		t.Fatal("resolveDispatchPrompt() error = nil, want directory error")
	}
	if !strings.Contains(err.Error(), "prompt path is a directory: "+wantPath) {
		t.Fatalf("resolveDispatchPrompt() error = %q, want directory path %s", err.Error(), wantPath)
	}
}

func TestResolveDispatchPromptRejectsEmptyFile(t *testing.T) {
	tmp := chdirTemp(t)
	wantPath := filepath.Join(tmp, "empty.txt")
	if err := os.WriteFile(wantPath, []byte("\n\t "), 0o600); err != nil {
		t.Fatal(err)
	}

	_, err := resolveDispatchPrompt([]string{"./empty.txt"})
	if err == nil {
		t.Fatal("resolveDispatchPrompt() error = nil, want empty prompt error")
	}
	if !strings.Contains(err.Error(), "prompt is required (file "+wantPath+" is empty after trim)") {
		t.Fatalf("resolveDispatchPrompt() error = %q, want empty file path %s", err.Error(), wantPath)
	}
}

func chdirTemp(t *testing.T) string {
	t.Helper()
	tmp := t.TempDir()
	old, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Chdir(tmp); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := os.Chdir(old); err != nil {
			t.Fatalf("restore cwd: %v", err)
		}
	})
	return tmp
}
