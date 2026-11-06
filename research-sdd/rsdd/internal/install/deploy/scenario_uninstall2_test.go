//go:build unix && !nodiff

package deploy

import (
	"os"
	"strings"
	"testing"
)

// Failure mode "Uninstall: kept (symlink|outside config root|unproven)". Each state is built on a real install, then
// `--uninstall --yes` must keep the path (the line names the reason) and leave its bytes intact. All link targets
// live inside the scratch home.
func TestUninstallKeptStates(t *testing.T) {
	const agents = ".claude/agents"
	cases := []struct {
		name  string
		build func(w *world)
		line  string // the typed status the uninstall must print
		kept  func(w *world) string
	}{
		{"symlink", func(w *world) {
			// the user's prompt file is a link into their dotfiles: uninstall never writes through it or removes it
			b := w.homeText(".claude/CLAUDE.md")
			if err := os.Remove(w.hp(".claude/CLAUDE.md")); err != nil {
				w.t.Fatal(err)
			}
			w.seed("dotfiles/CLAUDE.md", b)
			w.link(".claude/CLAUDE.md", w.hp("dotfiles/CLAUDE.md"))
		}, "kept (symlink)", func(w *world) string { return w.homeText("dotfiles/CLAUDE.md") }},
		{"outside config root", func(w *world) {
			// the agents dir became a link to a directory outside the config root: files in it are proven but not contained
			if err := os.Rename(w.hp(agents), w.hp("elsewhere-agents")); err != nil {
				w.t.Fatal(err)
			}
			w.link(agents, w.hp("elsewhere-agents"))
		}, "kept (outside config root)", func(w *world) string { return w.homeText("elsewhere-agents/research-sdd-risk.md") }},
		{"unproven", func(w *world) {
			// the skill's marker is gone: nothing vouches for the file any more
			if err := os.Remove(w.hp(".claude/research-sdd/.installed-skill-state")); err != nil {
				w.t.Fatal(err)
			}
		}, "kept (unproven)", func(w *world) string { return w.homeText(claudeSkill) }},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			w := newWorld(t)
			w.check("install", w.install("--harness", "claude"), 0, fromGolden, "")
			c.build(w)
			before := c.kept(w)
			r := w.install("--uninstall", "--yes", "--harness", "claude")
			w.check("apply", r, 0, fromGolden, "")
			if !strings.Contains(r.Out, "  "+c.line+"  ") {
				t.Errorf("no %q line in the uninstall output:\n%s", c.line, r.Out)
			}
			assertEq(t, "the kept path's bytes", c.kept(w), before)
		})
	}
}
