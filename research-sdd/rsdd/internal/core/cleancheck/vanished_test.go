package cleancheck

import (
	"errors"
	"io/fs"
	"os"
	"testing"
)

// flakyEntry is a directory entry whose Info fails the way a file removed between ReadDir and Info does.
type flakyEntry struct {
	fs.DirEntry
	err error
}

func (f flakyEntry) Info() (fs.FileInfo, error) { return nil, f.err }

// fakeDir makes listDir see these entries (real ones from a scratch directory, plus the flaky ones) instead of reading.
func fakeDir(t *testing.T, real string, extra ...fs.DirEntry) {
	t.Helper()
	old := readDir
	t.Cleanup(func() { readDir = old })
	readDir = func(dir string) ([]fs.DirEntry, error) {
		des, err := os.ReadDir(real)
		return append(des, extra...), err
	}
}

// An entry that vanished between the listing and its Info is left out (find's -ignore_readdir_race); the others stay.
func TestListDirLeavesOutAVanishedEntry(t *testing.T) {
	w := newWorld(t)
	w.writeAt(w.scratch+"/kept.txt", "x")
	gone := flakyEntry{DirEntry: dirEntryNamed(t, w, "gone.txt"), err: &fs.PathError{Op: "lstat", Path: "gone.txt", Err: fs.ErrNotExist}}
	fakeDir(t, w.scratch, gone)
	got, err := listDir(w.scratch)
	if err != nil || len(got) != 1 || got[0].name != "kept.txt" {
		t.Fatalf("listDir = %v, %v; want only kept.txt and no error", got, err)
	}
}

// Any other Info failure is a real read error and ends the listing.
func TestListDirFailsOnAnotherInfoError(t *testing.T) {
	w := newWorld(t)
	w.writeAt(w.scratch+"/kept.txt", "x")
	boom := flakyEntry{DirEntry: dirEntryNamed(t, w, "boom.txt"), err: &fs.PathError{Op: "lstat", Path: "boom.txt", Err: fs.ErrPermission}}
	fakeDir(t, w.scratch, boom)
	if got, err := listDir(w.scratch); !errors.Is(err, fs.ErrPermission) || got != nil {
		t.Fatalf("listDir = %v, %v; want the permission error and no entries", got, err)
	}
}

// dirEntryNamed is a real entry of the world (any), renamed through the embedding; only Name matters to listDir.
func dirEntryNamed(t *testing.T, w *world, name string) fs.DirEntry {
	t.Helper()
	w.writeAt(w.root+"/stub/"+name, "x")
	des, err := os.ReadDir(w.root + "/stub")
	if err != nil || len(des) == 0 {
		t.Fatal(err)
	}
	return des[0]
}
