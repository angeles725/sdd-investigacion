package place

import (
	"os"
	"strings"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/srcregistry"
)

// breakRegistry makes the registered SOURCES.md of x unreadable in one of the two ways a run meets in the wild:
// a file without read permission, or a directory in its place.
func breakRegistry(t *testing.T, x *fx, how string) string {
	t.Helper()
	path := x.sdir + "/" + srcregistry.SourcesFile
	switch how {
	case "mode 000":
		if os.Geteuid() == 0 {
			t.Skip("a permission case needs a non-root user")
		}
		if err := os.Chmod(path, 0); err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { _ = os.Chmod(path, 0o644) })
	case "directory":
		if err := os.Remove(path); err != nil {
			t.Fatal(err)
		}
		if err := os.Mkdir(path, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	return path
}

var unreadable = []string{"mode 000", "directory"}

func TestSweepRefusesWhenTheRegistryIsUnreadableAndDeletesNothing(t *testing.T) {
	for _, how := range unreadable {
		t.Run(how, func(t *testing.T) {
			x := newFx(t, false)
			registered := x.sub + "/spec.fetchdoc-part.333" // registered evidence that merely looks like a part file
			debris := x.sub + "/a.pdf.fetchdoc-part.111"
			write(t, registered, "evidence")
			write(t, debris, "x")
			register(t, x, "datasheets/spec.fetchdoc-part.333", "sha")
			path := breakRegistry(t, x, how)
			code := x.p.SweepStale(x.sub, func(string) bool { return false })
			if code != ExitFailure {
				t.Errorf("code %d, want %d", code, ExitFailure)
			}
			for _, f := range []string{registered, debris} {
				if _, err := os.Stat(f); err != nil {
					t.Errorf("%s was deleted: %v", f, err)
				}
			}
			if msg := x.err.String(); !strings.Contains(msg, "cannot read "+path) || strings.Contains(msg, "removed stale") {
				t.Errorf("message %q", msg)
			}
		})
	}
}

func TestReplaceIdenticalBytesUnderARowWithAnotherShaIsNotRegistered(t *testing.T) {
	x := newFx(t, true)
	dest := x.sub + "/ds.pdf"
	write(t, dest, "SAME")
	register(t, x, "datasheets/ds.pdf", "legacy-sha") // the row names the file, but not these bytes
	part := dest + ".fetchdoc-part.9"
	write(t, part, "SAME")
	if same, code := x.p.Install(part, dest); same || code != 0 {
		t.Errorf("same=%v code=%d err=%q: the bytes have no row of their own, so a new row is due", same, code, x.err.String())
	}
}

func TestSweepWithAnAbsentRegistryStillRemovesDeadDebris(t *testing.T) {
	x := newFx(t, false)
	debris := x.sub + "/a.pdf.fetchdoc-part.111"
	write(t, debris, "x")
	if code := x.p.SweepStale(x.sub, func(string) bool { return false }); code != 0 {
		t.Errorf("code %d, err %q", code, x.err.String())
	}
	if _, err := os.Stat(debris); err == nil {
		t.Error("an absent SOURCES.md (no rows at all) must not stop the sweep")
	}
}

func TestReplaceRefusesWhenTheRegistryIsUnreadableAndRenamesNothing(t *testing.T) {
	for _, how := range unreadable {
		for _, newBytes := range []string{"NEW", "OLD"} { // different bytes archive; identical bytes consult the row
			t.Run(how+"/"+newBytes, func(t *testing.T) {
				x := newFx(t, true)
				dest := x.sub + "/ds.pdf"
				write(t, dest, "OLD")
				register(t, x, "datasheets/ds.pdf", srcregistry.SHA256Hex([]byte("OLD")))
				part := dest + ".fetchdoc-part.9"
				write(t, part, newBytes)
				path := breakRegistry(t, x, how)
				same, code := x.p.Install(part, dest)
				if same || code != ExitFailure {
					t.Errorf("same=%v code=%d", same, code)
				}
				if read(t, dest) != "OLD" || read(t, part) != newBytes {
					t.Errorf("dest %q part %q: something was moved", read(t, dest), read(t, part))
				}
				ents, _ := os.ReadDir(x.sub)
				if len(ents) != 2 {
					t.Errorf("unexpected files in the sources directory: %v", ents)
				}
				if msg := x.err.String(); !strings.Contains(msg, "cannot read "+path) {
					t.Errorf("message %q", msg)
				}
			})
		}
	}
}
