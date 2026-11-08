package main

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// TestE2E runs test/e2e.vim in a real Vim with goda.vim and the binary built
// from here: the drawing, the version check and the build of goda.vim.
// Skipped with -short or without vim.
func TestE2E(t *testing.T) {
	if testing.Short() {
		t.Skip("-short")
	}
	vim, err := exec.LookPath("vim")
	if err != nil {
		t.Skip("no vim")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()

	dir := t.TempDir()
	bin := filepath.Join(dir, "mdview")
	if out, err := exec.CommandContext(ctx, "go", "build", "-o", bin, ".").CombinedOutput(); err != nil {
		t.Fatalf("go build: %v\n%s", err, out)
	}
	// goda.vim's Vim script, from the module cache: the version of go.mod.
	out, err := exec.CommandContext(ctx, "go", "list", "-m", "-f", "{{.Dir}}", "github.com/Shougo/goda.vim").Output()
	if err != nil {
		t.Fatalf("go list goda.vim: %v", err)
	}
	goda := strings.TrimSpace(string(out))

	result := filepath.Join(dir, "result")
	cmd := exec.CommandContext(ctx, vim, "-N", "-u", "NONE", "-i", "NONE", "-n", "--not-a-term",
		"-S", filepath.Join("..", "test", "e2e.vim"))
	cmd.Env = append(os.Environ(),
		"MDVIEW_E2E_BIN="+bin,
		"MDVIEW_E2E_GODA="+goda,
		"MDVIEW_E2E_CACHE="+dir,
		"MDVIEW_E2E_RESULT="+result)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("vim: %v\n%s", err, out)
	}
	b, err := os.ReadFile(result)
	if err != nil {
		t.Fatalf("no result: %v", err)
	}
	if got := strings.TrimSpace(string(b)); got != "ok" {
		t.Errorf("test/e2e.vim:\n%s", got)
	}
}
