//go:build linux

package fsx

import (
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"syscall"
	"testing"
)

func read(t *testing.T, p string) string {
	t.Helper()
	b, err := os.ReadFile(p)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func mustWrite(t *testing.T, p, s string) {
	t.Helper()
	if err := os.WriteFile(p, []byte(s), 0o644); err != nil {
		t.Fatal(err)
	}
}

func exists(p string) bool { _, err := os.Lstat(p); return err == nil }

func TestWriteAtomicCreatesAndReplaces(t *testing.T) {
	old := syscall.Umask(0o022)
	defer syscall.Umask(old)
	dir := t.TempDir()
	p := filepath.Join(dir, "out.json")
	if err := WriteAtomic(p, []byte("one")); err != nil {
		t.Fatal(err)
	}
	if err := WriteAtomic(p, []byte("two!")); err != nil {
		t.Fatal(err)
	}
	if read(t, p) != "two!" {
		t.Fatal("not replaced")
	}
	if st, _ := os.Stat(p); st.Mode().Perm() != 0o644 {
		t.Fatalf("mode %v (want 0666 &^ umask)", st.Mode().Perm())
	}
	if e, _ := os.ReadDir(dir); len(e) != 1 {
		t.Fatalf("temp file left behind: %v", e)
	}
	if err := WriteAtomic(p, nil); err != nil || read(t, p) != "" {
		t.Fatalf("empty write: %v", err)
	}
}

func TestWriteAtomicOverwritesStaleTemp(t *testing.T) {
	dir := t.TempDir()
	mustWrite(t, filepath.Join(dir, ".out.tmp"), "stale stale stale")
	p := filepath.Join(dir, "out")
	if err := WriteAtomic(p, []byte("ok")); err != nil || read(t, p) != "ok" {
		t.Fatalf("err %v", err)
	}
}

func TestWriteAtomicFailureLeavesNothing(t *testing.T) {
	if err := WriteAtomic(filepath.Join(t.TempDir(), "no", "dir", "f"), []byte("x")); err == nil {
		t.Fatal("missing parent must fail")
	}
	dir := t.TempDir()
	target := filepath.Join(dir, "t") // a non-empty directory: the final rename fails
	_ = os.Mkdir(target, 0o755)
	mustWrite(t, filepath.Join(target, "f"), "x")
	if err := WriteAtomic(target, []byte("x")); err == nil {
		t.Fatal("rename over a directory must fail")
	}
	if exists(filepath.Join(dir, ".t.tmp")) {
		t.Fatal("temp file not cleaned after a failed rename")
	}
}

func TestSyncDir(t *testing.T) {
	dir := t.TempDir()
	if err := SyncDir(dir); err != nil {
		t.Fatal(err)
	}
	if err := SyncDir(filepath.Join(dir, "nope")); !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("missing: %v", err)
	}
	f := filepath.Join(dir, "f")
	mustWrite(t, f, "x")
	if err := SyncDir(f); !errors.Is(err, syscall.ENOTDIR) {
		t.Fatalf("file is not a directory: %v", err)
	}
}
