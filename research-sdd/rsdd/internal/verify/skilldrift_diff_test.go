//go:build unix

package verify

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// The differential: the Go command and the frozen verify-skill-drift.sh (testdata/legacy/skilldrift, run beside
// the frozen adapters.sh in a mini kit) answer the same world, and must agree on exit code, stdout and stderr.
// The one declared difference on this path is exit 3: the dispatcher appends its own typed line.

type sdScenario struct {
	name  string
	setup func(w *sdWorld)
	args  [][]string
}

// sdSingle and sdAll are the argument sets most scenarios run.
var (
	sdNone   = [][]string{nil}
	sdSingle = [][]string{nil, {"--harness", "claude"}, {"--harness", "pi"}, {"--harness", "gentle-shell"}}
	sdAll    = [][]string{{"--all"}}
	sdBoth   = append(append([][]string{}, sdSingle...), sdAll...)
)

func (w *sdWorld) deployAll(text string) {
	for _, c := range []string{claudeRel, piRel, gentleRel} {
		w.deploy(c, text)
	}
}

func (w *sdWorld) dangling(crel string) {
	dep := w.skillPath(crel)
	if err := os.MkdirAll(filepath.Dir(dep), 0o755); err != nil {
		w.t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(w.root, "nowhere"), dep); err != nil {
		w.t.Fatal(err)
	}
}

