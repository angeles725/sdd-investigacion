//go:build linux

package fsx

import (
	"os"
	"path/filepath"
	"syscall"
	"testing"
)

func perm(t *testing.T, p string) os.FileMode {
	t.Helper()
	fi, err := os.Stat(p)
	if err != nil {
		t.Fatal(err)
	}
	return fi.Mode().Perm()
}

func TestWriteAtomicModeAppliesTheModeWhateverTheUmask(t *testing.T) {
	old := syscall.Umask(0o077)
	defer syscall.Umask(old)
	dir := t.TempDir()
	p := filepath.Join(dir, "out")
	if err := WriteAtomicMode(p, []byte("one"), 0o644); err != nil || read(t, p) != "one" || perm(t, p) != 0o644 {
		t.Fatalf("err %v content %q mode %v", err, read(t, p), perm(t, p))
	}
	// a stale temp with another mode does not leak its mode into the result
	if err := os.WriteFile(filepath.Join(dir, ".out.tmp"), []byte("stale"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := WriteAtomicMode(p, []byte("two"), 0o640); err != nil || read(t, p) != "two" || perm(t, p) != 0o640 {
		t.Fatalf("err %v content %q mode %v", err, read(t, p), perm(t, p))
	}
	if exists(filepath.Join(dir, ".out.tmp")) {
		t.Error("the temporary file survived a successful write")
	}
}

func TestWriteAtomicModeFailureKeepsTheOldContent(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "out")
	mustWrite(t, p, "OLD")
	if err := os.Mkdir(filepath.Join(dir, ".out.tmp"), 0o755); err != nil { // the temp name is taken by a directory
		t.Fatal(err)
	}
	if err := WriteAtomicMode(p, []byte("NEW"), 0o600); err == nil {
		t.Fatal("an unusable temp path reported success")
	}
	if read(t, p) != "OLD" {
		t.Errorf("the old content was damaged: %q", read(t, p))
	}
	// a rename that fails after the temp was written removes the temp and keeps the blocker intact
	target := filepath.Join(dir, "t")
	if err := os.MkdirAll(filepath.Join(target, "x"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := WriteAtomicMode(target, []byte("x"), 0o600); err == nil {
		t.Fatal("rename over a non-empty directory reported success")
	}
	if exists(filepath.Join(dir, ".t.tmp")) || !exists(filepath.Join(target, "x")) {
		t.Error("temp not cleaned or the blocking directory damaged")
	}
}

func TestWriteAtomicKeepsItsUmaskDerivedMode(t *testing.T) {
	old := syscall.Umask(0o027)
	defer syscall.Umask(old)
	p := filepath.Join(t.TempDir(), "out")
	if err := WriteAtomic(p, []byte("x")); err != nil || perm(t, p) != 0o640 {
		t.Fatalf("err %v mode %v, want 0666 &^ umask = 0640", err, perm(t, p))
	}
}
