//go:build unix && !nodiff

package block

import (
	"os"
	"path/filepath"
	"testing"
)

// TestDifferentialBlockUnreadable: on an unreadable block the Go report and exit code equal the frozen script's. Only
// stderr differs on purpose: the script let each awk/grep/cat print its own "Permission denied" (about twenty lines);
// the port prints one line naming the read failure (tool-registry.d/verify-block.md).
func TestDifferentialBlockUnreadable(t *testing.T) {
	t.Parallel()
	dir, block := bkUnreadableBlock(t)
	args := []string{filepath.Base(block), dir}
	env := []string{"PATH=" + os.Getenv("PATH"), "HOME=" + dir, "LC_ALL=C.UTF-8"}
	want := bkLegacy(t, dir, args, env)
	got := bkGo(dir, args, env)
	if want.RC != got.RC || want.Stdout != got.Stdout {
		t.Errorf("legacy and Go differ on an unreadable block:\n--- legacy rc=%d\n%s\n--- go rc=%d\n%s", want.RC, want.Stdout, got.RC, got.Stdout)
	}
	if want.Stderr == "" || got.Stderr == "" {
		t.Errorf("both sides must report the read failure on stderr: legacy %q, go %q", want.Stderr, got.Stderr)
	}
}
