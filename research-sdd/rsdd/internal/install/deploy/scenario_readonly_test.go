//go:build unix && !nodiff

package deploy

import (
	"os"
	"testing"
)

// Failure mode "Read-only config root: exit 1, no record". The root is made unwritable before a fresh install
// and restored in a cleanup so the scratch directory can be removed.
func TestReadOnlyConfigRoot(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root bypasses directory permissions: the read-only root cannot be simulated")
	}
	w := newWorld(t)
	w.seed(".claude/CLAUDE.md", "# mine\n")
	root := w.hp(".claude")
	if err := os.Chmod(root, 0o555); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(root, 0o755) })
	w.check("install", w.install("--harness", "claude"), 1, fromGolden, fromGolden)
	if _, err := os.Lstat(w.hp(".claude/research-sdd/.installed-bundle-state")); !os.IsNotExist(err) {
		t.Errorf("a bundle record exists after a failed install: %v", err)
	}
}
