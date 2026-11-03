package sweep

import (
	"os"
	"strings"
	"testing"
)

// The behaviour table of `sweep tools`. Every row is one fixture world and one run; the same rows run against
// the frozen scripts in tools_diff_test.go (stdout, stderr and exit code of the report and of the hook must be
// equal), so an expectation written here is also what the script printed. `old` names the case of the pre-port
// sweep-tools(-hook).test.sh the row replaces (the removed-case map is L3 of odd/tasks/sweep-tools-go.md).
// golden marks a world made of plain files and directories only (no symlink, no mode bit), so it can be
// recorded in testdata/tools/golden/cases.txt and replayed without bash. nodiff marks a declared difference
// from the script (L4): the row runs against the Go command only, and says why.

type toolScenario struct {
	name   string
	old    string
	setup  func(w *world)
	args   []string
	rc     int
	has    []string // substrings of stdout
	lacks  []string // substrings that stdout must not hold
	errHas []string // substrings of stderr
	hook   []string // substrings of the hook's additionalContext
	silent bool     // the hook prints nothing at all
	golden bool
	nodiff string
}

const (
	ledgerHint = "Run toolbelt/sweep-tools.sh for per-target breakdown."
)

// target makes targetA with the given scripts (non-executable) and registers it.
func target(files ...string) func(w *world) {
	return func(w *world) {
		a := w.tgt("targetA")
		for _, f := range files {
			w.tool(a, f, false)
		}
		w.targets(a)
	}
}

