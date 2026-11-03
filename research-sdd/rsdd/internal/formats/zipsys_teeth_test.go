//go:build linux

package formats

import (
	"errors"
	"io"
	"os"
	"path/filepath"
	"testing"
)

func openTeethInput(t *testing.T, path string) *zipInput {
	t.Helper()
	in, _, err := zipOpenInput(path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { in.Close() })
	return in
}

func TestZipInputReadAtBounds(t *testing.T) {
	path := filepath.Join(t.TempDir(), "f")
	if err := os.WriteFile(path, []byte("0123456789"), 0o600); err != nil {
		t.Fatal(err)
	}
	in := openTeethInput(t, path)
	for name, c := range map[string]struct {
		off, n  int
		want    string
		wantErr error
	}{
		"zero length":      {0, 0, "", nil},
		"zero at the end":  {10, 0, "", nil},
		"exact":            {0, 10, "0123456789", nil},
		"exact tail":       {4, 6, "456789", nil},
		"one byte":         {9, 1, "9", nil},
		"short at the end": {6, 8, "6789", io.EOF},
		"at the end":       {10, 3, "", io.EOF},
		"past the end":     {50, 3, "", io.EOF},
	} {
		buf := make([]byte, c.n)
		n, err := in.ReadAt(buf, int64(c.off))
		if !errors.Is(err, c.wantErr) && err != c.wantErr || string(buf[:n]) != c.want {
			t.Errorf("%s: ReadAt(%d@%d) = %q, %v; want %q, %v", name, c.n, c.off, buf[:n], err, c.want, c.wantErr)
		}
	}
}

func TestZipInputResolved(t *testing.T) {
	dir, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(filepath.Join(dir, "sub"), 0o700); err != nil {
		t.Fatal(err)
	}
	real := filepath.Join(dir, "f")
	if err := os.WriteFile(real, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	indirect := filepath.Join(dir, "sub", "..", "f")
	in := openTeethInput(t, indirect)
	if got := in.Resolved(); got != real {
		t.Errorf("Resolved() = %q, want the canonical %q (opened as %q)", got, real, indirect)
	}

	// A deleted file's descriptor link ends in " (deleted)", which no path resolves: the link text itself is
	// the answer, not the empty string and not the path the file was opened by.
	gone := filepath.Join(dir, "gone")
	if err := os.WriteFile(gone, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	in2 := openTeethInput(t, filepath.Join(dir, "sub", "..", "gone"))
	if err := os.Remove(gone); err != nil {
		t.Fatal(err)
	}
	if got, want := in2.Resolved(), gone+" (deleted)"; got != want {
		t.Errorf("Resolved() of a deleted file = %q, want %q", got, want)
	}

	// A descriptor with no link: the opening path is returned.
	in3 := openTeethInput(t, indirect)
	if err := in3.Close(); err != nil {
		t.Fatal(err)
	}
	in3.fd = -1
	if got := in3.Resolved(); got != indirect {
		t.Errorf("Resolved() with no descriptor link = %q, want %q", got, indirect)
	}
}
