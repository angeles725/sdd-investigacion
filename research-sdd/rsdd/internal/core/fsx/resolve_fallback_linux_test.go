//go:build linux

package fsx

import (
	"os"
	"path/filepath"
	"testing"
)

// The /proc-less fallback must never consult the process working directory:
// a relative path comes back as given (cleaned), not joined to the cwd, and an
// empty path stays empty (Publish passes "" and used to get the cwd back).
func TestResolveFallbackReadsNoCwd(t *testing.T) {
	dir := t.TempDir()
	real := filepath.Join(dir, "real")
	if err := os.Mkdir(real, 0o755); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(dir, "link")
	if err := os.Symlink(real, link); err != nil {
		t.Fatal(err)
	}
	want, err := filepath.EvalSymlinks(real)
	if err != nil {
		t.Fatal(err)
	}
	tests := []struct {
		name, in, want string
	}{
		{"absolute path resolves symlinks", link, want},
		{"absolute path that does not exist is cleaned", filepath.Join(dir, "gone", "..", "x"), filepath.Join(dir, "x")},
		{"relative path is not joined to the cwd", "a/./b", "a/b"},
		{"empty path stays empty", "", ""},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := resolveFallback(tt.in); got != tt.want {
				t.Errorf("resolveFallback(%q) = %q, want %q", tt.in, got, tt.want)
			}
		})
	}
}
