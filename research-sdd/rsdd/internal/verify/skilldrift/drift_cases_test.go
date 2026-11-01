package skilldrift

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The case table of `verify skill-drift`. Every row is run three ways (parity_test.go): the frozen script, the Go command, and
// the recorded golden. `legacy` names the cases of tests/verify-skill-drift.test.sh the row replaces (the mapping is recorded
// in odd/tasks/verify-skill-drift-port.md); `rc` and `has` are what that suite asserted, checked on the Go output.

type dcase struct {
	name   string
	legacy string
	kit    string // stageKit variant ("" = real)
	home   func(t testing.TB, w *world)
	args   []string
	env    []string
	rc     int
	has    []string // substrings of stderr
	not    []string // substrings that must not occur in stderr
	silent bool     // stdout and stderr both empty
	root   bool     // the case needs a non-root user
	diverg bool     // an intended divergence (intended.go): checked against expectations only, never against the oracle
}

func skillSrc(t testing.TB) string {
	return readFile(t, filepath.Join(liveKit(t), "skills", "research-sdd", "SKILL.md"))
}

// deploy writes a deployed skill under the harness config dir (".claude", ".pi/agent", ...).
func deploy(t testing.TB, home, rel, content string) string {
	t.Helper()
	p := filepath.Join(home, rel, "skills", "research-sdd", "SKILL.md")
	write(t, p, content, 0o644)
	return p
}

func claudeSync(t testing.TB, w *world) { deploy(t, w.home, ".claude", skillSrc(t)) }
func claudeStale(t testing.TB, w *world) {
	deploy(t, w.home, ".claude", "# stale content — not matching kit\n")
}

func claudeSyncPiStale(t testing.TB, w *world) {
	claudeSync(t, w)
	deploy(t, w.home, ".pi/agent", "stale content — not matching kit\n")
}

func allStale(t testing.TB, w *world) {
	deploy(t, w.home, ".claude", "# stale claude\n")
	deploy(t, w.home, ".pi/agent", "# stale pi\n")
	deploy(t, w.home, ".gentle-shell/agent", "# stale gentle-shell\n")
}

func emptyClaudeRoot(t testing.TB, w *world) {
	if err := os.MkdirAll(filepath.Join(w.home, ".claude"), 0o755); err != nil {
		t.Fatal(err)
	}
}

func piInstalled(t testing.TB, w *world)   { installedHome(t, w.home, "pi") }
func bothInstalled(t testing.TB, w *world) { installedHome(t, w.home, "pi", "gentle-shell") }

func appendTo(t testing.TB, path, s string) {
	t.Helper()
	write(t, path, readFile(t, path)+s, 0o644)
}

func twoSrc(t testing.TB, w *world, a, b string) {
	kit := filepath.Dir(w.tb)
	for _, p := range [][2]string{{".harness_a", a}, {".harness_b", b}} {
		write(t, filepath.Join(w.home, p[0], "skills", "research-sdd", "SKILL.md"), readFile(t, filepath.Join(kit, "skills", p[1], "SKILL.md")), 0o644)
	}
}