func sdScenarios(t *testing.T) []sdScenario {
	unreadable := func(w *sdWorld) {
		dep := w.deploy(claudeRel, sdKitSkill)
		if err := os.Chmod(dep, 0); err != nil {
			t.Fatal(err)
		}
	}
	profiled := func(w *sdWorld) { w.withProfiles(); delete(w.env, "RESEARCH_SDD_PROFILE") }
	return []sdScenario{
		{"nothing deployed", func(w *sdWorld) {}, sdBoth},
		{"every harness in sync", func(w *sdWorld) { w.deployAll(sdKitSkill) }, sdBoth},
		{"every harness diverged", func(w *sdWorld) { w.deployAll("stale\n") }, sdBoth},
		{"pi diverged only", func(w *sdWorld) { w.deploy(claudeRel, sdKitSkill); w.deploy(piRel, "x\n") }, sdBoth},
		{"last harness diverged", func(w *sdWorld) { w.deploy(gentleRel, "x\n") }, sdBoth},
		{"trailing newline is a byte", func(w *sdWorld) { w.deploy(claudeRel, strings.TrimSuffix(sdKitSkill, "\n")) }, sdBoth},
		{"empty deployed file", func(w *sdWorld) { w.deploy(claudeRel, "") }, sdBoth},
		{"dangling symlink", func(w *sdWorld) { w.dangling(claudeRel); w.dangling(gentleRel) }, sdBoth},
		{"dangling next to a diverged one", func(w *sdWorld) { w.dangling(piRel); w.deploy(claudeRel, "x\n") }, sdAll},
		{"deployed is a directory", func(w *sdWorld) {
			if err := os.MkdirAll(w.skillPath(claudeRel), 0o755); err != nil {
				t.Fatal(err)
			}
		}, sdBoth},
		{"deployed is a symlink to the source", func(w *sdWorld) {
			dep := w.skillPath(claudeRel)
			if err := os.MkdirAll(filepath.Dir(dep), 0o755); err != nil {
				t.Fatal(err)
			}
			if err := os.Symlink(filepath.Join(w.kit, "skills", "research-sdd", "SKILL.md"), dep); err != nil {
				t.Fatal(err)
			}
		}, sdBoth},
		{"unreadable deployed", unreadable, sdBoth},
		{"kit source missing", func(w *sdWorld) {
			w.deployAll(sdKitSkill)
			os.Remove(filepath.Join(w.kit, "skills", "research-sdd", "SKILL.md")) //nolint:errcheck
		}, sdBoth},
		{"kit source is a directory", func(w *sdWorld) {
			w.deployAll(sdKitSkill)
			p := filepath.Join(w.kit, "skills", "research-sdd", "SKILL.md")
			os.Remove(p)       //nolint:errcheck
			os.Mkdir(p, 0o755) //nolint:errcheck
		}, sdBoth},
		{"adapters.sh missing", func(w *sdWorld) { os.Remove(filepath.Join(w.kit, "install", "adapters.sh")) }, sdBoth},
		{"install dir missing", func(w *sdWorld) { os.RemoveAll(filepath.Join(w.kit, "install")) }, sdBoth},
		{"HOME unset", func(w *sdWorld) { delete(w.env, "HOME") }, sdBoth},
		{"HOME empty", func(w *sdWorld) { w.env["HOME"] = "" }, sdBoth},
		{"--home with HOME unset", func(w *sdWorld) {
			delete(w.env, "HOME")
			w.deploy(claudeRel, "x\n")
		}, [][]string{{"--home", "@home"}, {"--all", "--home", "@home"}}},
		{"--home elsewhere", func(w *sdWorld) {}, [][]string{{"--home", "@root/other"}, {"--all", "--home", "@root/other"}}},
		{"pi override", func(w *sdWorld) {
			w.env["GENTLE_PI_AGENT_HOME"] = filepath.Join(w.root, "pi-home") + "/"
			w.put(filepath.Join(w.root, "pi-home", "skills", "research-sdd", "SKILL.md"), sdKitSkill, 0o644)
		}, [][]string{{"--harness", "pi"}, {"--all"}, {"--harness", "pi", "--home", "@home"}, {"--harness", "pi", "--home", "@root/x"}}},
		{"PI_CODING_AGENT_DIR override", func(w *sdWorld) {
			w.env["PI_CODING_AGENT_DIR"] = filepath.Join(w.root, "pi-dir")
			w.put(filepath.Join(w.root, "pi-dir", "skills", "research-sdd", "SKILL.md"), "x\n", 0o644)
		}, [][]string{{"--harness", "pi"}, {"--all"}}},
		{"both overrides, GENTLE first", func(w *sdWorld) {
			w.env["GENTLE_PI_AGENT_HOME"] = filepath.Join(w.root, "g")
			w.env["PI_CODING_AGENT_DIR"] = filepath.Join(w.root, "p")
			w.put(filepath.Join(w.root, "p", "skills", "research-sdd", "SKILL.md"), sdKitSkill, 0o644)
		}, [][]string{{"--harness", "pi"}, {"--all"}}},
		{"bad override", func(w *sdWorld) {
			w.env["GENTLE_PI_AGENT_HOME"] = "relative"
			w.deploy(claudeRel, "x\n")
		}, [][]string{{"--harness", "pi"}, {"--harness", "pi", "--home", "@root/x"}, {"--all"}, {"--harness", "claude"}}},
		{"root override", func(w *sdWorld) { w.env["PI_CODING_AGENT_DIR"] = "///" }, [][]string{{"--harness", "pi"}, {"--all"}}},
		{"profile general in sync", func(w *sdWorld) {
			profiled(w)
			w.installProfile(piRel, "general")
			w.installProfile(gentleRel, "general")
		},
			append(append([][]string{}, sdBoth...), []string{"--all", "--profile", "claude"}, []string{"--harness", "pi", "--profile", "general"})},
		{"profile general diverged", func(w *sdWorld) { profiled(w); w.installProfile(piRel, "general"); w.deploy(piRel, "x\n") }, sdBoth},
		{"profile render dir incomplete", func(w *sdWorld) {
			profiled(w)
			os.Remove(filepath.Join(w.installProfile(piRel, "general"), "toolbelt")) //nolint:errcheck
		}, sdBoth},
		{"profile render dir diverged", func(w *sdWorld) {
			profiled(w)
			w.put(filepath.Join(w.installProfile(piRel, "general"), "METHODOLOGY.md"), "x\n", 0o644)
		}, sdBoth},
		{"profile render dir missing", func(w *sdWorld) { profiled(w); os.RemoveAll(filepath.Dir(w.installProfile(piRel, "general"))) }, sdBoth},
		{"profile render fails", func(w *sdWorld) {
			profiled(w)
			w.deploy(piRel, "x\n")
			w.put(filepath.Join(w.kit, "toolbelt", "render-profile.sh"), "#!/usr/bin/env bash\necho \"boom $2\" >&2\nexit 5\n", 0o755)
		}, sdBoth},
		{"unknown and unsafe profiles", func(w *sdWorld) { profiled(w); w.deployAll(sdKitSkill) },
			[][]string{{"--profile", "nope"}, {"--profile", "../profiles/general"}, {"--profile", "Gen"}, {"--profile", "general:x"}, {"--all", "--profile", "nope"}, {"--harness", "pi", "--profile", "claude"}}},
		{"profile from the environment", func(w *sdWorld) { profiled(w); w.env["RESEARCH_SDD_PROFILE"] = "nope"; w.deployAll(sdKitSkill) },
			[][]string{nil, {"--all"}, {"--profile", "claude"}}},
		{"profile file for the default is missing", func(w *sdWorld) {
			profiled(w)
			os.Remove(filepath.Join(w.kit, "profiles", "general.slots.md")) //nolint:errcheck
			w.deployAll(sdKitSkill)
		}, sdBoth},
		{"argument contract", func(w *sdWorld) { w.deploy(claudeRel, "x\n") }, [][]string{
			{"--harness"}, {"--harness", ""}, {"--home"}, {"--home", ""}, {"--profile"}, {"--profile", ""}, {"--bogus"}, {"claude"}, {""},
			{"--all", "--harness", "pi"}, {"--harness", "pi", "--all"}, {"--bogus", "--help"}, {"--help", "--bogus"}, {"--harness", "--help"},
			{"-h"}, {"--help"}, {"--all", "--all"}, {"--harness", "pi", "--harness", "claude"}, {"--help", "--all", "--harness", "x"},
		}},
	}
}