func toolScenarios() []toolScenario {
	return []toolScenario{
		{name: "abs path two tools", old: "1", setup: target("scan.py", "extract.sh"), golden: true,
			has:  []string{"TARGET  targetA\n        tools: 2 found\n", "Summary: 2 tool(s) across 1 target(s) · 0 recorded (retro) · 0 recorded (ledger) · 2 unrecorded.\n"},
			hook: []string{"Research-SDD tool ledger (unrecorded tools found):\nSummary: 2 tool(s)", ledgerHint}},
		{name: "RESEARCH_HOME form resolves", old: "2", golden: true, setup: func(w *world) {
			w.tool(w.root+"/rh/targetB", "probe.sh", false)
			w.env["RESEARCH_HOME"] = w.root + "/rh"
			w.targets("$RESEARCH_HOME/targetB")
		}, has: []string{"TARGET  targetB\n        tools: 1 found\n", "Summary: 1 tool(s) across 1 target(s)"}},
		{name: "no tools dir is empty-input", old: "3", golden: true, setup: func(w *world) { w.targets(w.tgt("targetA")) },
			has: []string{"TARGET  targetA\n        INFO: no tools/ directory (empty-input)\n", "Summary: 0 tool(s) across 1 target(s)"}, lacks: []string{"found"},
			silent: true},
		{name: "empty tools dir", old: "4", golden: true, setup: func(w *world) {
			a := w.tgt("targetA")
			w.must(os.MkdirAll(a+"/tools", 0o755))
			w.targets(a)
		}, has: []string{"        INFO: tools/ directory exists but is empty (empty-input)\n"}, lacks: []string{"no tools/ directory"}, silent: true},
		{name: "non-tool file is counted apart", old: "5", golden: true, setup: func(w *world) {
			a := w.tgt("targetA")
			w.tool(a, "real.py", false)
			w.put(a+"/tools/data.csv", "data\n")
			w.targets(a)
		}, has: []string{"        tools: 1 found (1 non-tool file(s) in tools/ not counted)\n"}},
		{name: "retro T-row recorded", old: "6", golden: true, setup: func(w *world) {
			a := w.tgt("targetA")
			w.tool(a, "recorded.py", false)
			w.tool(a, "unrecorded.sh", false)
			w.toolRetro(a, "r1.md", "recorded.py")
			w.targets(a)
		}, has: []string{"        recorded (retro): 1  ·  recorded (ledger): 0  ·  unrecorded: 1\n", "Summary: 2 tool(s) across 1 target(s) · 1 recorded (retro) · 0 recorded (ledger) · 1 unrecorded.\n"}},
		{name: "missing TARGETS.md", old: "7", setup: func(w *world) {}, rc: 1, golden: true,
			errHas: []string{"sweep-tools: cannot find {kit}/TARGETS.md\n"}, lacks: []string{"Summary:"},
			hook: []string{"Research-SDD tools sweep could not run (exit 1 — check TARGETS.md and lib/ helper):\nsweep-tools: cannot find {kit}/TARGETS.md"}},
		{name: "no usable path", old: "8", golden: true, setup: func(w *world) { w.targets("/home/user/.../research") }, rc: 1,
			errHas: []string{"sweep-tools: ERROR — no usable target paths in {kit}/TARGETS.md\nsweep-tools: check TARGETS.md has backtick-wrapped absolute or $RESEARCH_HOME/... paths\n"},
			lacks:  []string{"Summary:"}},
		{name: "truncated path is skipped and named", old: "9", golden: true, setup: func(w *world) {
			a := w.tgt("targetA")
			w.tool(a, "scan.sh", false)
			w.targets(a, "/home/user/.../truncated")
		}, has: []string{"WARN: 1 target(s) skipped — truncated/unresolvable path in TARGETS.md; this sweep is PARTIAL: truncated\n", "TARGET  targetA"},
			hook: []string{"Summary: 1 tool(s)", "WARN: 1 target(s) skipped"}},
		{name: "retros without a tools table", old: "11", golden: true, setup: func(w *world) {
			a := w.tgt("targetA")
			w.tool(a, "scan.py", false)
			w.put(a+"/retros/r1.md", "<!-- review-status: applied 2026-01-01 -->\n# Retro\n\nNo tools table here.\n")
			w.targets(a)
		}, has: []string{"unrecorded: 1  ·  no retro has a tools table\n"}, lacks: []string{"no retros found"}},
		{name: "no retros at all", old: "(spot)", setup: target("scan.py"), golden: true, has: []string{"unrecorded: 1  ·  no retros found\n"}},
		{name: "ledger only", old: "12", golden: true, setup: func(w *world) {
			a := w.tgt("targetA")
			w.tool(a, "ledger-tool.py", false)
			w.tool(a, "other-tool.sh", false)
			w.ledger(a, "ledger-tool.py", "other-tool.sh")
			w.targets(a)
		}, has: []string{"recorded (retro): 0  ·  recorded (ledger): 2  ·  unrecorded: 0", "Summary: 2 tool(s) across 1 target(s) · 0 recorded (retro) · 2 recorded (ledger) · 0 unrecorded.\n"},
			silent: true},
		{name: "retro and ledger no double count", old: "13", golden: true, setup: func(w *world) {
			a := w.tgt("targetA")
			for _, n := range []string{"both.py", "ledger-only.sh", "neither.py"} {
				w.tool(a, n, false)
			}
			w.toolRetro(a, "r1.md", "both.py")
			w.ledger(a, "both.py", "ledger-only.sh")
			w.targets(a)
		}, has: []string{"recorded (retro): 1  ·  recorded (ledger): 1  ·  unrecorded: 1", "Summary: 3 tool(s) across 1 target(s) · 1 recorded (retro) · 1 recorded (ledger) · 1 unrecorded."}},
		{name: "ledger without a table", old: "14", golden: true, setup: func(w *world) {
			a := w.tgt("targetA")
			w.tool(a, "scan.py", false)
			w.put(a+"/tools/README.md", "Tools are documented in ESTADO-SITIO.md.\n\nNo table here.\n")
			w.targets(a)
		}, has: []string{"        WARN: tools/README.md has no table — ledger unreadable\n        recorded (retro): 0  ·  unrecorded: 1"}, lacks: []string{"recorded (ledger): "}},
		{name: "separator rows alone are no table", old: "(spot)", golden: true, setup: func(w *world) {
			a := w.tgt("targetA")
			w.tool(a, "scan.py", false)
			w.put(a+"/tools/README.md", "|---|---|\n| - | - |\n|:--|--:|\n")
			w.targets(a)
		}, has: []string{"has no table"}},
		{name: "dependency dirs are excluded", old: "15", golden: true, setup: func(w *world) {
			a := w.tgt("targetA")
			w.tool(a, "scan.py", false)
			w.tool(a, "extract.sh", false)
			for _, d := range []string{"node_modules/pkg/index.js", "node_modules/pkg/dep.py", "__pycache__/mod.pyc", ".venv/bin/x.py", ".git/hooks/h.sh", "sub/node_modules/y.js"} {
				w.put(a+"/tools/"+d, "x\n")
			}
			w.targets(a)
		}, has: []string{"tools: 2 found\n"}, lacks: []string{"non-tool"}},
		{name: "_lib dir is disclosed", old: "16", golden: true, setup: func(w *world) {
			a := w.tgt("targetA")
			w.tool(a, "main_tool.py", false)
			w.tool(a, "module_nav_lib/parser.py", false)
			w.tool(a, "module_nav_lib/deep/scanner.py", false)
			w.targets(a)
		}, has: []string{"tools: 1 found (2 library module(s) not counted as tools)\n", "Summary: 1 tool(s) across 1 target(s)"}},
		{name: "package internals are disclosed", old: "16b", golden: true, setup: func(w *world) {
			a := w.tgt("targetA")
			w.tool(a, "main_tool.py", false)
			w.put(a+"/tools/my_package/__init__.py", "")
			w.tool(a, "my_package/helper.py", false)
			w.tool(a, "my_package/sub/deeper.py", false) // only the immediate parent is a package
			w.targets(a)
		}, has: []string{"tools: 2 found (2 library module(s) not counted as tools)\n"}},
		{name: "lib module and non-tool file both disclosed", old: "(spot)", golden: true, setup: func(w *world) {
			a := w.tgt("targetA")
			w.tool(a, "x_lib/m.py", false)
			w.put(a+"/tools/x_lib/notes.txt", "n\n")
			w.tool(a, "t.sh", false)
			w.targets(a)
		}, has: []string{"tools: 1 found (1 library module(s) not counted as tools) (1 non-tool file(s) in tools/ not counted)\n"}},
		{name: "absent target is disclosed", old: "17", golden: true, setup: func(w *world) {
			a := w.tgt("targetA")
			w.tool(a, "scan.py", false)
			w.targets(a, w.root+"/nonexistent-target")
		}, has: []string{"INFO: corpus not found (absent-input): {root}/nonexistent-target\n", "INFO: 1 target(s) not traversed (absent-input) — corpus directory not found; see INFO lines above.\n", "Summary: 1 tool(s) across 1 target(s)"},
			hook: []string{"Research-SDD tool ledger (unrecorded tools found):\nSummary: 1 tool(s)", "INFO: 1 target(s) not traversed"}},
		{name: "only absent targets still speaks", old: "(hook 9)", golden: true, setup: func(w *world) { w.targets(w.root + "/nowhere") },
			has:  []string{"Summary: 0 tool(s) across 0 target(s)", "INFO: 1 target(s) not traversed"},
			hook: []string{"Research-SDD tool ledger (targets not traversed):\nSummary: 0 tool(s) across 0 target(s)", "INFO: 1 target(s) not traversed (absent-input)", ledgerHint}},
		{name: "unreadable retro warns", old: "18", golden: true, setup: func(w *world) {
			a := w.tgt("targetA")
			w.tool(a, "tool.sh", false)
			w.toolRetro(a, "retro1.md", "tool.sh")
			w.must(os.MkdirAll(a+"/retros/dir.md", 0o755)) // a directory named like a retro cannot be read as one
			w.targets(a)
		}, has: []string{"TARGET  targetA\n   WARN: 1 retro(s) unreadable during T-row scan (grep error)\n        tools: 1 found\n", "1 recorded (retro)"}},
		{name: "unreadable retro file warns", old: "18", golden: true, setup: func(w *world) {
			a := w.tgt("targetA")
			w.tool(a, "tool.sh", false)
			w.toolRetro(a, "retro1.md", "tool.sh")
			w.toolRetro(a, "retro2.md", "other.sh")
			w.unreadable(a + "/retros/retro2.md")
			w.targets(a)
		}, has: []string{"   WARN: 1 retro(s) unreadable during T-row scan (grep error)\n        tools: 1 found\n", "1 recorded (retro)"}},
		{name: "unreadable ledger is an error not a zero", old: "19 19b", golden: true, setup: func(w *world) {
			a := w.tgt("targetA")
			w.tool(a, "scan.py", false)
			w.ledger(a, "scan.py")
			w.unreadable(a + "/tools/README.md")
			w.targets(a)
		}, has: []string{"        WARN: tools/README.md scan FAILED (grep error) — ledger count unavailable\n        recorded (retro): 0  ·  unrecorded: 1  ·  no retros found\n"},
			lacks: []string{"recorded (ledger): "}},
		{name: "executable without extension is a tool", old: "(spot)", setup: func(w *world) {
			a := w.tgt("targetA")
			w.tool(a, "runner", true)
			w.tool(a, "plain", false)
			w.targets(a)
		}, has: []string{"tools: 1 found (1 non-tool file(s) in tools/ not counted)\n"}},
		{name: "extension is case sensitive", old: "(spot)", golden: true, setup: target("Scan.PY", "ok.ps1", "m.mjs", "j.js", "t.ts", "x.sh~"),
			has: []string{"tools: 4 found (2 non-tool file(s) in tools/ not counted)\n"}},
		{name: "ledger name needs a boundary", old: "(spot)", golden: true, setup: func(w *world) {
			a := w.tgt("targetA")
			w.tool(a, "envelope.py", false)
			w.tool(a, "gf-envelope.py", false)
			w.ledger(a, "gf-envelope.py")
			w.targets(a)
		}, has: []string{"recorded (retro): 0  ·  recorded (ledger): 1  ·  unrecorded: 1"}},
		{name: "ledger row must end the name with a boundary", old: "(spot)", golden: true, setup: func(w *world) {
			a := w.tgt("targetA")
			w.tool(a, "scan.py", false)
			w.put(a+"/tools/README.md", "| Tool |\n|---|\n| scan.py\n| scan.pyc |\n")
			w.targets(a)
		}, has: []string{"recorded (ledger): 0  ·  unrecorded: 1"}},
		{name: "retro match is a substring of the row", old: "(spot)", golden: true, setup: func(w *world) {
			a := w.tgt("targetA")
			w.tool(a, "scan.py", false)
			w.tool(a, "can.py", false) // a substring of scan.py: the script counts it recorded
			w.toolRetro(a, "r1.md", "scan.py")
			w.put(a+"/retros/not-a-row.md", "mentions tools/other.py in prose\n")
			w.targets(a)
		}, has: []string{"recorded (retro): 2  ·  recorded (ledger): 0  ·  unrecorded: 0"}},
		{name: "index retros are not read", old: "(spot)", golden: true, setup: func(w *world) {
			a := w.tgt("targetA")
			w.tool(a, "scan.py", false)
			w.toolRetro(a, "RETRO-INDEX.md", "scan.py")
			w.targets(a)
		}, has: []string{"unrecorded: 1  ·  no retros found\n"}},
		{name: "multi-target totals", old: "(spot)", golden: true, setup: func(w *world) {
			a, b := w.tgt("targetA"), w.tgt("targetB")
			w.tool(a, "a.py", false)
			w.tool(b, "b.sh", false)
			w.tool(b, "c.sh", false)
			w.toolRetro(b, "r.md", "b.sh")
			w.targets(a, b)
		}, has: []string{"Summary: 3 tool(s) across 2 target(s) · 1 recorded (retro) · 0 recorded (ledger) · 2 unrecorded."}},
		{name: "same target twice is swept twice", old: "(spot)", golden: true, setup: func(w *world) {
			a := w.tgt("targetA")
			w.tool(a, "a.py", false)
			w.targets(a, a+"/")
		}, has: []string{"Summary: 2 tool(s) across 2 target(s)"}},
		{name: "target path with a space is split into words", old: "(spot)", setup: func(w *world) {
			a := w.tgt("my target")
			w.tool(a, "a.py", false)
			w.targets(a)
		}, has: []string{"INFO: corpus not found (absent-input): {root}/my\n", "INFO: corpus not found (absent-input): target\n"}},
		{name: "unknown arguments are ignored", old: "(script ignored them)", setup: target("a.py"), args: []string{"--nope", "extra"},
			has: []string{"Summary: 1 tool(s) across 1 target(s)"}},
		{name: "symlinks in tools are not files", old: "(spot)", setup: func(w *world) {
			a := w.tgt("targetA")
			w.tool(a, "real.py", false)
			w.must(os.Symlink(a+"/tools/real.py", a+"/tools/link.py"))
			w.targets(a)
		}, has: []string{"tools: 1 found\n"}},

		// Declared differences (L4): the Go command is right, the script was not.
		{name: "tools symlinked to a directory is followed", old: "(L4.3)", nodiff: "the script's find listed the link and read it as empty", setup: func(w *world) {
			a := w.tgt("targetA")
			w.tool(w.root+"/elsewhere", "real.py", false)
			w.must(os.Rename(w.root+"/elsewhere/tools", w.root+"/real-tools"))
			w.must(os.Symlink(w.root+"/real-tools", a+"/tools"))
			w.targets(a)
		}, has: []string{"        tools: 1 found\n"}, lacks: []string{"exists but is empty"}},
		{name: "target under a dependency dir keeps its tools", old: "(L4.1)", nodiff: "the script matched the exclusion on the whole path, target prefix included", setup: func(w *world) {
			a := w.tgt(".venv/targetA")
			w.tool(a, "scan.py", false)
			w.targets(a)
		}, has: []string{"        tools: 1 found\n"}, lacks: []string{"exists but is empty"}},
		{name: "regex metacharacters in a ledger name are literal", old: "(L4.2)", nodiff: "the script read the name as a regex with only the dot escaped", setup: func(w *world) {
			a := w.tgt("targetA")
			w.tool(a, "a+b.sh", false)
			w.ledger(a, "a+b.sh")
			w.targets(a)
		}, has: []string{"recorded (ledger): 1  ·  unrecorded: 0"}},
		{name: "tool name starting with a dash is found in a retro", old: "(L4.2)", nodiff: "grep -qF read the name as an option", setup: func(w *world) {
			a := w.tgt("targetA")
			w.tool(a, "-x.sh", false)
			w.toolRetro(a, "r1.md", "-x.sh")
			w.targets(a)
		}, has: []string{"recorded (retro): 1  ·  recorded (ledger): 0  ·  unrecorded: 0"}},
	}
}

