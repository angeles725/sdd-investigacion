package console

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

func envIn(dir string) (*env, *bytes.Buffer, *bytes.Buffer) {
	var o, e bytes.Buffer
	s := cli.Stdio{Out: &o, Err: &e, Env: func(string) string { return "" }, Clock: time.Now, Cwd: dir}
	return newEnv(s), &o, &e
}

// mkdir -p reports the first component it cannot make, as typed, and the errno of that component.
func TestMkdirAllNamesTheFirstFailingComponent(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "file"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("nowhere", filepath.Join(dir, "dangling")); err != nil {
		t.Fatal(err)
	}
	e, _, _ := envIn(dir)
	cases := []struct{ in, failed, err string }{
		{"file", "file", "File exists"},
		{"file/", "file/", "File exists"},
		{"file/x/y", "file", "Not a directory"},
		{"dangling", "dangling", "File exists"},
		{"dangling/z", "dangling", "File exists"},
		{"a//../file//z", "a//../file", "Not a directory"},
		{"", "", "No such file or directory"},
	}
	for _, c := range cases {
		failed, err := e.mkdirAll(c.in)
		if err == nil || failed != c.failed || err.Error() != c.err {
			t.Errorf("mkdirAll(%q) = %q, %v; want %q, %q", c.in, failed, err, c.failed, c.err)
		}
	}
	// the made components are the ones before the failure, and a second call finds them present
	for _, ok := range []string{"new", "new/deeper", "a//b///c/", "rel/../rel2"} {
		if failed, err := e.mkdirAll(ok); err != nil {
			t.Errorf("mkdirAll(%q) failed at %q: %v", ok, failed, err)
		}
	}
	if fi, err := os.Stat(filepath.Join(dir, "new", "deeper")); err != nil || !fi.IsDir() {
		t.Errorf("new/deeper was not created: %v", err)
	}
}

// A file that opens but cannot be written (a full device) is a tee failure: the path is named once, stdout keeps
// every byte, and the status is 1.
func TestTeeKeepsTheStreamWhenTheFileFails(t *testing.T) {
	if _, err := os.Stat("/dev/full"); err != nil {
		t.Skip("no /dev/full on this system")
	}
	e, out, errb := envIn(t.TempDir())
	tw := e.openTee("/dev/full")
	for _, chunk := range []string{"first\n", "second\n"} {
		if n, err := tw.Write([]byte(chunk)); n != len(chunk) || err != nil {
			t.Fatalf("Write(%q) = %d, %v", chunk, n, err)
		}
	}
	if rc := tw.close(); rc != 1 {
		t.Errorf("close() = %d, want 1", rc)
	}
	if out.String() != "first\nsecond\n" {
		t.Errorf("stdout = %q", out.String())
	}
	if want := "tee: /dev/full: No space left on device\n"; errb.String() != want {
		t.Errorf("stderr = %q, want %q (one report, however many writes follow)", errb.String(), want)
	}
}

func TestTeeWritesBothCopies(t *testing.T) {
	dir := t.TempDir()
	e, out, errb := envIn(dir)
	tw := e.openTee("evidence.txt")
	if _, err := tw.Write([]byte("bytes\x00\xff")); err != nil {
		t.Fatal(err)
	}
	if rc := tw.close(); rc != 0 || errb.Len() != 0 {
		t.Errorf("close() = %d, stderr %q", rc, errb.String())
	}
	got, err := os.ReadFile(filepath.Join(dir, "evidence.txt"))
	if err != nil || !bytes.Equal(got, []byte("bytes\x00\xff")) || !strings.HasPrefix(out.String(), "bytes") {
		t.Errorf("file %q (%v), stdout %q", got, err, out.String())
	}
}

// The preservation guard needs both halves: a clean tee AND a regular file on disk.
func TestEvidenceWrittenNeedsTheTeeAndTheFile(t *testing.T) {
	dir := t.TempDir()
	reg := filepath.Join(dir, "evidence.txt")
	if err := os.WriteFile(reg, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	fileInfo, err := os.Stat(reg)
	if err != nil {
		t.Fatal(err)
	}
	dirInfo, err := os.Stat(dir)
	if err != nil {
		t.Fatal(err)
	}
	_, missing := os.Stat(filepath.Join(dir, "absent"))
	cases := []struct {
		name string
		rc   int
		fi   os.FileInfo
		err  error
		want bool
	}{
		{"clean tee and a regular file", 0, fileInfo, nil, true},
		{"tee failed after creating the file", 1, fileInfo, nil, false},
		{"clean tee but the file is gone", 0, nil, missing, false},
		{"clean tee but a directory is there", 0, dirInfo, nil, false},
		{"tee failed and no file", 1, nil, missing, false},
	}
	for _, c := range cases {
		if got := evidenceWritten(c.rc, c.fi, c.err); got != c.want {
			t.Errorf("%s: evidenceWritten = %v, want %v", c.name, got, c.want)
		}
	}
}
