package kitmaint

import (
	"os"
	"path/filepath"
	"testing"
)

// scratch is a short, symlink-free temp dir (macOS and GOTMPDIR runs resolve t.TempDir through links).
func scratch(t *testing.T) string {
	t.Helper()
	d, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	return d
}

// script writes an executable shell script; tests that use it never run in parallel (ETXTBSY, golang/go#22315).
func script(t *testing.T, dir, name, body string) string {
	t.Helper()
	p := filepath.Join(dir, name)
	if err := os.WriteFile(p, []byte("#!/bin/sh\n"+body+"\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	return p
}
