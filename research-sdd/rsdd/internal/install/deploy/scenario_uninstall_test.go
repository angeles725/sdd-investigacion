//go:build unix && !nodiff

package deploy

import "testing"

// Failure mode "Uninstall: dry run by default; second run reports absent". Only the installer's own artifacts are
// removed; the user's CLAUDE.md lines outside the block stay.
func TestUninstallDryRunThenApplyThenAbsent(t *testing.T) {
	w := newWorld(t)
	w.seed(".claude/CLAUDE.md", "# mine\n")
	w.check("install", w.install("--harness", "claude"), 0, fromGolden, "")
	installed := w.tree()
	w.check("dry-run", w.install("--uninstall", "--harness", "claude"), 0, fromGolden, "")
	assertEq(t, "tree after the default dry-run", w.tree(), installed)
	w.check("apply", w.install("--uninstall", "--yes", "--harness", "claude"), 0, fromGolden, "")
	if got := w.homeText(".claude/CLAUDE.md"); got != "# mine\n" {
		t.Errorf("the user's own prompt text did not survive the uninstall: %q", got)
	}
	w.check("second run", w.install("--uninstall", "--yes", "--harness", "claude"), 0, fromGolden, "")
}

// Failure mode "kept (modified|unproven|symlink|outside config root)": a hand-edited skill is kept, never removed.
func TestUninstallKeepsHandEditedSkill(t *testing.T) {
	w := newWorld(t)
	w.check("install", w.install("--harness", "claude"), 0, fromGolden, "")
	w.seed(claudeSkill, "# research-sdd skill\nmy local retro delta\n")
	w.check("apply", w.install("--uninstall", "--yes", "--harness", "claude"), 0, fromGolden, "")
	assertEq(t, "the kept skill", w.homeText(claudeSkill), "# research-sdd skill\nmy local retro delta\n")
}

// Failure mode "no python3 -> exit 2 and nothing removed" (:1324): ownership cannot be proven, in dry-run and apply alike.
func TestUninstallWithoutPython(t *testing.T) {
	w := newWorld(t)
	w.check("install", w.install("--harness", "claude"), 0, fromGolden, "")
	installed := w.tree()
	w.dropTool("python3")
	w.check("apply", w.install("--uninstall", "--yes", "--harness", "claude"), 2, fromGolden, fromGolden)
	assertEq(t, "tree after a degraded uninstall", w.tree(), installed)
}