func (w *sdWorld) expand(args []string) []string {
	out := make([]string, len(args))
	for i, a := range args {
		a = strings.Replace(a, "@home", w.home, 1)
		out[i] = strings.Replace(a, "@root", w.root, 1)
	}
	return out
}

// sameRun compares the Go and the bash answer of one invocation.
func (w *sdWorld) sameRun(args []string) {
	w.t.Helper()
	args = w.expand(args)
	gOut, gErr, gRC := w.runGo(args...)
	bOut, bErr, bRC := w.runBash("verify-skill-drift.sh", args...)
	gErr = w.scrub(gErr)
	if gRC == exitAbsent {
		gErr = strings.TrimSuffix(gErr, dispatcherDegraded) // the one declared difference
	}
	if gRC != bRC || gOut != bOut || gErr != w.scrub(bErr) {
		w.t.Errorf("verify skill-drift %q differs from the frozen script\ngo   rc=%d\nstdout %q\nstderr %q\nbash rc=%d\nstdout %q\nstderr %q", args, gRC, gOut, gErr, bRC, bOut, w.scrub(bErr))
	}
}

func TestSkillDriftDifferential(t *testing.T) {
	for _, sc := range sdScenarios(t) {
		t.Run(sc.name, func(t *testing.T) {
			if os.Geteuid() == 0 && strings.Contains(sc.name, "unreadable") {
				t.Skip("root reads a mode-000 file")
			}
			w := newSDWorld(t)
			w.withBash()
			sc.setup(w)
			for _, args := range sc.args {
				w.sameRun(args)
			}
		})
	}
}

// The kit reached through a symlink: both resolve it physically (cd -P), so the messages name the real paths.
func TestSkillDriftDifferentialKitThroughASymlink(t *testing.T) {
	w := newSDWorld(t)
	w.withBash()
	w.deploy(claudeRel, "x\n")
	link := filepath.Join(w.root, "kitlink")
	if err := os.Symlink(w.kit, link); err != nil {
		t.Fatal(err)
	}
	os.Remove(filepath.Join(w.kit, "skills", "research-sdd", "SKILL.md")) //nolint:errcheck
	for _, args := range [][]string{nil, {"--all"}} {
		gOut, gErr, gRC := w.runGoKit(link, args...)
		bOut, bErr, bRC := w.runBashAt(filepath.Join(link, "toolbelt", "verify-skill-drift.sh"), args...)
		if gRC != bRC || gOut != bOut || w.scrub(gErr) != w.scrub(bErr) {
			t.Errorf("%q through a symlinked kit: go rc=%d %q, bash rc=%d %q", args, gRC, w.scrub(gErr), bRC, w.scrub(bErr))
		}
	}
}

