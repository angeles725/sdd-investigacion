//go:build unix && !nodiff

package deploy

import "testing"

// Failure mode "Re-run": fresh install per harness, dry-run then real then --verify. Dry-run touches nothing
// (the tree golden is empty); the real run writes the bundle record; --verify reports match.
func TestFreshInstallPerHarness(t *testing.T) {
	for _, h := range harnesses {
		t.Run(h, func(t *testing.T) {
			w := newWorld(t)
			dry := w.install("--harness", h, "--dry-run")
			w.check("dry-run", dry, 0, fromGolden, "")
			if got := w.snapshot(w.home); got != "" {
				t.Errorf("--dry-run wrote below the home:\n%s", got)
			}
			real := w.install("--harness", h)
			w.check("install", real, 0, fromGolden, "")
			ver := w.install("--verify", "--harness", h)
			w.check("verify", ver, 0, fromGolden, "")
		})
	}
}

// Failure mode "Re-run: same bytes, same bundle_sha256, exactly one block": a second install changes nothing.
func TestRerunIsIdempotent(t *testing.T) {
	w := newWorld(t)
	first := w.install()
	w.check("first", first, 0, fromGolden, "")
	treeFirst := w.tree()
	record := w.homeText(".claude/research-sdd/.installed-bundle-state")
	second := w.install()
	w.check("second", second, 0, fromGolden, "")
	assertEq(t, "tree after the second run", w.tree(), treeFirst)
	assertEq(t, "bundle record after the second run", w.homeText(".claude/research-sdd/.installed-bundle-state"), record)
	assertEq(t, "stdout of the second run", second.Out, first.Out)
	for _, h := range harnesses {
		if n := w.blocks(harnessRoot[h] + promptFile(h)); n != 1 {
			t.Errorf("%s: %d launcher blocks after two installs, want 1", h, n)
		}
	}
}

// promptFile is the system-prompt file name of a harness (adapters.sh _RSDD_PROMPT_FILE_NAME), with its slash.
func promptFile(h string) string {
	if h == "claude" {
		return "/CLAUDE.md"
	}
	return "/AGENTS.md"
}
