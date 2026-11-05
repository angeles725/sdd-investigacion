//go:build unix

package verify

import (
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

// Profile-aware drift (kit issue #993 WU2) and the pi agent-home override: the parts of verify skill-drift that
// reach beyond the byte comparison.

// installProfile does what the installer does for a non-claude harness: renders the profile into
// <config root>/research-sdd/profile/<profile>, completes it with the links the installer adds, and deploys the
// rendered skill. It returns the render dir.
func (w *sdWorld) installProfile(crel, profile string) string {
	w.t.Helper()
	dir := filepath.Join(w.home, crel, "research-sdd", "profile", profile)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		w.t.Fatal(err)
	}
	cmd := exec.Command("bash", filepath.Join(w.kit, "toolbelt", "render-profile.sh"), profile, dir)
	cmd.Env = w.environ()
	if out, err := cmd.CombinedOutput(); err != nil {
		w.t.Fatalf("render-profile.sh %s: %v: %s", profile, err, out)
	}
	if err := os.Symlink(filepath.Join(w.kit, "toolbelt"), filepath.Join(dir, "toolbelt")); err != nil {
		w.t.Fatal(err)
	}
	w.put(filepath.Join(dir, "TARGETS.md"), "# targets\n", 0o644)
	w.put(filepath.Join(dir, "skills", "README.md"), "# skills\n", 0o644)
	rendered, err := os.ReadFile(filepath.Join(dir, "skills", "research-sdd", "SKILL.md"))
	if err != nil {
		w.t.Fatal(err)
	}
	w.deploy(crel, string(rendered))
	return dir
}

func profileWorld(t *testing.T) *sdWorld {
	w := newSDWorld(t)
	w.withProfiles()
	delete(w.env, "RESEARCH_SDD_PROFILE") // pi defaults to "general"
	return w
}

func TestSkillDriftProfileInSyncAndRenderDirStates(t *testing.T) {
	t.Parallel()
	w := profileWorld(t)
	dir := w.installProfile(piRel, "general")
	w.wantRun([]string{"--harness", "pi"}, "", "", 0)
	w.wantRun([]string{"--all"}, "", "", 0)

	// the persisted render dir lost a link the skill depends on: never "in sync"
	if err := os.Remove(filepath.Join(dir, "toolbelt")); err != nil {
		t.Fatal(err)
	}
	const where = "<ROOT>/home/.pi/agent/research-sdd/profile/general"
	w.wantRun([]string{"--harness", "pi"}, "", "verify-skill-drift: could-not-run harness=pi (render dir incomplete: "+where+")\n", 2)
	w.wantRun([]string{"--all"}, "",
		"verify-skill-drift: could-not-run harness=pi (render dir incomplete: "+where+")\n"+
			"verify-skill-drift: all: checked=3 in-sync=0 diverged=0 absent=2 could-not-run=1\n", 2)

	// a rendered file edited by hand
	if err := os.Symlink(filepath.Join(w.kit, "toolbelt"), filepath.Join(dir, "toolbelt")); err != nil {
		t.Fatal(err)
	}
	w.put(filepath.Join(dir, "PROMPT-LOOP.md"), "hand edited\n", 0o644)
	w.wantRun([]string{"--harness", "pi"}, "", "verify-skill-drift: could-not-run harness=pi (render dir diverged: "+where+")\n", 2)

	// the whole render dir gone
	if err := os.RemoveAll(dir); err != nil {
		t.Fatal(err)
	}
	w.wantRun([]string{"--harness", "pi"}, "", "verify-skill-drift: could-not-run harness=pi (render dir missing: "+where+")\n", 2)
}

func TestSkillDriftProfileDivergedSkillWinsOverTheRenderDirCheck(t *testing.T) {
	t.Parallel()
	w := profileWorld(t)
	dir := w.installProfile(piRel, "general")
	w.deploy(piRel, "hand edited\n")
	if err := os.RemoveAll(dir); err != nil {
		t.Fatal(err)
	}
	// the skill itself differs, so that is the finding; the render dir is not looked at
	w.wantRun([]string{"--harness", "pi"}, "", "verify-skill-drift: diverged harness=pi deployed=<ROOT>/home/.pi/agent/skills/research-sdd/SKILL.md\n", 1)
}

func TestSkillDriftProfileSelection(t *testing.T) {
	t.Parallel()
	w := profileWorld(t)
	w.installProfile(piRel, "general")
	live, err := os.ReadFile(filepath.Join(w.kit, "skills", "research-sdd", "SKILL.md"))
	if err != nil {
		t.Fatal(err)
	}
	// --profile claude compares against the kit source itself, byte for byte: the rendered skill differs from it
	w.wantRun([]string{"--harness", "pi", "--profile", "claude"}, "", "verify-skill-drift: diverged harness=pi deployed=<ROOT>/home/.pi/agent/skills/research-sdd/SKILL.md\n", 1)
	w.deploy(piRel, string(live))
	w.wantRun([]string{"--harness", "pi", "--profile", "claude"}, "", "", 0)

	// precedence: flag > $RESEARCH_SDD_PROFILE > the harness default
	w.env["RESEARCH_SDD_PROFILE"] = "claude"
	w.wantRun([]string{"--harness", "pi"}, "", "", 0)
	w.wantRun([]string{"--harness", "pi", "--profile", "general"}, "", "verify-skill-drift: diverged harness=pi deployed=<ROOT>/home/.pi/agent/skills/research-sdd/SKILL.md\n", 1)
	// a colon cuts the pair "<profile>:<source>" at its first colon
	w.wantRun([]string{"--harness", "pi", "--profile", "claude:whatever"}, "", "", 0)
}

