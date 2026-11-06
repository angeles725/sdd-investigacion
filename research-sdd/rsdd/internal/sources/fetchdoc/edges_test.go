package fetchdoc

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/sources/download"
)

func TestBaseNameEdges(t *testing.T) {
	for url, want := range map[string]string{
		"http://h/a.pdf?x=1": "a.pdf", "?x": "", "/a": "a", "/a/": "a", "a": "a", "http://h/d/b.pdf": "b.pdf", "": "",
	} {
		if got := baseName(url); got != want {
			t.Errorf("baseName(%q) = %q, want %q", url, got, want)
		}
	}
}

func TestCheckURLControlCharacterBoundary(t *testing.T) {
	for url, refused := range map[string]bool{
		"http://h/a b": false, "http://h/a~": false, "http://h/a\x1f": true, "http://h/a\x7f": true, "http://h/a\n": true, "-x": true,
	} {
		if got := checkURL(url) != ""; got != refused {
			t.Errorf("checkURL(%q) refused=%v, want %v", url, got, refused)
		}
	}
}

func TestAsExitMapsStageStatuses(t *testing.T) {
	x := &exe{sess: newSession(nil)}
	defer x.sess.Close()
	for in, want := range map[int]int{0: 0, 1: 1, 3: 3, 4: 4, 5: 5, download.Cancelled: exitFailure} {
		if got := x.asExit(in); got != want {
			t.Errorf("asExit(%d) = %d, want %d", in, got, want)
		}
	}
	x.sess.code.Store(143)
	if got := x.asExit(download.Cancelled); got != 143 {
		t.Errorf("a cancelled stage after TERM is %d, want 143", got)
	}
}

func TestCopyFileCopiesAndReportsFailures(t *testing.T) {
	dir := t.TempDir()
	src, dst := filepath.Join(dir, "in"), filepath.Join(dir, "out")
	if err := os.WriteFile(src, []byte("body"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := copyFile(src, dst); err != nil {
		t.Fatal(err)
	}
	if b, _ := os.ReadFile(dst); string(b) != "body" {
		t.Errorf("copied %q", b)
	}
	if err := copyFile(filepath.Join(dir, "missing"), dst); err == nil {
		t.Error("a missing source was copied")
	}
	if err := copyFile(src, filepath.Join(dir, "no-dir", "out")); err == nil {
		t.Error("an uncreatable destination was written")
	}
	if err := copyFile(dir, filepath.Join(dir, "out2")); err == nil {
		t.Error("a directory was copied as a file (the read error was dropped)")
	}
}
