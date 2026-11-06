package fetchdoc

import (
	"os"
	"strings"
	"testing"
)

// A SOURCES.md that exists but cannot be read is not "no rows": the stale-part sweep would take a registered file
// that carries the part-file marker for debris. The run refuses, names the registry, exits 1 and removes nothing.
func TestUnreadableRegistryRefusesTheRunAndDeletesNothing(t *testing.T) {
	for _, m := range []struct{ mode, sub string }{{"doc", "datasheets"}, {"web", "web-snapshots"}} {
		testUnreadableRegistry(t, m.mode, m.sub)
	}
}

func testUnreadableRegistry(t *testing.T, mode, sub string) {
	t.Helper()
	for _, how := range []string{"mode 000", "directory"} {
		t.Run(mode+"/"+how, func(t *testing.T) {
			if how == "mode 000" && os.Geteuid() == 0 {
				t.Skip("a permission case needs a non-root user")
			}
			w := newWorld(t, "curl", "wget")
			w.setEnv("STUB_ROUTES=")
			seeded(sub+"/spec.fetchdoc-part.333", "evidence\n")(w)
			md := w.path("sources/SOURCES.md")
			if how == "directory" {
				_ = os.Remove(md)
				if err := os.Mkdir(md, 0o755); err != nil {
					t.Fatal(err)
				}
			} else {
				if err := os.Chmod(md, 0); err != nil {
					t.Fatal(err)
				}
				t.Cleanup(func() { _ = os.Chmod(md, 0o644) })
			}
			got := w.goRun(mode, "http://h/a.pdf", w.dir)
			if got.rc != exitFailure {
				t.Errorf("exit %d, want %d; err=%q", got.rc, exitFailure, got.err)
			}
			if !strings.Contains(got.err, "cannot read "+md) {
				t.Errorf("the notice does not name the registry: %q", got.err)
			}
			if b, _ := os.ReadFile(w.path("sources/" + sub + "/spec.fetchdoc-part.333")); string(b) != "evidence\n" {
				t.Errorf("the registered file was removed or changed: %q", b)
			}
			if exists(w.path("sources/datasheets/a.pdf")) || exists(w.path("sources/web-snapshots/h_a.pdf.md")) {
				t.Error("the run went on to install a download")
			}
		})
	}
}
