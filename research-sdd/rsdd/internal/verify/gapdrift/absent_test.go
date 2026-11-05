package gapdrift

import (
	"bytes"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"testing"
)

// An absent state file and an unreadable one print the same line (the script's), but stay distinguishable to a
// caller (CLAUDE.md section 7): only the absent one wraps fs.ErrNotExist.
func TestAbsentStateIsDistinctFromUnreadable(t *testing.T) {
	t.Parallel()
	dir := corpus(t, map[string]string{"locked.md": "x\n"})
	locked := filepath.Join(dir, "locked.md")
	if err := os.Chmod(locked, 0); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(locked, 0o644) })
	var out, errb bytes.Buffer
	for _, c := range []struct {
		state  string
		absent bool
	}{{filepath.Join(dir, "missing.md"), true}, {locked, false}} {
		_, err := runArgs([]string{dir, "--state", c.state}, stdio(&out, &errb, dir))
		var e *Error
		if !errors.As(err, &e) || e.Kind != ErrStateUnreadable || e.Msg != "check-gap-drift: cannot read state file "+c.state {
			t.Fatalf("%s: err = %v, want ErrStateUnreadable with the script's message", c.state, err)
		}
		if got := errors.Is(err, fs.ErrNotExist); got != c.absent && (c.absent || os.Geteuid() != 0) {
			t.Errorf("%s: errors.Is(err, fs.ErrNotExist) = %v, want %v", c.state, got, c.absent)
		}
	}
}
