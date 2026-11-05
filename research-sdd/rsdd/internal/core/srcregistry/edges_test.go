package srcregistry

import (
	"os"
	"path/filepath"
	"testing"
)

func TestInsertRowAfterATableThatIsTheFirstLine(t *testing.T) {
	md := "| a |\n\nprose\n"
	if got := string(InsertRow([]byte(md), "| N |")); got != "| a |\n| N |\n\nprose\n" {
		t.Errorf("%q", got)
	}
}

func TestWriteReplacesAtomicallyAndReportsARenameFailure(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "SOURCES.md")
	if err := write(path, []byte("new\n"), 0o640); err != nil {
		t.Fatal(err)
	}
	if b, _ := os.ReadFile(path); string(b) != "new\n" {
		t.Errorf("wrote %q", b)
	}
	if fi, _ := os.Stat(path); fi.Mode().Perm() != 0o640 {
		t.Errorf("mode %v", fi.Mode().Perm())
	}
	// a non-empty directory in the way: the rename fails, the error is returned and no temporary file is left
	blocked := filepath.Join(dir, "blocked")
	if err := os.MkdirAll(filepath.Join(blocked, "x"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := write(blocked, []byte("z"), 0o644); err == nil {
		t.Error("a rename onto a non-empty directory reported success")
	}
	left, _ := filepath.Glob(filepath.Join(dir, ".sources-md-*"))
	if len(left) != 0 {
		t.Errorf("temporary files left: %v", left)
	}
}
