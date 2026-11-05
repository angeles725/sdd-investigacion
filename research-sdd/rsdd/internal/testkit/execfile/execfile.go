// Package execfile writes the fake executables of tests.
//
// A test that writes an executable while parallel tests fork child processes can fail to run it with ETXTBSY
// (golang/go#22315): a fork that happens while the new file is still open for writing hands a copy of that
// descriptor to the child until the child execs, and Linux refuses to exec a file that is open for writing.
// os/exec forks while holding syscall.ForkLock for writing, so Write holds it for reading from open to close:
// no fork can start while the descriptor is open, and no child can carry it.
package execfile

import (
	"os"
	"path/filepath"
	"syscall"
	"testing"
)

// Write creates (or replaces) path with body, mode 0755 whatever the umask, creating its parent directories. Any
// failure fails the test.
func Write(tb testing.TB, path, body string) {
	tb.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		tb.Fatal(err)
	}
	if err := write(path, body); err != nil {
		tb.Fatal(err)
	}
}

func write(path, body string) error {
	syscall.ForkLock.RLock()
	defer syscall.ForkLock.RUnlock()
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o755)
	if err != nil {
		return err
	}
	if _, err := f.WriteString(body); err != nil {
		f.Close()
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	return os.Chmod(path, 0o755)
}
