package fetchdoc

import (
	"errors"
	"os"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/srcregistry"
)

// A hashing failure must never leave bytes in sources/ without their row: the file is hashed while it is still a
// part file, before the install, so the run fails with nothing placed and the next run is not refused with exit 4.
func TestHashFailureLeavesNothingPlacedInDocAndWebMode(t *testing.T) {
	for _, mode := range [][]string{{"doc", "http://h/a.pdf"}, {"web", "http://h/page"}} {
		t.Run(mode[0], func(t *testing.T) {
			w := newWorld(t, "curl", "wget", "pandoc")
			w.setEnv("STUB_ROUTES=")
			w.hash = func(string) (string, error) { return "", errors.New("hash unavailable on this OS") }
			got := w.goRun(append(mode, w.dir)...)
			if got.rc != 1 {
				t.Errorf("exit %d, want 1; err=%q", got.rc, got.err)
			}
			for _, p := range []string{"sources/datasheets/a.pdf", "sources/web-snapshots/h_page.md", "sources/SOURCES.md"} {
				if exists(w.path(p)) {
					t.Errorf("%s was placed although hashing failed", p)
				}
			}
			if p := partFiles(w); len(p) != 0 {
				t.Errorf("part files left: %v", p)
			}
			// the retry, with a working hash, is not refused: nothing was left behind
			w.hash = nil
			if again := w.goRun(append(mode, w.dir)...); again.rc != 0 {
				t.Errorf("retry exit %d: %q", again.rc, again.err)
			}
		})
	}
}

// The staged file is the one hashed, and the row carries that hash.
func TestHashIsTakenOnTheStagedFile(t *testing.T) {
	w := newWorld(t, "curl", "wget")
	w.setEnv("STUB_ROUTES=")
	var seen string
	w.hash = func(p string) (string, error) {
		seen = p
		return srcregistry.FileSHA256(p)
	}
	if got := w.goRun("doc", "http://h/a.pdf", w.dir); got.rc != 0 {
		t.Fatalf("exit %d: %q", got.rc, got.err)
	}
	if seen == "" || seen == w.path("sources/datasheets/a.pdf") {
		t.Errorf("hashed %q: want the part file, not the destination", seen)
	}
	md, _ := os.ReadFile(w.path("sources/SOURCES.md"))
	b, _ := os.ReadFile(w.path("sources/datasheets/a.pdf"))
	if !srcregistry.HasRow(md, "datasheets/a.pdf", srcregistry.SHA256Hex(b)) {
		t.Errorf("the row does not carry the sha256 of the installed bytes:\n%s", md)
	}
}
