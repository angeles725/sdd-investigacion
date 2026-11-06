//go:build unix && !nodiff

package deploy

import (
	"os"
	"path/filepath"
	"testing"
)

const (
	piRenderDir = ".pi/agent/research-sdd/profile/general"
	piRecord    = ".pi/agent/research-sdd/.installed-bundle-state"
)

// Failure mode "Unrecorded file in the render dir: REFUSED exit 1, nothing removed; --backup-unrecorded moves it."
// The backup directory name embeds a UTC stamp, masked as <UTC> in text and in the tree snapshot.
func TestUnrecordedFileInRenderDir(t *testing.T) {
	w := newWorld(t)
	w.check("install", w.install("--harness", "pi"), 0, fromGolden, "")
	const mine = "my notes, not in the bundle record\n\x00\xff bytes\n"
	w.seed(piRenderDir+"/NOTES.md", mine)
	record := w.homeText(piRecord)
	w.check("refused", w.install("--harness", "pi"), 1, fromGolden, fromGolden)
	assertEq(t, "the unrecorded file after a refusal", w.homeText(piRenderDir+"/NOTES.md"), mine)
	assertEq(t, "the bundle record after a refusal", w.homeText(piRecord), record)
	w.check("backup", w.install("--harness", "pi", "--backup-unrecorded"), 0, fromGolden, "")
	if _, err := os.Lstat(w.hp(piRenderDir + "/NOTES.md")); !os.IsNotExist(err) {
		t.Errorf("the unrecorded file is still in the render dir: %v", err)
	}
	moved, err := filepath.Glob(w.hp(".pi/agent/research-sdd/backups/unrecorded-general-*/NOTES.md"))
	if err != nil || len(moved) != 1 {
		t.Fatalf("want exactly one moved copy under backups/, got %v (%v)", moved, err)
	}
	assertEq(t, "the moved file", w.read(moved[0]), mine)
}

// Failure mode "Symlinked research-sdd/profile: refuse to clean". The link target lives inside the scratch home and
// its content must be untouched. Three shapes: a profile dir link whose target holds a file (the unrecorded-file
// guard fires first), one whose target holds an empty render dir (the cleaner's own symlink-in-chain refusal), and
// a symlinked render dir (the guard's "it is a symlink" refusal).
func TestSymlinkedProfileDirIsNotCleaned(t *testing.T) {
	cases := []struct {
		name  string
		build func(w *world)
		link  string // the path below home that must still be a symlink
		keep  string // a path below home whose content must be untouched ("" = none)
	}{
		{"profile dir link, target has a file", func(w *world) {
			w.seed("elsewhere/general/KEEP.md", "outside content\n")
			w.link(".pi/agent/research-sdd/profile", w.hp("elsewhere"))
		}, ".pi/agent/research-sdd/profile", "elsewhere/general/KEEP.md"},
		{"profile dir link, target has an empty render dir", func(w *world) {
			mkdir(w.t, w.hp("elsewhere/general"))
			w.link(".pi/agent/research-sdd/profile", w.hp("elsewhere"))
		}, ".pi/agent/research-sdd/profile", ""},
		{"render dir link", func(w *world) {
			w.seed("elsewhere/KEEP.md", "outside content\n")
			w.link(piRenderDir, w.hp("elsewhere"))
		}, piRenderDir, "elsewhere/KEEP.md"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			w := newWorld(t)
			c.build(w)
			w.check("install", w.install("--harness", "pi"), 1, fromGolden, fromGolden)
			if c.keep != "" {
				assertEq(t, "the link target's content", w.homeText(c.keep), "outside content\n")
			}
			if fi, err := os.Lstat(w.hp(c.link)); err != nil || fi.Mode()&os.ModeSymlink == 0 {
				t.Errorf("the link was replaced: %v %v", fi, err)
			}
			if _, err := os.Lstat(w.hp(piRecord)); !os.IsNotExist(err) {
				t.Errorf("a bundle record exists after a refusal: %v", err)
			}
		})
	}
}
