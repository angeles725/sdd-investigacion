//go:build unix && !nodiff

package deploy

import (
	"os"
	"strings"
	"testing"
)

const claudeSkill = ".claude/skills/research-sdd/SKILL.md"

// Failure mode "Hand-edited SKILL.md": WARNING, kept, `kept-hand-edit=` recorded, then --verify exit 1.
func TestHandEditedSkillKept(t *testing.T) {
	w := newWorld(t)
	w.check("install", w.install("--harness", "claude"), 0, fromGolden, "")
	w.seed(claudeSkill, "# research-sdd skill\nmy local retro delta\n")
	w.check("reinstall", w.install("--harness", "claude"), 0, fromGolden, fromGolden)
	if got := w.homeText(claudeSkill); got != "# research-sdd skill\nmy local retro delta\n" {
		t.Errorf("the hand-edited skill was not kept: %q", got)
	}
	if !strings.Contains(w.homeText(".claude/research-sdd/.installed-bundle-state"), "kept-hand-edit=skills/research-sdd/SKILL.md") {
		t.Error("the bundle record does not name the kept hand-edit")
	}
	w.check("verify", w.install("--verify", "--harness", "claude"), 1, fromGolden, "")
}

// Failure mode "--force-skill with an existing .local-backup: exit 1" (:580), and the happy forced overwrite.
func TestForceSkill(t *testing.T) {
	w := newWorld(t)
	w.check("install", w.install("--harness", "claude"), 0, fromGolden, "")
	w.seed(claudeSkill, "# research-sdd skill\nmy local retro delta\n")
	w.seed(claudeSkill+".local-backup", "an older backup\n")
	w.check("force blocked by backup", w.install("--harness", "claude", "--force-skill"), 1, fromGolden, fromGolden)
	if got := w.homeText(claudeSkill); got != "# research-sdd skill\nmy local retro delta\n" {
		t.Errorf("a refused --force-skill touched the skill: %q", got)
	}
	if err := os.Remove(w.hp(claudeSkill + ".local-backup")); err != nil {
		t.Fatal(err)
	}
	w.check("force", w.install("--harness", "claude", "--force-skill"), 0, fromGolden, fromGolden)
	assertEq(t, "the backup", w.homeText(claudeSkill+".local-backup"), "# research-sdd skill\nmy local retro delta\n")
}

// Failure mode "the same during a profile switch: exit 1 and launcher unchanged" (:595-600).
func TestProfileSwitchBlockedByHandEdit(t *testing.T) {
	w := newWorld(t)
	w.check("install general", w.install("--harness", "pi"), 0, fromGolden, "")
	w.seed(".pi/agent/skills/research-sdd/SKILL.md", "# research-sdd skill\nmy local retro delta\n")
	launcher := w.homeText(".pi/agent/AGENTS.md")
	w.check("switch to claude", w.install("--harness", "pi", "--profile", "claude"), 1, fromGolden, fromGolden)
	assertEq(t, "launcher after a blocked switch", w.homeText(".pi/agent/AGENTS.md"), launcher)
}

// Legacy defect 4 (install-trio-go.md): an orphan start marker is user content; the installer appends a SECOND block
// and returns success (install.sh refuses with rc 3 for the same input). The Go port refuses instead.
func TestUnbalancedLauncherMarkers(t *testing.T) {
	w := newWorld(t)
	w.seed(".claude/CLAUDE.md", "# mine\n<!-- research-sdd:start -->\nhalf a block, no end marker\n")
	// legacy defect 4: success with a warning and two start markers, not a refusal
	w.check("install", w.install("--harness", "claude"), 0, fromGolden, fromGolden)
	if n := w.blocks(".claude/CLAUDE.md"); n != 2 {
		t.Errorf("%d start markers after the install, want the legacy 2 (orphan kept + fresh block)", n)
	}
}

// Failure mode "Symlinked prompt file: written through, link kept."
func TestSymlinkedPromptFileWrittenThrough(t *testing.T) {
	w := newWorld(t)
	w.seed("dotfiles/CLAUDE.md", "# dotfiles prompt\n")
	w.link(".claude/CLAUDE.md", w.hp("dotfiles/CLAUDE.md"))
	w.check("install", w.install("--harness", "claude"), 0, fromGolden, "")
	if fi, err := os.Lstat(w.hp(".claude/CLAUDE.md")); err != nil || fi.Mode()&os.ModeSymlink == 0 {
		t.Errorf("the prompt-file symlink was severed: %v %v", fi, err)
	}
	if got := w.blocks("dotfiles/CLAUDE.md"); got != 1 {
		t.Errorf("%d launcher blocks reached the link target, want 1", got)
	}
	if !strings.HasPrefix(w.homeText("dotfiles/CLAUDE.md"), "# dotfiles prompt\n\n<!-- research-sdd:start -->") {
		t.Error("the user's own prompt text was not preserved above the block")
	}
}

// Legacy defect 3 (install-trio-go.md): mktemp in $TMPDIR creates the file 0600 and mv keeps it, so a user's 0644
// CLAUDE.md ends up 0600. The Go port keeps the mode.
func TestPromptFileModeFollowsMktemp(t *testing.T) {
	w := newWorld(t)
	w.seed(".claude/CLAUDE.md", "# mine\n")
	w.check("install", w.install("--harness", "claude"), 0, fromGolden, "")
	fi, err := os.Stat(w.hp(".claude/CLAUDE.md"))
	if err != nil {
		t.Fatal(err)
	}
	// legacy defect 3: 0600, not the 0644 the user had
	if fi.Mode().Perm() != 0o600 {
		t.Errorf("CLAUDE.md mode %04o, want the legacy 0600", fi.Mode().Perm())
	}
}

// Legacy defect 1 (install-trio-go.md): the pi extension deploy block is written twice, so the plan names the file
// twice. The golden of the Go port will carry one line.
func TestPiExtensionPlanIsDuplicated(t *testing.T) {
	w := newWorld(t)
	r := w.install("--harness", "pi", "--dry-run")
	w.check("dry-run", r, 0, fromGolden, "")
	line := "INSTALL " + w.hp(".pi/agent/extensions/research-sdd-hooks.ts") + " (pi extension: session hooks)"
	// legacy defect 1: the same plan line twice
	if n := strings.Count(strings.ReplaceAll(r.Out, "<ROOT>", w.root), line); n != 2 {
		t.Errorf("the extension plan line appears %d times, want the legacy 2", n)
	}
}