func TestSkillDriftUnknownProfile(t *testing.T) {
	t.Parallel()
	w := profileWorld(t)
	w.deploy(claudeRel, sdKitSkill)
	for _, p := range []string{"bogus", "../profiles/general", "Gen", "general/"} {
		w.wantRun([]string{"--profile", p}, "", "verify-skill-drift: ERROR: unknown profile for harness \"claude\"\n", 2)
	}
	w.wantRun([]string{"--all", "--profile", "bogus"}, "",
		"verify-skill-drift: could-not-run harness=claude (unknown profile)\n"+
			"verify-skill-drift: all: checked=3 in-sync=0 diverged=0 absent=2 could-not-run=1\n", 2)
}

func TestSkillDriftRenderFailureIsCouldNotRunAndLeavesNoTempDir(t *testing.T) {
	t.Parallel()
	w := profileWorld(t)
	w.deploy(piRel, "whatever\n")
	w.put(filepath.Join(w.kit, "toolbelt", "render-profile.sh"), "#!/usr/bin/env bash\necho boom >&2\nexit 5\n", 0o755)
	const failed = "verify-skill-drift: render-profile.sh failed for profile \"general\": boom\n"
	w.wantRun([]string{"--harness", "pi"}, "", failed+"verify-skill-drift: ERROR: could not render profile for harness \"pi\"\n", 2)
	w.wantRun([]string{"--all"}, "",
		failed+"verify-skill-drift: could-not-run harness=pi (profile render failed)\n"+
			"verify-skill-drift: all: checked=3 in-sync=0 diverged=0 absent=2 could-not-run=1\n", 2)
	if left, _ := os.ReadDir(w.env["TMPDIR"]); len(left) != 0 {
		t.Errorf("throwaway render dirs left behind in TMPDIR: %v", left)
	}
}

func TestSkillDriftNoTempDirIsLeftBehindOnAnyPath(t *testing.T) {
	t.Parallel()
	w := profileWorld(t)
	w.installProfile(piRel, "general")
	w.installProfile(gentleRel, "general")
	w.wantRun([]string{"--all"}, "", "", 0)
	w.deploy(piRel, "stale\n")
	w.wantRun([]string{"--all"}, "", "verify-skill-drift: fix: research-sdd-install.sh --harness pi --force-skill  # deployed: ~/.pi/agent/skills/research-sdd/SKILL.md\n"+
		"verify-skill-drift: all: checked=3 in-sync=1 diverged=1 absent=1 could-not-run=0\n", 1)
	if left, _ := os.ReadDir(w.env["TMPDIR"]); len(left) != 0 {
		t.Errorf("throwaway render dirs left behind in TMPDIR: %v", left)
	}
}

func TestSkillDriftPiAgentHomeOverride(t *testing.T) {
	t.Parallel()
	w := newSDWorld(t)
	custom := filepath.Join(w.root, "pi-agent")
	w.put(filepath.Join(custom, "skills", "research-sdd", "SKILL.md"), sdKitSkill, 0o644)

	// the override applies when --home is the invoking user's own $HOME (the default)
	w.env["GENTLE_PI_AGENT_HOME"] = custom + "//"
	w.wantRun([]string{"--harness", "pi"}, "", "", 0)
	// ... GENTLE_PI_AGENT_HOME before PI_CODING_AGENT_DIR
	w.env["PI_CODING_AGENT_DIR"] = filepath.Join(w.root, "other")
	w.wantRun([]string{"--harness", "pi"}, "", "", 0)
	delete(w.env, "GENTLE_PI_AGENT_HOME")
	w.wantRun([]string{"--harness", "pi"}, "", "verify-skill-drift: absent harness=pi deployed=<ROOT>/other/skills/research-sdd/SKILL.md\n"+dispatcherDegraded, 3)
	// an explicit --home redirects the whole config root and wins over the override
	w.wantRun([]string{"--harness", "pi", "--home", filepath.Join(w.root, "elsewhere")}, "", "verify-skill-drift: absent harness=pi deployed=<ROOT>/elsewhere/.pi/agent/skills/research-sdd/SKILL.md\n"+dispatcherDegraded, 3)
	// gentle-shell keeps its isolated agent home
	w.wantRun([]string{"--harness", "gentle-shell"}, "", "verify-skill-drift: absent harness=gentle-shell deployed=<ROOT>/home/.gentle-shell/agent/skills/research-sdd/SKILL.md\n"+dispatcherDegraded, 3)
}

func TestSkillDriftPiOverrideThatIsNotAbsoluteFailsEveryField(t *testing.T) {
	t.Parallel()
	w := newSDWorld(t)
	w.deploy(claudeRel, sdKitSkill)
	for _, bad := range []string{"relative/dir", "/", "//", "."} {
		w.env["GENTLE_PI_AGENT_HOME"] = bad
		// single mode: config_root fails, so the harness reads as unknown (the message is silenced)
		w.wantRun([]string{"--harness", "pi"}, "", "verify-skill-drift: ERROR: unknown harness \"pi\"\n", 2)
		// --all: the field lookups fail loudly (twice) and pi then counts as absent; claude is unaffected
		msg := "rsdd_field: GENTLE_PI_AGENT_HOME must be an absolute path other than / (got '" + bad + "')\n"
		w.wantRun([]string{"--all"}, "", msg+msg+"", 0)
	}
}
