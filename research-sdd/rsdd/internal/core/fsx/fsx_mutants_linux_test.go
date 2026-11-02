//go:build linux

package fsx

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"testing"
)

// These tests pin behaviour that only the bash/python differential tests used to cover, so the mutation run (which
// drops those with -tags nodiff) still has teeth.

func TestOpenAndOpenWONewErrorsReturnFdMinusOne(t *testing.T) {
	dir := t.TempDir()
	if fd, _, err := OpenRO(filepath.Join(dir, "missing")); err == nil || fd != -1 {
		t.Fatalf("OpenRO missing: fd=%d err=%v", fd, err)
	}
	if fd, _, err := OpenRO(dir); !errors.Is(err, ErrNotRegular) || fd != -1 {
		t.Fatalf("OpenRO directory: fd=%d err=%v", fd, err)
	}
	existing := writeFile(t, "e", []byte("x"))
	if fd, err := OpenWONew(existing); err == nil || fd != -1 {
		t.Fatalf("OpenWONew existing: fd=%d err=%v", fd, err)
	}
}

// The read length is clamped to the bytes left under the cap plus one. A file exactly one chunk long under a cap of
// one chunk, and one that crosses a chunk boundary and ends within the cap, must both hash in full.
func TestIdentityCapAtChunkBoundaries(t *testing.T) {
	for _, size := range []int{chunkSize, chunkSize + 5} {
		data := bytes.Repeat([]byte("a"), size)
		p := writeFile(t, "big", data)
		id, err := Identity(p, int64(size))
		if err != nil {
			t.Fatalf("size %d cap %d: %v", size, size, err)
		}
		if id.Size != int64(size) || id.SHA256 != "sha256:"+sum(data) {
			t.Fatalf("size %d: got %d %s", size, id.Size, id.SHA256)
		}
		if _, err := Identity(p, int64(size)-1); !errors.Is(err, ErrTooLarge) {
			t.Fatalf("size %d cap-1: %v", size, err)
		}
	}
}

func TestStageFileCapAtChunkBoundaries(t *testing.T) {
	for _, size := range []int{chunkSize, chunkSize + 5} {
		data := bytes.Repeat([]byte("b"), size)
		dir := t.TempDir()
		src, dst := filepath.Join(dir, "src"), filepath.Join(dir, "dst")
		if err := os.WriteFile(src, data, 0o644); err != nil {
			t.Fatal(err)
		}
		if _, rec, err := StageFile(src, dst, "l", 0o600, int64(size)); err != nil || rec.Size != int64(size) || rec.SHA256 != "sha256:"+sum(data) {
			t.Fatalf("size %d cap %d: rec=%+v err=%v", size, size, rec, err)
		}
		_ = os.Remove(dst)
		if _, _, err := StageFile(src, dst, "l", 0o600, int64(size)-1); !errors.Is(err, ErrTooLarge) {
			t.Fatalf("size %d cap-1: %v", size, err)
		}
	}
}
