package srcregistry

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const abcSHA = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

func TestSHA256Helpers(t *testing.T) {
	if got := SHA256Hex([]byte("abc")); got != abcSHA {
		t.Errorf("hex %s", got)
	}
	p := filepath.Join(t.TempDir(), "f")
	if err := os.WriteFile(p, []byte("abc"), 0o644); err != nil {
		t.Fatal(err)
	}
	if got, err := FileSHA256(p); err != nil || got != abcSHA {
		t.Errorf("file %s %v", got, err)
	}
	id, err := Identity(p)
	if err != nil || id.SHA256 != "sha256:"+abcSHA || id.Size != 3 {
		t.Errorf("identity %+v %v", id, err)
	}
}

func TestFileSHA256RefusesSymlinkAndMissing(t *testing.T) {
	d := t.TempDir()
	if err := os.WriteFile(filepath.Join(d, "f"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(d, "f"), filepath.Join(d, "l")); err != nil {
		t.Fatal(err)
	}
	if _, err := FileSHA256(filepath.Join(d, "l")); err == nil {
		t.Error("a symlink must not be hashed")
	}
	if _, err := FileSHA256(filepath.Join(d, "none")); err == nil {
		t.Error("a missing file must not hash to a value")
	}
}

func TestAppendCreatesWithHeaderAndKeepsMode(t *testing.T) {
	d := t.TempDir()
	if err := Append(d, "| a | k | o | d | s | |"); err != nil {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(filepath.Join(d, SourcesFile))
	if !strings.HasPrefix(string(b), Header) || !strings.HasSuffix(string(b), "| a | k | o | d | s | |\n") {
		t.Errorf("%q", b)
	}
	if fi, _ := os.Stat(filepath.Join(d, SourcesFile)); fi.Mode().Perm() != 0o644 {
		t.Errorf("new document mode %v", fi.Mode())
	}
	if err := os.Chmod(filepath.Join(d, SourcesFile), 0o664); err != nil {
		t.Fatal(err)
	}
	if err := Append(d, "| b | k | o | d | s | |"); err != nil {
		t.Fatal(err)
	}
	if fi, _ := os.Stat(filepath.Join(d, SourcesFile)); fi.Mode().Perm() != 0o664 {
		t.Errorf("existing mode not kept: %v", fi.Mode())
	}
	if ents, _ := os.ReadDir(d); len(ents) != 1 {
		t.Errorf("temporary file left behind: %v", ents)
	}
}

func TestRetargetAndHasOnDisk(t *testing.T) {
	d := t.TempDir()
	if n, err := Retarget(d, "a", "b", "s"); n != 0 || err != nil {
		t.Errorf("missing document: %d %v", n, err)
	}
	if ok, err := Has(d, "a", ""); ok || err != nil {
		t.Errorf("missing document has no row: %v %v", ok, err)
	}
	if err := Append(d, "| a | k | o | d | s | |"); err != nil {
		t.Fatal(err)
	}
	if n, err := Retarget(d, "a", "b", "s"); n != 0 || err != nil {
		t.Errorf("%d %v", n, err)
	}
	if ok, _ := Has(d, "b", "s"); !ok {
		t.Error("row not retargeted")
	}
	if ok, _ := Has(d, "a", ""); ok {
		t.Error("old row still there")
	}
}

func TestAppendReportsAnUnwritableDirectory(t *testing.T) {
	if err := Append(filepath.Join(t.TempDir(), "missing"), "| a |"); err == nil {
		t.Error("an absent sources directory must be an error, not a silent skip")
	}
}
