package kit

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func envOf(m map[string]string) Getenv { return func(k string) string { return m[k] } }

func write(t *testing.T, path, content string) string {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	return path
}

// mkfiles creates empty files (and their directories) under root.
func mkfiles(t *testing.T, root string, rels ...string) {
	t.Helper()
	for _, r := range rels {
		write(t, filepath.Join(root, r), "")
	}
}

// physical returns the symlink-free absolute form of dir (t.TempDir may sit behind a symlink on some hosts).
func physical(t *testing.T, dir string) string {
	t.Helper()
	p, err := filepath.EvalSymlinks(dir)
	if err != nil {
		t.Fatal(err)
	}
	return p
}

// tableRows builds a TARGETS.md-shaped source: a header, the rows, one per line.
func tableRows(rows ...string) string {
	return "# Targets\n\n| # | name | path |\n|---|------|------|\n" + strings.Join(rows, "\n") + "\n"
}
