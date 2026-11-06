//go:build unix && !nodiff

package deploy

import (
	"os"
	"testing"
)

// Failure mode "--verify states": match, absent, drift (modified / missing / extra), degraded "no bundle record",
// a corrupt record, and degraded outranking drift in the exit code (0, 0, 1, 2).
func TestVerifyStates(t *testing.T) {
	const claudeRoot, piRoot = ".claude", ".pi/agent"
	rm := func(w *world, rel string) {
		if err := os.Remove(w.hp(rel)); err != nil {
			w.t.Fatal(err)
		}
	}
	cases := []struct {
		name      string
		harness   string
		installed bool
		mutate    func(w *world)
		rc        int
	}{
		{"absent", "claude", false, func(w *world) {}, 0},
		{"match", "claude", true, func(w *world) {}, 0},
		{"drift modified", "claude", true, func(w *world) {
			w.seed(claudeRoot+"/agents/research-sdd-risk.md", "edited\n")
		}, 1},
		{"drift missing", "claude", true, func(w *world) { rm(w, claudeRoot+"/agents/research-sdd-risk.md") }, 1},
		{"drift extra", "pi", true, func(w *world) {
			w.seed(piRoot+"/research-sdd/profile/general/EXTRA.md", "unrecorded\n")
		}, 1},
		// the kit gained an agent definition after the install: the comparison set is the record plus the CURRENT kit agents
		{"drift kit agent not deployed", "claude", true, func(w *world) {
			w.put(join(w.kit, "agents", "claude", "research-sdd-new.md"), []byte("new\n"), 0o644)
			w.kitBefore = w.snapshot(w.kit)
		}, 1},
		{"degraded no bundle record", "claude", true, func(w *world) { rm(w, claudeRoot+"/research-sdd/.installed-bundle-state") }, 2},
		{"degraded corrupt record", "claude", true, func(w *world) {
			w.seed(claudeRoot+"/research-sdd/.installed-bundle-state", "garbage\n")
		}, 2},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			w := newWorld(t)
			if c.installed {
				w.check("install", w.install("--harness", c.harness), 0, fromGolden, "")
			}
			c.mutate(w)
			w.check("verify", w.install("--verify", "--harness", c.harness), c.rc, fromGolden, "")
		})
	}
}

// Degraded outranks drift: claude drifts (exit 1 alone) while pi has files but no record (exit 2 alone); together 2.
func TestVerifyDegradedOutranksDrift(t *testing.T) {
	w := newWorld(t)
	w.check("install", w.install("--harness", "all"), 0, fromGolden, "")
	w.seed(".claude/agents/research-sdd-risk.md", "edited\n")
	if err := os.Remove(w.hp(".pi/agent/research-sdd/.installed-bundle-state")); err != nil {
		t.Fatal(err)
	}
	w.check("verify", w.install("--verify"), 2, fromGolden, "")
}
