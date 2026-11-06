package fetchdoc

import (
	"os"
	"strings"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/testkit/execfile"
)

// A conversion that fails altogether (pandoc fails and the plain copy cannot be written) never touches a snapshot
// that is already registered: with --replace the old bytes stay byte-identical, no row is added and no part file
// is left behind.
func TestFailedWebConversionLeavesTheRegisteredSnapshotIntact(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("a permission case needs a non-root user")
	}
	w := newWorld(t, "curl", "wget", "pandoc-fail")
	w.setEnv("STUB_ROUTES=", "STUB_BODY=NEW")
	const snap = "sources/web-snapshots/h_page.md"
	w.write(snap, "OLD\n")
	dir := w.path("sources/web-snapshots")
	if err := os.Chmod(dir, 0o555); err != nil { // the part file cannot be created, so the copy fails
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(dir, 0o755) })

	got := w.goRun("--replace", "web", "http://h/page", w.dir)
	if got.rc != exitFailure {
		t.Errorf("exit %d, want %d; err=%q", got.rc, exitFailure, got.err)
	}
	if !strings.Contains(got.err, "fetch-doc: cannot copy the page into ") {
		t.Errorf("the copy failure is not reported: %q", got.err)
	}
	if b, err := os.ReadFile(w.path(snap)); err != nil || string(b) != "OLD\n" {
		t.Errorf("the registered snapshot changed: %q %v", b, err)
	}
	if exists(w.path("sources/SOURCES.md")) {
		t.Error("a row was written for a snapshot that was never installed")
	}
	if p := partFiles(w); len(p) != 0 {
		t.Errorf("part files left: %v", p)
	}
	if left, _ := os.ReadDir(w.tmp); len(left) != 0 {
		t.Errorf("staged files left in the temp dir: %d", len(left))
	}
}

// The downloaded page is staged in the temp dir the run was given and removed afterwards. This is what makes the
// "nothing is left in the temp dir" assertions of the failure tests mean something: files really are created there.
func TestStagedPageLivesInTheTempDirAndIsRemoved(t *testing.T) {
	w := newWorld(t, "curl", "wget")
	w.setEnv("STUB_ROUTES=", "STUB_PANDOC_SAW="+w.path("pandoc-saw"))
	execfile.Write(t, w.bin+"/pandoc", "#!/usr/bin/env bash\nin=\"${@: -3:1}\"; out=\"${@: -1}\"\nprintf '%s' \"$in\" > \"$STUB_PANDOC_SAW\"\ncp \"$in\" \"$out\"\n")
	if got := w.goRun("web", "http://h/page", w.dir); got.rc != 0 {
		t.Fatalf("exit %d: %q", got.rc, got.err)
	}
	saw, err := os.ReadFile(w.path("pandoc-saw"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(string(saw), w.tmp+"/") {
		t.Errorf("pandoc read %q: want a file under the run's temp dir %s", saw, w.tmp)
	}
	if left, _ := os.ReadDir(w.tmp); len(left) != 0 {
		t.Errorf("staged files left in the temp dir after a successful run: %d", len(left))
	}
}
