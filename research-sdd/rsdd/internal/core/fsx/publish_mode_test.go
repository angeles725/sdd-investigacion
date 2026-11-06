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
}

// Two writers of one file must never share a temp: WriteAtomic's fixed sibling ".<name>.tmp" may belong to another
// run that is still writing it, so WriteAtomicMode leaves it byte-identical and uses a temp of its own.
func TestWriteAtomicModeNeverTouchesAnotherWritersTemp(t *testing.T) {
	dir := t.TempDir()
	p, other := filepath.Join(dir, "out"), filepath.Join(dir, ".out.tmp")
	if err := os.WriteFile(other, []byte("another run is writing this"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := WriteAtomicMode(p, []byte("two"), 0o640); err != nil || read(t, p) != "two" || perm(t, p) != 0o640 {
		t.Fatalf("err %v content %q mode %v", err, read(t, p), perm(t, p))
	}
	if !exists(other) || read(t, other) != "another run is writing this" || perm(t, other) != 0o600 {
		t.Errorf("the other writer's temp was touched: exists=%v", exists(other))
	}
	if names := entries(t, dir); len(names) != 2 {
		t.Errorf("entries %v, want only the file and the other writer's temp", names)
	}
}

func entries(t *testing.T, dir string) []string {
	t.Helper()
	es, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	names := make([]string, len(es))
	for i, e := range es {
		names[i] = e.Name()
	}
	return names
}

func TestWriteAtomicModeFailureKeepsTheOldContent(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "out")
	mustWrite(t, p, "OLD")
	if os.Geteuid() != 0 { // a directory that takes no new entry: the temp cannot be created
		if err := os.Chmod(dir, 0o555); err != nil {
			t.Fatal(err)
		}
		err := WriteAtomicMode(p, []byte("NEW"), 0o600)
		_ = os.Chmod(dir, 0o755)
		if err == nil {
			t.Fatal("a temp that cannot be created reported success")
		}
		if read(t, p) != "OLD" {
			t.Errorf("the old content was damaged: %q", read(t, p))
		}
	}
	// a rename that fails after the temp was written removes the temp and keeps the blocker intact
	target := filepath.Join(dir, "t")
	if err := os.MkdirAll(filepath.Join(target, "x"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := WriteAtomicMode(target, []byte("x"), 0o600); err == nil {
		t.Fatal("rename over a non-empty directory reported success")
	}
	if names := entries(t, dir); len(names) != 2 || !exists(filepath.Join(target, "x")) {
		t.Errorf("entries %v: temp not cleaned or the blocking directory damaged", names)
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
