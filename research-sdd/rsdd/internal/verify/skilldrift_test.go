//go:build unix

package verify

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Behaviour of `rsdd verify skill-drift` pinned on its own, without bash: exit codes, the exact stderr lines,
// the typed absent/could-not-run/diverged states and the argument contract. The differential test
// (skilldrift_diff_test.go) pins the same behaviour against the frozen script.

const (
	claudeRel = ".claude"
	piRel     = ".pi/agent"
	gentleRel = ".gentle-shell/agent"

	// dispatcherDegraded is what cli.Run adds after any command that ends on exit 3 without a DEGRADED: line.
	dispatcherDegraded = "DEGRADED: command reported a degraded state without a reason\n"
)

func (w *sdWorld) skillPath(crel string) string {
	return filepath.Join(w.home, crel, "skills", "research-sdd", "SKILL.md")
}

func (w *sdWorld) wantRun(args []string, wantOut, wantErr string, wantRC int) {
	w.t.Helper()
	out, errs, rc := w.runGo(args...)
	if got := w.scrub(errs); out != wantOut || got != wantErr || rc != wantRC {
		w.t.Errorf("verify skill-drift %v\ngot rc=%d\nstdout: %q\nstderr: %q\nwant rc=%d\nstdout: %q\nstderr: %q", args, rc, out, got, wantRC, wantOut, wantErr)
	}
}

func TestSkillDriftSingleHarnessStates(t *testing.T) {
	w := newSDWorld(t)
	w.deploy(claudeRel, sdKitSkill)
	w.wantRun(nil, "", "", 0) // in sync: silent

	w.deploy(claudeRel, "hand edited\n")
	w.wantRun(nil, "", "verify-skill-drift: diverged harness=claude deployed=<ROOT>/home/.claude/skills/research-sdd/SKILL.md\n", 1)

	// exit 3 is the dispatcher's "degraded" code: it appends its own typed line after the script's one (declared)
	w.wantRun([]string{"--harness", "pi"}, "", "verify-skill-drift: absent harness=pi deployed=<ROOT>/home/.pi/agent/skills/research-sdd/SKILL.md\n"+dispatcherDegraded, 3)
	w.wantRun([]string{"--harness", "nope"}, "", "verify-skill-drift: ERROR: unknown harness \"nope\"\n", 2)
}

func TestSkillDriftSingleHarnessCouldNotRun(t *testing.T) {
	w := newSDWorld(t)
	dep := w.skillPath(claudeRel)
	if err := os.MkdirAll(filepath.Dir(dep), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(w.root, "nowhere"), dep); err != nil {
		t.Fatal(err)
	}
	w.wantRun(nil, "", "verify-skill-drift: could-not-run harness=claude (dangling symlink: <ROOT>/home/.claude/skills/research-sdd/SKILL.md)\n", 2)

	if err := os.Remove(dep); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(dep, 0o755); err != nil {
		t.Fatal(err)
	}
	w.wantRun(nil, "", "verify-skill-drift: ERROR: deployed path exists but is not a regular file: <ROOT>/home/.claude/skills/research-sdd/SKILL.md\n", 2)

	if err := os.Remove(dep); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(filepath.Join(w.kit, "skills", "research-sdd", "SKILL.md")); err != nil {
		t.Fatal(err)
	}
	w.wantRun(nil, "", "verify-skill-drift: ERROR: kit source not found: <ROOT>/kit/skills/research-sdd/SKILL.md\n", 2)
}

func TestSkillDriftKitInstallMissing(t *testing.T) {
	w := newSDWorld(t)
	if err := os.Remove(filepath.Join(w.kit, "install", "adapters.sh")); err != nil {
		t.Fatal(err)
	}
	w.wantRun(nil, "", "verify-skill-drift: ERROR: adapters.sh not found: <ROOT>/kit/install/adapters.sh\n", 2)
	if err := os.RemoveAll(filepath.Join(w.kit, "install")); err != nil {
		t.Fatal(err)
	}
	w.wantRun(nil, "", "verify-skill-drift: ERROR: install dir not found\n", 2)
}

func TestSkillDriftArgumentContract(t *testing.T) {
	w := newSDWorld(t)
	for _, c := range []struct {
		args []string
		err  string
	}{
		{[]string{"--harness"}, "verify-skill-drift: --harness requires a non-empty value\n"},
		{[]string{"--harness", ""}, "verify-skill-drift: --harness requires a non-empty value\n"},
		{[]string{"--home"}, "verify-skill-drift: --home requires a non-empty value\n"},
		{[]string{"--profile", ""}, "verify-skill-drift: --profile requires a non-empty value\n"},
		{[]string{"--bogus"}, "verify-skill-drift: unknown argument: --bogus\n"},
		{[]string{"claude"}, "verify-skill-drift: unknown argument: claude\n"},
		{[]string{"--all", "--harness", "pi"}, "verify-skill-drift: --all and --harness are mutually exclusive\n"},
		{[]string{"--harness", "pi", "--all"}, "verify-skill-drift: --all and --harness are mutually exclusive\n"},
		{[]string{"--bogus", "--help"}, "verify-skill-drift: unknown argument: --bogus\n"},
	} {
		w.wantRun(c.args, "", c.err, 2)
	}
}

