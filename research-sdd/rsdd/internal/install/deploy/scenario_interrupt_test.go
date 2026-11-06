//go:build unix && !nodiff

package deploy

import (
	"os"
	"testing"
)

// truncate cuts a deployed file to half its size without touching any marker or the bundle record: the state a
// killed `cp` leaves behind.
func (w *world) truncate(rel string) {
	w.t.Helper()
	fi, err := os.Stat(w.hp(rel))
	if err != nil {
		w.t.Fatal(err)
	}
	if err := os.Truncate(w.hp(rel), fi.Size()/2); err != nil {
		w.t.Fatal(err)
	}
}

// Failure mode "Kill during cp": a managed file left truncated no longer matches its marker. The next plain run
// reports it diverged and keeps it (nothing overwritten); --force-skill recovers it, keeping the truncated bytes
// as .local-backup.
func TestInterruptedWrite(t *testing.T) {
	const agent = ".claude/agents/research-sdd-risk.md"
	for _, rel := range []string{claudeSkill, agent} {
		t.Run(rel, func(t *testing.T) {
			w := newWorld(t)
			w.check("install", w.install("--harness", "claude"), 0, fromGolden, "")
			good := w.homeText(rel)
			w.truncate(rel)
			cut := w.homeText(rel)
			if len(cut) == 0 || len(cut) >= len(good) {
				t.Fatalf("the file was not truncated: %d of %d bytes", len(cut), len(good))
			}
			w.check("rerun", w.install("--harness", "claude"), 0, fromGolden, fromGolden)
			assertEq(t, "the truncated file after a plain run", w.homeText(rel), cut)
			w.check("force", w.install("--harness", "claude", "--force-skill"), 0, fromGolden, fromGolden)
			assertEq(t, "the recovered file", w.homeText(rel), good)
			assertEq(t, "the backup of the truncated bytes", w.homeText(rel+".local-backup"), cut)
		})
	}
}
