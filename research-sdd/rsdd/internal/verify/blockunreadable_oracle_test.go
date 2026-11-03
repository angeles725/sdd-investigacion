//go:build unix && !nodiff

package verify

import (
	"os"
	"path/filepath"
	"testing"
)

// TestDifferentialBlockUnreadable: on an unreadable block the Go report and exit code equal the frozen script's. Only
// stderr differs on purpose: the script let each awk/grep/cat print its own "Permission denied" (about twenty lines);
// the port prints one line naming the read failure (tool-registry.d/verify-block.md).
func TestDifferentialBlockUnreadable(t *testing.T) {
	dir, block := bkUnreadableBlock(t)
	args := []string{filepath.Base(block), dir}
	env := []string{"PATH=" + os.Getenv("PATH"), "HOME=" + dir, "LC_ALL=C.UTF-8"}
	want := bkLegacy(t, dir, args, env)
	got := bkGo(dir, args, env)
	if want.rc != got.rc || want.stdout != got.stdout {
		t.Errorf("legacy and Go differ on an unreadable block:\n--- legacy rc=%d\n%s\n--- go rc=%d\n%s", want.rc, want.stdout, got.rc, got.stdout)
	}
	if want.stderr == "" || got.stderr == "" {
		t.Errorf("both sides must report the read failure on stderr: legacy %q, go %q", want.stderr, got.stderr)
	}
}
