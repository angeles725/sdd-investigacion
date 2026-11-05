package cleancheck

import (
	"crypto/sha256"
	"encoding/hex"
	"os"
)

func sum(s string) string { h := sha256.Sum256([]byte(s)); return hex.EncodeToString(h[:]) }

func withScratch(extra ...string) func(w *world) []string {
	return func(w *world) []string {
		return append([]string{"--target", w.repo, "--tmp", w.tmp, "--scratchpad", w.scratch}, extra...)
	}
}

// scratchWorld is a repository with blocks, probes and a manifest, and a scratchpad of files each telling one
// story of (c) and (d).
func scratchWorld(w *world) {
	keep(w, "docs/\nsources/\n")
	w.write("docs/b1.md", "see (out.json) and `keep.dat`.\nrun.sh, then run: other.py\nthe layout is fine; /abs/dir/full.json too\nprerun.sh is not run.sh? no: prerun.sh\n")
	w.write("docs/b2.md", "mentions \"quoted.txt\" and <angle.txt> and [brk.txt] and pipe|pipe.txt| and (paren.txt) and end.txt.\nlast line cites tail.txt")
	w.write("sources/probes/b1/run.sh", "#!/bin/sh\n")
	w.write("sources/probes/b1/keep.dat", "payload\n")
	w.write("sources/probes/b1/SCRIPTS-MANIFEST.md", "| script | sha256 |\n|---|---|\n| run.sh | "+sum("#!/bin/sh\n")+" |\n| ./dot.sh | "+sum("dot")+" |\n| other.py | TODO |\n| `sub/ticks.rb` | "+sum("t")+" |\n| short.pl | abcd |\n")
	w.writeAt(w.scratch+"/out.json", "{}")
	w.writeAt(w.scratch+"/out", "no")
	w.writeAt(w.scratch+"/layout.txt", "no")
	w.writeAt(w.scratch+"/keep.dat", "payload\n")
	w.writeAt(w.scratch+"/run.sh", "#!/bin/sh\n")
	w.writeAt(w.scratch+"/dot.sh", "dot")
	w.writeAt(w.scratch+"/ticks.rb", "t")
	w.writeAt(w.scratch+"/other.py", "py")
	w.writeAt(w.scratch+"/prerun.sh", "pre")
	w.writeAt(w.scratch+"/short.pl", "pl")
	w.writeAt(w.scratch+"/x.sh", "x")
	w.writeAt(w.scratch+"/sub/y.ps1", "y")
	w.writeAt(w.scratch+"/sub/deep/z.kts", "z")
	w.writeAt(w.scratch+"/full.json", "{}")
	for _, n := range []string{"quoted.txt", "angle.txt", "brk.txt", "pipe.txt", "paren.txt", "end.txt", "tail.txt"} {
		w.writeAt(w.scratch+"/"+n, n)
	}
	w.writeAt(w.scratch+"/notes.TXT", "n")
	w.writeAt(w.scratch+"/Upper.SH", "u")
}

// scratchScenarios are the scratchpad cases (c) and (d).
func scratchScenarios() []scenario {
	return []scenario{
		{name: "scratchpad-not-set-has-no-scan", build: func(w *world) { keep(w, ""); w.writeAt(w.scratch+"/x.sh", "x") }, args: std(), want: 0},
		{name: "scratchpad-absent", build: func(w *world) { keep(w, "") }, args: stdW(func(w *world) []string { return []string{"--scratchpad", w.root + "/nope"} }), want: 0},
		{name: "scratchpad-absent-relative-with-slash", build: func(w *world) { keep(w, "") }, args: stdW(func(*world) []string { return []string{"--scratchpad", "nope//"} }), want: 0},
		{name: "scratchpad-empty", build: func(w *world) { keep(w, "") }, args: withScratch(), want: 0},
		{name: "scratchpad-stories", build: scratchWorld, args: withScratch(), want: 1},
		{name: "scratchpad-from-environment", build: scratchWorld, args: std(),
			env: func(w *world) []string { return []string{"CLEAN_CHECK_SCRATCHPAD=" + w.scratch} }, want: 1},
		{name: "scratchpad-flag-wins-over-environment", build: scratchWorld, args: withScratch(),
			env: func(w *world) []string { return []string{"CLEAN_CHECK_SCRATCHPAD=" + w.root + "/other"} }, want: 1},
		{name: "scratchpad-environment-absent", build: func(w *world) { keep(w, "") }, args: std(),
			env: func(w *world) []string { return []string{"CLEAN_CHECK_SCRATCHPAD=" + w.root + "/nope"} }, want: 0},
		{name: "scratchpad-with-trailing-slash", build: scratchWorld, args: stdW(func(w *world) []string { return []string{"--scratchpad", w.scratch + "/"} }), want: 1},
		{name: "scratchpad-inside-the-target-is-exempt", build: func(w *world) {
			keep(w, "")
			w.write("scratchdir/a.txt", "x")
			w.write("scratchdir/run.sh", "x")
			w.write("docs/b.md", "cites a.txt\n")
			w.write("stray.txt", "x")
		}, args: stdW(func(w *world) []string { return []string{"--scratchpad", w.repo + "/scratchdir"} }), want: 1},
		{name: "scratchpad-block-deleted-from-disk", build: func(w *world) {
			keep(w, "")
			w.write("docs/gone.md", "cites a.txt\n")
			w.git("add", "docs/gone.md")
			w.commit("gone")
			if err := os.Remove(w.repo + "/docs/gone.md"); err != nil {
				w.t.Fatal(err)
			}
			w.writeAt(w.scratch+"/a.txt", "x")
		}, args: withScratch(), want: 0},
		{name: "scratchpad-manifest-md-is-not-a-block", build: func(w *world) {
			keep(w, "sources/\n")
			w.write("sources/probes/b/SCRIPTS-MANIFEST.md", "| a.sh | "+sum("a")+" |\nmentions only-in-manifest.txt\n")
			w.writeAt(w.scratch+"/only-in-manifest.txt", "x")
			w.writeAt(w.scratch+"/a.sh", "a")
		}, args: withScratch(), want: 0},
		{name: "scratchpad-cited-by-first-block-in-order", build: func(w *world) {
			keep(w, "")
			w.write("b/z.md", "z.txt here\n")
			w.write("a/m.md", "z.txt there\n")
			w.writeAt(w.scratch+"/z.txt", "x")
		}, args: withScratch(), want: 1},
		{name: "scratchpad-vanishing-subdirectory-is-fine", build: func(w *world) { keep(w, ""); w.writeAt(w.scratch+"/d/f.txt", "x") }, args: withScratch(), want: 0},
		{name: "scratchpad-symlinks-are-not-files", build: func(w *world) {
			keep(w, "")
			w.writeAt(w.root+"/target.sh", "x")
			if err := os.Symlink(w.root+"/target.sh", w.scratch+"/link.sh"); err != nil {
				w.t.Fatal(err)
			}
			w.writeAt(w.scratch+"/real.txt", "x")
		}, args: withScratch(), want: 0},
		{name: "scratchpad-unreadable-directory", root: true, build: func(w *world) {
			keep(w, "")
			w.writeAt(w.scratch+"/locked/f.txt", "x")
			if err := os.Chmod(w.scratch+"/locked", 0); err != nil {
				w.t.Fatal(err)
			}
			w.t.Cleanup(func() { _ = os.Chmod(w.scratch+"/locked", 0o755) })
		}, args: withScratch(), want: 2},
	}
}
