//go:build linux

package formats

import (
	"errors"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"testing"
)

func TestZipCreateWritesOwnerReadOnlyExclusive(t *testing.T) {
	dir := t.TempDir()
	root, err := os.OpenRoot(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer root.Close()
	if err := zipCreate(root, "f", []byte("data")); err != nil {
		t.Fatal(err)
	}
	fi, err := os.Stat(filepath.Join(dir, "f"))
	if err != nil || fi.Mode().Perm() != 0o400 || fi.Size() != 4 {
		t.Errorf("created file: %v %v", fi, err)
	}
	if err := zipCreate(root, "f", []byte("again")); !errors.Is(err, os.ErrExist) {
		t.Errorf("second create: %v", err)
	}
}

// A failing write must surface its error (and not be followed by a "successful" sync and close). The write
// fails for real: the file-size resource limit is 0 for the length of the call. The test is deliberately not
// parallel, so no other test writes a file while the limit is lowered.
func TestZipCreateReportsWriteError(t *testing.T) {
	dir := t.TempDir()
	root, err := os.OpenRoot(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer root.Close()

	var old syscall.Rlimit
	if err := syscall.Getrlimit(syscall.RLIMIT_FSIZE, &old); err != nil {
		t.Skipf("no RLIMIT_FSIZE: %v", err)
	}
	signal.Ignore(syscall.SIGXFSZ)
	defer signal.Reset(syscall.SIGXFSZ)
	if err := syscall.Setrlimit(syscall.RLIMIT_FSIZE, &syscall.Rlimit{Cur: 0, Max: old.Max}); err != nil {
		t.Skipf("cannot lower RLIMIT_FSIZE: %v", err)
	}
	err = zipCreate(root, "big", []byte("x"))
	if rerr := syscall.Setrlimit(syscall.RLIMIT_FSIZE, &old); rerr != nil {
		t.Fatalf("cannot restore RLIMIT_FSIZE: %v", rerr)
	}
	if !errors.Is(err, syscall.EFBIG) {
		t.Errorf("zipCreate with a refused write returned %v, want EFBIG", err)
	}
}