var driftCases = []dcase{
	// ---- single-harness mode -----------------------------------------------------------------------------------------
	{name: "single-insync", legacy: "6 AX8", home: claudeSync, args: []string{"--harness", "claude", "--home", "@HOME@"}, silent: true},
	{name: "single-diverged", legacy: "7", home: claudeStale, args: []string{"--harness", "claude", "--home", "@HOME@"}, rc: 1, has: []string{"diverged harness=claude deployed="}},
	{name: "single-absent", legacy: "8 9", home: emptyClaudeRoot, args: []string{"--harness", "claude", "--home", "@HOME@"}, rc: 3, has: []string{"absent harness=claude deployed="}},
	{name: "single-default-harness", legacy: "6", home: claudeSync, args: []string{"--home", "@HOME@"}, silent: true},
	{name: "single-no-adapters", legacy: "10", kit: "noadapters", home: claudeSync, args: []string{"--harness", "claude", "--home", "@HOME@"}, rc: 2, has: []string{"ERROR: adapters.sh not found:"}},
	{name: "single-no-install-dir", legacy: "10", kit: "noinstall", home: claudeSync, args: []string{"--harness", "claude", "--home", "@HOME@"}, rc: 2, has: []string{"ERROR: install dir not found"}},
	{name: "single-unknown-harness", legacy: "11", home: claudeSync, args: []string{"--harness", "unknownharness", "--home", "@HOME@"}, rc: 2, has: []string{`ERROR: unknown harness "unknownharness"`}},
	{name: "single-harness-novalue", legacy: "11b", args: []string{"--harness"}, rc: 2, has: []string{"--harness requires a non-empty value"}},
	{name: "single-harness-emptyvalue", legacy: "11b", args: []string{"--harness", ""}, rc: 2, has: []string{"--harness requires a non-empty value"}},
	{name: "single-home-novalue", legacy: "11c", args: []string{"--home"}, rc: 2, has: []string{"--home requires a non-empty value"}},
	{name: "single-profile-novalue", legacy: "PD3", args: []string{"--profile"}, rc: 2, has: []string{"--profile requires a non-empty value"}},
	{name: "single-unknown-arg", legacy: "AN7", args: []string{"--bogus"}, rc: 2, has: []string{"unknown argument: --bogus"}},
	{name: "all-and-harness", legacy: "AN7", home: claudeSync, args: []string{"--all", "--harness", "claude", "--home", "@HOME@"}, rc: 2, has: []string{"--all and --harness are mutually exclusive"}},
	{name: "help", legacy: "AX9", args: []string{"--help"}, rc: 0},
	{name: "help-short-no-home", legacy: "AX9", args: []string{"-h"}, env: []string{"-HOME"}, rc: 0},
	{name: "help-stops-parsing", legacy: "AX9", args: []string{"--help", "--bogus"}, rc: 0},
	{name: "help-needs-adapters", legacy: "10", kit: "noadapters", args: []string{"--help"}, rc: 2, has: []string{"adapters.sh not found"}},
	{name: "single-dangling", legacy: "AX1", args: []string{"--harness", "claude", "--home", "@HOME@"}, rc: 2, has: []string{"could-not-run harness=claude (dangling symlink:"},
		home: func(t testing.TB, w *world) {
			symlink(t, w.root+"/nonexistent-target", filepath.Join(w.home, ".claude/skills/research-sdd/SKILL.md"))
		}},
	{name: "single-deployed-is-dir", legacy: "AX1", args: []string{"--harness", "claude", "--home", "@HOME@"}, rc: 2, has: []string{"deployed path exists but is not a regular file:"},
		home: func(t testing.TB, w *world) {
			if err := os.MkdirAll(filepath.Join(w.home, ".claude/skills/research-sdd/SKILL.md"), 0o755); err != nil {
				t.Fatal(err)
			}
		}},
	{name: "single-deployed-unreadable", legacy: "AX3", root: true, args: []string{"--harness", "claude", "--home", "@HOME@"}, rc: 2, has: []string{"ERROR: deployed skill not readable:"},
		home: func(t testing.TB, w *world) {
			p := deploy(t, w.home, ".claude", "deployed\n")
			if err := os.Chmod(p, 0); err != nil {
				t.Fatal(err)
			}
		}},
	{name: "single-src-missing", legacy: "AX4", kit: "nosrc", home: claudeSync, args: []string{"--harness", "claude", "--home", "@HOME@"}, rc: 2, has: []string{"ERROR: kit source not found:"}},
	{name: "single-home-unset", legacy: "AX6", args: []string{"--harness", "claude"}, env: []string{"-HOME"}, rc: 2, has: []string{"could-not-run: HOME is unset or empty and no --home given"}},
	{name: "single-home-empty-env", legacy: "AX6", args: []string{"--harness", "claude"}, env: []string{"HOME="}, rc: 2, has: []string{"could-not-run: HOME is unset or empty"}},
	{name: "single-home-flag-beats-unset-home", legacy: "AX8", home: claudeSync, args: []string{"--harness", "claude", "--home", "@HOME@"}, env: []string{"-HOME"}, silent: true},
	{name: "single-home-from-env", legacy: "6", home: claudeSync, args: []string{"--harness", "claude"}, env: []string{"HOME=@HOME@"}, silent: true},
	// ---- profiles ----------------------------------------------------------------------------------------------------------
	{name: "profile-claude-flag", legacy: "PD2", home: claudeSync, args: []string{"--harness", "claude", "--home", "@HOME@", "--profile", "claude"}, silent: true},
	{name: "profile-unknown", legacy: "PD3", home: claudeSync, args: []string{"--harness", "claude", "--home", "@HOME@", "--profile", "bogus-profile-xyz"}, rc: 2, has: []string{`ERROR: unknown profile for harness "claude"`}},
	{name: "profile-unsafe-name", legacy: "PD3", home: claudeSync, args: []string{"--harness", "claude", "--home", "@HOME@", "--profile", "../profiles/general"}, rc: 2, has: []string{"unknown profile"}},
	{name: "profile-env-unknown", legacy: "PD3", home: claudeSync, args: []string{"--harness", "claude", "--home", "@HOME@"}, env: []string{"RESEARCH_SDD_PROFILE=bogus"}, rc: 2, has: []string{"unknown profile"}},
	{name: "profile-flag-beats-env", legacy: "PD2", home: claudeSync, args: []string{"--harness", "claude", "--home", "@HOME@", "--profile", "claude"}, env: []string{"RESEARCH_SDD_PROFILE=bogus"}, silent: true},
	{name: "profile-unknown-absent-still-errors", legacy: "PD3", home: emptyClaudeRoot, args: []string{"--harness", "claude", "--home", "@HOME@", "--profile", "bogus"}, rc: 2, has: []string{"unknown profile"}},
	{name: "profile-pi-insync", legacy: "PD1a PIH1", home: piInstalled, args: []string{"--harness", "pi", "--home", "@HOME@"}, silent: true},
	{name: "profile-pi-explicit-general", legacy: "PD1a", home: piInstalled, args: []string{"--harness", "pi", "--home", "@HOME@", "--profile", "general"}, silent: true},
	{name: "profile-pi-handedit", legacy: "PD1b", args: []string{"--harness", "pi", "--home", "@HOME@"}, rc: 1, has: []string{"diverged harness=pi deployed="},
		home: func(t testing.TB, w *world) {
			piInstalled(t, w)
			appendTo(t, filepath.Join(w.home, ".pi/agent/skills/research-sdd/SKILL.md"), "\n<!-- hand-edited by an operator -->\n")
		}},
	{name: "profile-pi-claude-profile-diverges", legacy: "TOOTH PD", home: piInstalled, args: []string{"--harness", "pi", "--home", "@HOME@", "--profile", "claude"}, rc: 1, has: []string{"diverged harness=pi"}},
	{name: "profile-gentle-shell-insync", legacy: "PIH1", home: bothInstalled, args: []string{"--harness", "gentle-shell", "--home", "@HOME@"}, silent: true},
	{name: "profile-render-missing", legacy: "F3-missing", args: []string{"--harness", "pi", "--home", "@HOME@"}, rc: 2, has: []string{"render dir missing:"},
		home: func(t testing.TB, w *world) {
			piInstalled(t, w)
			_ = os.RemoveAll(filepath.Join(w.home, ".pi/agent/research-sdd/profile/general"))
		}},
	{name: "profile-render-handedit", legacy: "F3-handedit", args: []string{"--harness", "pi", "--home", "@HOME@"}, rc: 2, has: []string{"render dir diverged:"},
		home: func(t testing.TB, w *world) {
			piInstalled(t, w)
			appendTo(t, filepath.Join(w.home, ".pi/agent/research-sdd/profile/general/PROMPT-LOOP.md"), "tampered\n")
		}},
	{name: "profile-render-incomplete", legacy: "F3-missing", args: []string{"--harness", "pi", "--home", "@HOME@"}, rc: 2, has: []string{"render dir incomplete:"},
		home: func(t testing.TB, w *world) {
			piInstalled(t, w)
			if err := os.Remove(filepath.Join(w.home, ".pi/agent/research-sdd/profile/general/TARGETS.md")); err != nil {
				t.Fatal(err)
			}
		}},
	{name: "profile-render-failed", legacy: "F3", kit: "rfail", args: []string{"--harness", "pi", "--home", "@HOME@"}, rc: 2, has: []string{"ERROR: could not render profile", "render-profile.sh failed for profile \"general\": render out line"},
		home: func(t testing.TB, w *world) { deploy(t, w.home, ".pi/agent", "x\n") }},
	{name: "profile-render-missing-script", legacy: "F3", kit: "norender", diverg: true, args: []string{"--harness", "pi", "--home", "@HOME@"}, rc: 2, has: []string{"ERROR: could not render profile", "render-profile.sh failed for profile \"general\": "},
		home: func(t testing.TB, w *world) { deploy(t, w.home, ".pi/agent", "x\n") }},
	{name: "profile-render-not-executable", legacy: "F3", kit: "rnoexec", diverg: true, args: []string{"--harness", "pi", "--home", "@HOME@"}, rc: 2, has: []string{"ERROR: could not render profile", "Permission denied"},
		home: func(t testing.TB, w *world) { deploy(t, w.home, ".pi/agent", "x\n") }},
	// ---- --all mode ---------------------------------------------------------------------------------------------------------
	{name: "all-insync-one", legacy: "AN6 AX5 BDG1", home: claudeSync, args: []string{"--all", "--home", "@HOME@"}, silent: true},
	{name: "all-all-absent", legacy: "AN5 AN-hook-3", home: func(t testing.TB, w *world) {}, args: []string{"--all", "--home", "@HOME@"}, silent: true},
	{name: "all-middle-diverged", legacy: "AN1 AN2 AN3 AN4", home: claudeSyncPiStale, args: []string{"--all", "--home", "@HOME@"}, rc: 1,
		has: []string{"fix: research-sdd-install.sh --harness pi --force-skill  # deployed: ~/.pi/agent/skills/research-sdd/SKILL.md", "all: checked=3 in-sync=1 diverged=1 absent=1 could-not-run=0"}},
	{name: "all-three-diverged", legacy: "BDG3 REM1", home: allStale, args: []string{"--all", "--home", "@HOME@"}, rc: 1,
		has: []string{"--harness claude --force-skill", "also diverged: pi, gentle-shell (same fix with --harness <name>)", "diverged=3"}},
	{name: "all-last-diverged", legacy: "PIH4 TOOTH D", args: []string{"--all", "--home", "@HOME@"}, rc: 1, has: []string{"fix: research-sdd-install.sh --harness gentle-shell --force-skill"},
		home: func(t testing.TB, w *world) {
			bothInstalled(t, w)
			appendTo(t, filepath.Join(w.home, ".gentle-shell/agent/skills/research-sdd/SKILL.md"), "\n<!-- hand-edited -->\n")
		}},
	{name: "all-installed-insync", legacy: "PIH3", home: bothInstalled, args: []string{"--all", "--home", "@HOME@"}, silent: true},
	{name: "all-two-diverged", legacy: "PIH5", args: []string{"--all", "--home", "@HOME@"}, rc: 1, has: []string{"diverged=2", "also diverged: gentle-shell"},
		home: func(t testing.TB, w *world) {
			bothInstalled(t, w)
			appendTo(t, filepath.Join(w.home, ".gentle-shell/agent/skills/research-sdd/SKILL.md"), "\n<!-- hand-edited -->\n")
			appendTo(t, filepath.Join(w.home, ".pi/agent/skills/research-sdd/SKILL.md"), "\n<!-- hand-edited -->\n")
		}},
	{name: "all-harness-dropped", legacy: "TOOTH PIH", kit: "nopi", args: []string{"--all", "--home", "@HOME@"}, rc: 0, not: []string{"gentle-shell"},
		home: func(t testing.TB, w *world) { deploy(t, w.home, ".gentle-shell/agent", "stale\n") }},
	{name: "all-dangling", legacy: "AX2 TOOTH G TOOTH J", args: []string{"--all", "--home", "@HOME@"}, rc: 2, has: []string{"could-not-run harness=claude (dangling symlink:", "could-not-run=1"},
		home: func(t testing.TB, w *world) {
			symlink(t, w.root+"/nonexistent-target", filepath.Join(w.home, ".claude/skills/research-sdd/SKILL.md"))
		}},
	{name: "all-diverged-plus-error", legacy: "TOOTH J", args: []string{"--all", "--home", "@HOME@"}, rc: 1, has: []string{"diverged=1", "could-not-run=1"},
		home: func(t testing.TB, w *world) {
			symlink(t, w.root+"/nonexistent-target", filepath.Join(w.home, ".claude/skills/research-sdd/SKILL.md"))
			deploy(t, w.home, ".pi/agent", "stale\n")
		}},
	{name: "all-unreadable", legacy: "AX3", root: true, args: []string{"--all", "--home", "@HOME@"}, rc: 2, has: []string{"could-not-run harness=claude (deployed not a readable file:"},
		home: func(t testing.TB, w *world) {
			p := deploy(t, w.home, ".claude", "deployed\n")
			if err := os.Chmod(p, 0); err != nil {
				t.Fatal(err)
			}
		}},
	{name: "all-deployed-is-dir", legacy: "AX3", args: []string{"--all", "--home", "@HOME@"}, rc: 2, has: []string{"deployed not a readable file:"},
		home: func(t testing.TB, w *world) {
			if err := os.MkdirAll(filepath.Join(w.home, ".claude/skills/research-sdd/SKILL.md"), 0o755); err != nil {
				t.Fatal(err)
			}
		}},
	{name: "all-src-missing", legacy: "AX4", kit: "nosrc", home: claudeSync, args: []string{"--all", "--home", "@HOME@"}, rc: 2, has: []string{"could-not-run harness=claude (src missing:", "could-not-run=1"}},
	{name: "all-unknown-profile", legacy: "PD3", home: claudeSync, args: []string{"--all", "--home", "@HOME@", "--profile", "bogus"}, rc: 2, has: []string{"could-not-run harness=claude (unknown profile)"}},
	{name: "all-render-failed", legacy: "F3", kit: "rfail", args: []string{"--all", "--home", "@HOME@"}, rc: 2, has: []string{"could-not-run harness=pi (profile render failed)", "render-profile.sh failed for profile \"general\""},
		home: func(t testing.TB, w *world) { deploy(t, w.home, ".pi/agent", "x\n") }},
	{name: "all-render-missing", legacy: "F3-missing", args: []string{"--all", "--home", "@HOME@"}, rc: 2, has: []string{"could-not-run harness=pi (render dir missing:"},
		home: func(t testing.TB, w *world) {
			piInstalled(t, w)
			_ = os.RemoveAll(filepath.Join(w.home, ".pi/agent/research-sdd/profile/general"))
		}},
	{name: "all-render-handedit-diverged-wins", legacy: "F3-handedit", args: []string{"--all", "--home", "@HOME@"}, rc: 1, has: []string{"diverged=1"},
		home: func(t testing.TB, w *world) {
			piInstalled(t, w)
			appendTo(t, filepath.Join(w.home, ".pi/agent/research-sdd/profile/general/PROMPT-LOOP.md"), "tampered\n")
			appendTo(t, filepath.Join(w.home, ".pi/agent/skills/research-sdd/SKILL.md"), "x\n")
		}},
	{name: "all-render-handedit", legacy: "F3-handedit", args: []string{"--all", "--home", "@HOME@"}, rc: 2, has: []string{"could-not-run harness=pi (render dir diverged:"},
		home: func(t testing.TB, w *world) {
			piInstalled(t, w)
			appendTo(t, filepath.Join(w.home, ".pi/agent/research-sdd/profile/general/PROMPT-LOOP.md"), "tampered\n")
		}},
	{name: "all-home-unset", legacy: "AX6 AX7", args: []string{"--all"}, env: []string{"-HOME"}, rc: 2, has: []string{"could-not-run: HOME is unset or empty and no --home given"}},
	{name: "all-pi-agent-home-override", legacy: "PIH", args: []string{"--all"}, env: []string{"HOME=@HOME@", "GENTLE_PI_AGENT_HOME=@ROOT@/piagent"}, rc: 1, has: []string{"diverged=1"},
		home: func(t testing.TB, w *world) { deploy(t, filepath.Join(w.root, "piagent"), ".", "x\n") }},
	{name: "all-pi-agent-home-invalid", legacy: "PIH", args: []string{"--all"}, env: []string{"HOME=@HOME@", "GENTLE_PI_AGENT_HOME=relative/dir"}, rc: 0, has: []string{"rsdd_field: GENTLE_PI_AGENT_HOME must be an absolute path other than /"}},
	{name: "single-harness-takes-flag-as-value", legacy: "11", args: []string{"--harness", "--all", "--home", "@HOME@"}, rc: 2, has: []string{`ERROR: unknown harness "--all"`}},
	{name: "single-home-takes-flag-as-value", legacy: "8", args: []string{"--home", "--all"}, rc: 3, has: []string{"absent harness=claude deployed=--all/.claude/skills/research-sdd/SKILL.md"}},
	{name: "profile-empty-value", legacy: "PD3", args: []string{"--profile", ""}, rc: 2, has: []string{"--profile requires a non-empty value"}},
	{name: "all-claude-and-pi-insync", legacy: "PIH3", args: []string{"--all", "--home", "@HOME@"}, silent: true,
		home: func(t testing.TB, w *world) { claudeSync(t, w); piInstalled(t, w) }},
	{name: "all-profile-flag-claude-diverges-installed", legacy: "TOOTH PD", home: bothInstalled, args: []string{"--all", "--home", "@HOME@", "--profile", "claude"}, rc: 1, has: []string{"diverged=2", "also diverged: gentle-shell"}},
	{name: "single-profile-env-claude-diverges-installed", legacy: "TOOTH PD", home: piInstalled, args: []string{"--harness", "pi", "--home", "@HOME@"}, env: []string{"RESEARCH_SDD_PROFILE=claude"}, rc: 1, has: []string{"diverged harness=pi"}},
	// ---- two-source fixture (adapters.sh without profile support) -------------------------------------------------------------
	{name: "two-both-insync", legacy: "SRC1", kit: "two", args: []string{"--all", "--home", "@HOME@"}, silent: true,
		home: func(t testing.TB, w *world) { twoSrc(t, w, "source_a", "source_b") }},
	{name: "two-wrong-source", legacy: "SRC2 TOOTH E", kit: "two", args: []string{"--all", "--home", "@HOME@"}, rc: 1, has: []string{"fix: research-sdd-install.sh --harness harness_b --force-skill"},
		home: func(t testing.TB, w *world) { twoSrc(t, w, "source_a", "source_a") }},
	{name: "two-single-harness-b", legacy: "SRC2", kit: "two", args: []string{"--harness", "harness_b", "--home", "@HOME@"}, rc: 1, has: []string{"diverged harness=harness_b"},
		home: func(t testing.TB, w *world) { twoSrc(t, w, "source_a", "source_a") }},
	{name: "two-profile-flag-ignored", legacy: "SRC1", kit: "two", args: []string{"--all", "--home", "@HOME@", "--profile", "bogus"}, silent: true,
		home: func(t testing.TB, w *world) { twoSrc(t, w, "source_a", "source_b") }},
	{name: "two-one-absent-one-diverged", legacy: "TOOTH E", kit: "two", args: []string{"--all", "--home", "@HOME@"}, rc: 1, has: []string{"checked=2 in-sync=0 diverged=1 absent=1 could-not-run=0"},
		home: func(t testing.TB, w *world) {
			write(t, filepath.Join(w.home, ".harness_b/skills/research-sdd/SKILL.md"), "wrong\n", 0o644)
		}},
}

func (c dcase) setupWorld(t testing.TB) *world {
	w := newWorld(t, c.kit)
	if c.home != nil {
		c.home(t, w)
	}
	return w
}

func hasAll(s string, subs []string) (string, bool) {
	for _, x := range subs {
		if !strings.Contains(s, x) {
			return x, false
		}
	}
	return "", true
}