// The script's header is its --help; the Go copy must be the same bytes.
func TestSkillDriftHelpEqualsTheFrozenScriptHeader(t *testing.T) {
	w := newSDWorld(t)
	w.withBash()
	header, err := exec.Command("bash", "-c", `sed -n '3,32p' "$1" | sed 's/^# \{0,1\}//'`, "sh", filepath.Join(w.kit, "toolbelt", "verify-skill-drift.sh")).Output()
	if err != nil {
		t.Fatal(err)
	}
	if skillDriftHelp != string(header) {
		t.Errorf("skillDriftHelp differs from the script header:\n%q\n%q", skillDriftHelp, header)
	}
}

// The compiled-in adapter table must be what the installer's adapters.sh declares: this reads the REAL file.
func TestSkillDriftAdapterTableEqualsAdaptersSh(t *testing.T) {
	adapters := filepath.Join(sdLiveKit(t), "install", "adapters.sh")
	script := `. "$1"; echo "$RESEARCH_SDD_HARNESSES"; for h in $RESEARCH_SDD_HARNESSES; do
  printf '%s|%s|%s|%s\n' "$h" "$(rsdd_field "$h" config_root /H)" "$(rsdd_field "$h" skill_src_relkit)" "$(rsdd_field "$h" prompt_profile)"; done`
	cmd := exec.Command("bash", "-c", script, "sh", adapters)
	cmd.Env = []string{"PATH=" + sdTools(t), "HOME=/H"}
	out, err := cmd.Output()
	if err != nil {
		t.Fatal(err)
	}
	var want []string
	want = append(want, "") // the harness list line, filled below
	var names []string
	for _, h := range skillHarnesses {
		names = append(names, h.name)
		want = append(want, h.name+"|/H/"+h.configRel+"|"+h.skillSrcRelkit+"|"+h.defaultProfile)
	}
	want[0] = strings.Join(names, " ")
	if got := strings.TrimRight(string(out), "\n"); got != strings.Join(want, "\n") {
		t.Errorf("the compiled-in adapter table differs from install/adapters.sh\ngot  %q\nwant %q", got, strings.Join(want, "\n"))
	}
}

// Declared difference: a renderer that cannot be started is reported with Go's error text, not the shell's
// "Permission denied" line; the exit code, stdout and the closing ERROR line are the script's.
func TestSkillDriftRenderNotExecutableDiffersOnlyInTheSpawnMessage(t *testing.T) {
	w := newSDWorld(t)
	w.withBash()
	w.withProfiles()
	delete(w.env, "RESEARCH_SDD_PROFILE")
	w.deploy(piRel, "x\n")
	if err := os.Chmod(filepath.Join(w.kit, "toolbelt", "render-profile.sh"), 0o644); err != nil {
		t.Fatal(err)
	}
	args := []string{"--harness", "pi"}
	gOut, gErr, gRC := w.runGo(args...)
	bOut, bErr, bRC := w.runBash("verify-skill-drift.sh", args...)
	const prefix = "verify-skill-drift: render-profile.sh failed for profile \"general\": "
	const tail = "\nverify-skill-drift: ERROR: could not render profile for harness \"pi\"\n"
	for who, e := range map[string]string{"go": gErr, "bash": bErr} {
		if !strings.HasPrefix(e, prefix) || !strings.HasSuffix(e, tail) {
			t.Errorf("%s stderr is not the render-failure shape: %q", who, e)
		}
	}
	if !strings.Contains(gErr, "render-profile.sh: permission denied") || !strings.Contains(bErr, "Permission denied") {
		t.Errorf("the spawn messages are not the declared ones:\ngo   %q\nbash %q", gErr, bErr)
	}
	if gRC != bRC || gOut != bOut || gRC != 2 {
		t.Errorf("go rc=%d stdout=%q, bash rc=%d stdout=%q; want both 2 and empty", gRC, gOut, bRC, bOut)
	}
}