func TestSkillDriftHelpIsTheScriptHeader(t *testing.T) {
	w := newSDWorld(t)
	for _, flag := range []string{"-h", "--help"} {
		out, errs, rc := w.runGo(flag)
		if rc != 0 || errs != "" {
			t.Fatalf("%s: rc=%d stderr=%q", flag, rc, errs)
		}
		if !strings.HasPrefix(out, "\nUsage: verify-skill-drift.sh [--all | --harness <h>] [--home <dir>] [--profile <name>]\n") {
			t.Errorf("%s: help does not start with the usage line:\n%s", flag, out)
		}
		if !strings.HasSuffix(out, "  3  absent       no deployed skill found (harness not installed / never run)\n\n") {
			t.Errorf("%s: help does not end with the exit-code table:\n%s", flag, out)
		}
	}
	// help needs no HOME and exits before any later validation
	w.env["HOME"] = ""
	if _, _, rc := w.runGo("--help", "--all", "--harness", "pi"); rc != 0 {
		t.Errorf("--help with HOME unset and conflicting flags after it: rc=%d, want 0", rc)
	}
}

func TestSkillDriftHomeResolution(t *testing.T) {
	w := newSDWorld(t)
	w.deploy(claudeRel, sdKitSkill)
	const noHome = "verify-skill-drift: could-not-run: HOME is unset or empty and no --home given\n"
	w.env["HOME"] = ""
	w.wantRun(nil, "", noHome, 2)
	w.wantRun([]string{"--all"}, "", noHome, 2)
	w.wantRun([]string{"--home", filepath.Join(w.root, "home")}, "", "", 0) // --home wins over a missing HOME
}

func TestSkillDriftAllMode(t *testing.T) {
	w := newSDWorld(t)
	w.wantRun([]string{"--all"}, "", "", 0) // every harness absent is normal and silent

	w.deploy(claudeRel, sdKitSkill)
	w.wantRun([]string{"--all"}, "", "", 0)

	w.deploy(piRel, "stale\n")
	w.wantRun([]string{"--all"}, "",
		"verify-skill-drift: fix: research-sdd-install.sh --harness pi --force-skill  # deployed: ~/.pi/agent/skills/research-sdd/SKILL.md\n"+
			"verify-skill-drift: all: checked=3 in-sync=1 diverged=1 absent=1 could-not-run=0\n", 1)

	// every harness diverged: one detailed fix line (the output budget), the rest named
	w.deploy(claudeRel, "stale\n")
	w.deploy(gentleRel, "stale\n")
	w.wantRun([]string{"--all"}, "",
		"verify-skill-drift: fix: research-sdd-install.sh --harness claude --force-skill  # deployed: ~/.claude/skills/research-sdd/SKILL.md\n"+
			"verify-skill-drift: also diverged: pi, gentle-shell (same fix with --harness <name>)\n"+
			"verify-skill-drift: all: checked=3 in-sync=0 diverged=3 absent=0 could-not-run=0\n", 1)
}

func TestSkillDriftAllModeCouldNotRunOutranksNothingButDivergedOutranksIt(t *testing.T) {
	w := newSDWorld(t)
	w.deploy(claudeRel, sdKitSkill)
	dep := w.skillPath(piRel)
	if err := os.MkdirAll(filepath.Dir(dep), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(w.root, "nowhere"), dep); err != nil {
		t.Fatal(err)
	}
	w.wantRun([]string{"--all"}, "",
		"verify-skill-drift: could-not-run harness=pi (dangling symlink: <ROOT>/home/.pi/agent/skills/research-sdd/SKILL.md)\n"+
			"verify-skill-drift: all: checked=3 in-sync=1 diverged=0 absent=1 could-not-run=1\n", 2)

	w.deploy(gentleRel, "stale\n") // a diverged harness wins the exit code
	w.wantRun([]string{"--all"}, "",
		"verify-skill-drift: could-not-run harness=pi (dangling symlink: <ROOT>/home/.pi/agent/skills/research-sdd/SKILL.md)\n"+
			"verify-skill-drift: fix: research-sdd-install.sh --harness gentle-shell --force-skill  # deployed: ~/.gentle-shell/agent/skills/research-sdd/SKILL.md\n"+
			"verify-skill-drift: all: checked=3 in-sync=1 diverged=1 absent=0 could-not-run=1\n", 1)
}

func TestSkillDriftAllModeKitSourceMissing(t *testing.T) {
	w := newSDWorld(t)
	w.deploy(claudeRel, sdKitSkill)
	if err := os.Remove(filepath.Join(w.kit, "skills", "research-sdd", "SKILL.md")); err != nil {
		t.Fatal(err)
	}
	w.wantRun([]string{"--all"}, "",
		"verify-skill-drift: could-not-run harness=claude (src missing: <ROOT>/kit/skills/research-sdd/SKILL.md)\n"+
			"verify-skill-drift: all: checked=3 in-sync=0 diverged=0 absent=2 could-not-run=1\n", 2)
}

func TestSkillDriftAllModeUnreadableDeployed(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root reads a mode-000 file")
	}
	w := newSDWorld(t)
	dep := w.deploy(claudeRel, sdKitSkill)
	if err := os.Chmod(dep, 0); err != nil {
		t.Fatal(err)
	}
	w.wantRun([]string{"--all"}, "",
		"verify-skill-drift: could-not-run harness=claude (deployed not a readable file: <ROOT>/home/.claude/skills/research-sdd/SKILL.md)\n"+
			"verify-skill-drift: all: checked=3 in-sync=0 diverged=0 absent=2 could-not-run=1\n", 2)
	w.wantRun(nil, "", "verify-skill-drift: ERROR: deployed skill not readable: <ROOT>/home/.claude/skills/research-sdd/SKILL.md\n", 2)
}
