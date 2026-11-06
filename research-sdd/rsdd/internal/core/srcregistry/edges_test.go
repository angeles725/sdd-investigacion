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

func TestAppendKeepsTheModeLeavesNoTempAndReportsAWriteFailure(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, SourcesFile)
	if err := os.WriteFile(path, []byte(Header), 0o640); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(path, 0o640); err != nil {
		t.Fatal(err)
	}
	row := FormatRow("a.pdf", "datasheet", "http://h/a", "2026-01-02T03:04:05Z", SHA256Hex([]byte("a")))
	if err := Append(dir, row); err != nil {
		t.Fatal(err)
	}
	if b, _ := os.ReadFile(path); !HasRow(b, "a.pdf", "") {
		t.Errorf("the row is missing:\n%s", b)
	}
	if fi, _ := os.Stat(path); fi.Mode().Perm() != 0o640 {
		t.Errorf("mode %v, want the existing 0640", fi.Mode().Perm())
	}
	if ents, _ := os.ReadDir(dir); len(ents) != 1 {
		t.Errorf("stray files next to SOURCES.md: %v", ents)
	}
	// the write cannot start (its temp path is a directory): the error is returned and the document is intact
	before, _ := os.ReadFile(path)
	if err := os.Mkdir(filepath.Join(dir, "."+SourcesFile+".tmp"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := Append(dir, FormatRow("b.pdf", "datasheet", "http://h/b", "2026-01-02T03:04:05Z", SHA256Hex([]byte("b")))); err == nil {
		t.Error("a write that cannot start reported success")
	}
	if after, _ := os.ReadFile(path); string(after) != string(before) {
		t.Errorf("the document changed on a failed write:\n%s", after)
	}
}
