//go:build unix

package verify

import (
	"os"
	"path/filepath"
	"testing"
)

// SRC1, SRC2: every harness is compared with the skill source of its own adapter row, not with one shared
// source. The compiled table has a single source today, so the test gives the second harness its own for the
// duration of the test (the shell suite did the same with a fixture adapters.sh).
func TestSkillDriftEachHarnessIsComparedWithItsOwnSource(t *testing.T) {
	saved := append([]skillHarness(nil), skillHarnesses...)
	t.Cleanup(func() { skillHarnesses = saved })
	skillHarnesses = append([]skillHarness(nil), saved...)
	skillHarnesses[1].skillSrcRelkit = "skills/source-b/SKILL.md" // pi

	const srcB = "# research-sdd skill\nsource b\n"
	w := newSDWorld(t)
	if err := os.MkdirAll(filepath.Join(w.kit, "skills", "source-b"), 0o755); err != nil {
		t.Fatal(err)
	}
	w.write("skills/source-b/SKILL.md", srcB)

	// SRC1: each harness carries its own source: in sync
	w.deploy(claudeRel, sdKitSkill)
	w.deploy(piRel, srcB)
	w.wantRun([]string{"--all", "--home", w.home}, "", "", 0)

	// SRC2: pi carries the other harness's source: diverged, and only pi
	w.deploy(piRel, sdKitSkill)
	w.wantRun([]string{"--all", "--home", w.home}, "",
		"verify-skill-drift: fix: research-sdd-install.sh --harness pi --force-skill  # deployed: ~/.pi/agent/skills/research-sdd/SKILL.md\n"+
			"verify-skill-drift: all: checked=3 in-sync=1 diverged=1 absent=1 could-not-run=0\n", 1)
}
