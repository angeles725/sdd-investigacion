//go:build unix

package parity

import (
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
)

func TestCopyTreeAppliesTheRootDirMode(t *testing.T) {
	src := filepath.Join(t.TempDir(), "in")
	if err := os.MkdirAll(filepath.Join(src, "sub"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(src, 0o555); err != nil {
		t.Fatal(err)
	}
	dst := filepath.Join(t.TempDir(), "out")
	t.Cleanup(func() { _ = os.Chmod(src, 0o755); _ = os.Chmod(dst, 0o755) })
	if err := copyTree(src, dst, false); err != nil {
		t.Fatal(err)
	}
	st, err := os.Stat(dst)
	if err != nil || st.Mode().Perm() != 0o555 {
		t.Fatalf("the root directory's mode must be copied too: %v %v", st, err)
	}
}

func TestCopyTreeKeepsTheWalkErrorAfterApplyingDirModes(t *testing.T) {
	src := filepath.Join(t.TempDir(), "in")
	if err := os.MkdirAll(src, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := syscall.Mkfifo(filepath.Join(src, "fifo"), 0o644); err != nil {
		t.Skipf("mkfifo: %v", err)
	}
	err := copyTree(src, filepath.Join(t.TempDir(), "out"), false)
	if err == nil || !strings.Contains(err.Error(), "unsupported file type") {
		t.Fatalf("a special file must fail the copy even though the dir modes apply cleanly: %v", err)
	}
}
