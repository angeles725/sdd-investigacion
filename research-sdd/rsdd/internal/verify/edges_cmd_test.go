package verify

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// Command-level edges that the first teeth run of this package left alive (kit issue #2592). The skill-drift
// cases write and exec stubs through testkit/execfile (sdWorld.put), so they run in parallel without ETXTBSY.

// With no --kit the registry resolves the kit from RESEARCH_SDD_KIT, the way the portable hook does, and reports
// exactly what an explicit --kit reports.
func TestRegistryResolvesTheKitWithoutTheFlag(t *testing.T) {
	t.Parallel()
	k := newVRKit(t)
	k.blocks("alpha", 3)
	k.targets(vrTable(vrRow("1", "alpha", "alpha", "(3 blocks)")))
	k.write("home/kit/toolbelt/verify-registry.sh", "#!/usr/bin/env bash\n")
	explicit := k.run(nil)
	e := k.env(map[string]string{"RESEARCH_SDD_KIT": k.kit})
	var out, errb bytes.Buffer
	s := cli.Stdio{In: strings.NewReader(""), Out: &out, Err: &errb, Env: func(key string) string { return e[key] },
		Clock: func() time.Time { return time.Unix(0, 0) }, Cwd: k.root}
	rc := RunRegistry(nil, s)
	if got := (vrResult{out.String(), errb.String(), rc}); got != explicit {
		t.Errorf("resolved from RESEARCH_SDD_KIT:\n got %+v\nwant %+v (the --kit run)", got, explicit)
	}
	if explicit.rc != 0 {
		t.Errorf("the --kit run itself failed: %+v", explicit)
	}
}

// A trailing --kit with no value is ignored by the hook (the script ignored it), never read past the arguments.
func TestRegistryHookTrailingKitFlagIsIgnored(t *testing.T) {
	t.Parallel()
	k := newVRKit(t)
	k.blocks("alpha", 3)
	k.targets(vrTable(vrRow("1", "alpha", "alpha", "(3 blocks)")))
	k.write("home/kit/toolbelt/verify-registry.sh", "#!/usr/bin/env bash\n")
	plain, _, _ := k.runHook(nil)
	e := k.env(map[string]string{"RESEARCH_SDD_KIT": k.kit})
	var out, errb bytes.Buffer
	s := cli.Stdio{In: strings.NewReader(""), Out: &out, Err: &errb, Env: func(key string) string { return e[key] },
		Clock: func() time.Time { return time.Unix(0, 0) }, Cwd: k.root}
	if rc := RunRegistryHook([]string{"--full", "--kit"}, s); rc != 0 {
		t.Errorf("rc = %d, want 0", rc)
	}
	full, fullRaw, _ := k.runHook(nil, "--full")
	if !strings.Contains(full, "Research-SDD") {
		t.Fatalf("no registry context in the explicit run: %q", fullRaw)
	}
	if out.String() != fullRaw {
		t.Errorf("a trailing --kit changed the report:\n got %q\nwant %q", out.String(), fullRaw)
	}
	if plain == full {
		t.Error("--full made no difference here; the case would not show that --full was still honoured")
	}
}

// With no arguments skill-drift resolves the kit from RESEARCH_SDD_KIT and checks the default harness.
func TestSkillDriftWithNoArguments(t *testing.T) {
	t.Parallel()
	w := newSDWorld(t)
	w.deploy(claudeRel, sdKitSkill)
	w.put(filepath.Join(w.kit, "toolbelt", "verify-skill-drift.sh"), "#!/usr/bin/env bash\n", 0o644)
	w.env["RESEARCH_SDD_KIT"] = w.kit
	var out, errb bytes.Buffer
	rc := RunSkillDrift(nil, w.stdio(&out, &errb))
	wantOut, wantErr, wantRC := w.runGo()
	if wantRC != 0 {
		t.Fatalf("the --kit run itself is not in sync: rc=%d err=%q", wantRC, wantErr)
	}
	if out.String() != wantOut || errb.String() != wantErr || rc != wantRC {
		t.Errorf("no arguments: rc=%d out=%q err=%q; the --kit run: rc=%d out=%q err=%q", rc, out.String(), errb.String(), wantRC, wantOut, wantErr)
	}
}

// The shortest absolute override ("/p", two characters) is accepted.
func TestSkillDriftPiOverrideOfTwoCharacters(t *testing.T) {
	t.Parallel()
	w := newSDWorld(t)
	for _, v := range []string{"/p", "/p/", "/p//"} {
		w.env["GENTLE_PI_AGENT_HOME"] = v
		w.wantRun([]string{"--harness", "pi"}, "", "verify-skill-drift: absent harness=pi deployed=/p/skills/research-sdd/SKILL.md\n"+dispatcherDegraded, 3)
	}
}

// The throwaway render lives under $TMPDIR; an unusable $TMPDIR is a could-not-run, never a silent /tmp.
func TestSkillDriftRenderHonoursTMPDIR(t *testing.T) {
	t.Parallel()
	w := profileWorld(t)
	w.installProfile(piRel, "general")
	w.env["TMPDIR"] = filepath.Join(w.root, "no-such-dir")
	w.wantRun([]string{"--harness", "pi"}, "", "verify-skill-drift: cannot create a throwaway render dir: stat <ROOT>/no-such-dir: no such file or directory\n"+
		"verify-skill-drift: ERROR: could not render profile for harness \"pi\"\n", 2)
}

// A single-harness check leaves no render directory behind (the --all path is covered elsewhere).
func TestSkillDriftSingleHarnessLeavesNoTempDir(t *testing.T) {
	t.Parallel()
	w := profileWorld(t)
	w.installProfile(piRel, "general")
	w.wantRun([]string{"--harness", "pi"}, "", "", 0)
	tmp := w.env["TMPDIR"]
	if tmp == "" {
		t.Fatal("the world sets no TMPDIR; the leak check would look nowhere")
	}
	left, err := os.ReadDir(tmp)
	if err != nil {
		t.Fatalf("cannot list TMPDIR, so the leak check proves nothing: %v", err)
	}
	if len(left) != 0 {
		t.Errorf("throwaway render dirs left behind in TMPDIR: %v", left)
	}
}

// The kit is a subdirectory of its checkout (research-sdd/ under the repo root): that is the kit's own
// repository, so staleness is measured, not reported as an unrelated repo.
func TestSkillDriftHookKitInASubdirectoryOfItsCheckout(t *testing.T) {
	t.Parallel()
	w := hookWorld(t)
	repo := w.gitKit(3)
	sub := filepath.Join(repo, "research-sdd")
	if err := os.Mkdir(sub, 0o755); err != nil {
		t.Fatal(err)
	}
	w.env["RESEARCH_SDD_KIT_DIR"] = sub
	w.env["RESEARCH_SDD_KIT_STALE_MAX_COMMITS"] = "2"
	ctx := w.hookContext()
	if !strings.Contains(ctx, "verify kit-stale status=stale") || strings.Contains(ctx, "unrelated repo") {
		t.Errorf("hook context %q", ctx)
	}
}