func TestToolsScenarios(t *testing.T) {
	for _, sc := range toolScenarios() {
		t.Run(sc.name, func(t *testing.T) {
			w := newWorld(t)
			sc.setup(w)
			r := w.runTools(sc.args...)
			if r.rc != sc.rc {
				t.Errorf("exit %d, want %d\nstdout:\n%s\nstderr:\n%s", r.rc, sc.rc, r.out, r.err)
			}
			for _, h := range sc.has {
				if !strings.Contains(r.out, w.expand(h)) {
					t.Errorf("stdout lacks %q\n%s", h, r.out)
				}
			}
			for _, l := range sc.lacks {
				if strings.Contains(r.out, w.expand(l)) {
					t.Errorf("stdout holds %q\n%s", l, r.out)
				}
			}
			for _, h := range sc.errHas {
				if !strings.Contains(r.err, w.expand(h)) {
					t.Errorf("stderr lacks %q\n%s", h, r.err)
				}
			}
			if sc.rc == 0 && r.err != "" {
				t.Errorf("unexpected stderr: %q", r.err)
			}
			hr := w.runToolsHook(sc.args...)
			ctx := decodeHookCtx(t, hr.out)
			if hr.rc != 0 || hr.err != "" {
				t.Errorf("a hook exits 0 with an empty stderr: %+v", hr)
			}
			if sc.silent && hr.out != "" {
				t.Errorf("the hook must stay silent, it printed %q", hr.out)
			}
			for _, h := range sc.hook {
				if !strings.Contains(ctx, w.expand(h)) {
					t.Errorf("hook context lacks %q\n%s", h, ctx)
				}
			}
		})
	}
}
