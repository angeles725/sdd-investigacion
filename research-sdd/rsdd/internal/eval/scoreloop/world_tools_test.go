package scoreloop

import (
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

// toolsets are PATH directories that hold exactly the tools the legacy script needs, minus one: they make the
// "dependency absent" states reproducible whatever the host has installed.
var scriptTools = []string{"bash", "git", "date", "sort", "grep", "mktemp", "cat", "tail", "head", "rm", "tr", "cut",
	"wc", "paste", "dirname", "base64", "jq", "env", "sed"}

// mkTools builds <scratch>/tools-<kind> and returns its path. kind names the missing tool: "jq", "base64", or
// "date" (a date that cannot parse -d, like BSD date).
func mkTools(t testing.TB, scratch, kind string) string {
	t.Helper()
	dir := filepath.Join(scratch, "tools-"+kind)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, name := range scriptTools {
		if name == kind {
			continue
		}
		target, err := exec.LookPath(name)
		if err != nil {
			t.Fatalf("toolset needs %s on PATH: %v", name, err)
		}
		if err := os.Symlink(target, filepath.Join(dir, name)); err != nil {
			t.Fatal(err)
		}
	}
	if kind == "date" {
		if err := os.WriteFile(filepath.Join(dir, "date"), []byte("#!/usr/bin/env bash\nexit 1\n"), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	return dir
}
