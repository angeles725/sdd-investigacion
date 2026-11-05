package sweep

import (
	"os"
	"strconv"
	"strings"
	"testing"
)

// The behaviour table of `sweep all`. Every row is one world (a toolbelt of stub scripts) and one run; the same
// rows run against the frozen sweep-all.sh in all_diff_test.go (stdout, stderr and the exit code must be equal),
// so an expectation written here is also what the script printed. `old` names the case of the pre-port
// sweep-all.test.sh the row replaces (the removed-case map is L3 of odd/tasks/sweep-all-go.md). golden marks a
// world made of plain files and directories only, so it can be recorded in testdata/all/golden/cases.txt and
// replayed without bash. The declared differences from the script (L4) are not rows: they have no oracle and live
// in all_divergence_test.go.

type allScenario struct {
	name   string
	old    string
	setup  func(w *world)
	rc     int
	has    []string // substrings of stdout
	lacks  []string // substrings that stdout must not hold
	errHas []string // substrings of stderr
	golden bool
}

// allNames are the eight canonical scripts, in the order they must run. It is written out here on purpose: the
// Go list under test is compared with it (TestAllScriptsAreTheEight).
var allNames = []string{
	"sweep-retros.sh", "sweep-audits.sh", "sweep-breakthroughs.sh", "verify-registry.sh",
	"verify-kit-clean.sh", "sweep-tools.sh", "verify-tool-catalog.sh", "verify-skill-drift.sh",
}

// stub writes <kit>/toolbelt/<name>: a bash script with the given body, executable.
func (w *world) stub(name, body string) {
	w.t.Helper()
	p := w.kit + "/toolbelt/" + name
	w.put(p, "#!/usr/bin/env bash\n"+body+"\n")
	w.must(os.Chmod(p, 0o755))
}

// stubs writes every canonical script: it prints "stub:<name>" and exits with rcs[name] (0 by default).
func (w *world) stubs(rcs map[string]int) {
	w.t.Helper()
	for _, n := range allNames {
		w.stub(n, "echo stub:"+n+"\nexit "+strconv.Itoa(rcs[n]))
	}
}

// stubsExcept is stubs without the named scripts.
func (w *world) stubsExcept(rcs map[string]int, skip ...string) {
	w.t.Helper()
	w.stubs(rcs)
	for _, s := range skip {
		w.must(os.RemoveAll(w.kit + "/toolbelt/" + s))
	}
}

// banner is the block the script prints before a script's own output.
func banner(name string) string {
	bar := strings.Repeat("=", 40)
	return "\n" + bar + "\n== " + name + "\n" + bar + "\n"
}

// summaryHead is the block that opens the summary.
var summaryHead = "\n" + strings.Repeat("=", 40) + "\n== sweep-all summary\n" + strings.Repeat("=", 40) + "\n"

func allScenarios() []allScenario {
	retros, audits, last := allNames[0], allNames[1], allNames[7]
	all := func(s string) []string {
		var out []string
		for _, n := range allNames {
			out = append(out, strings.ReplaceAll(s, "{n}", n))
		}
		return out
	}
	return []allScenario{
		{name: "all eight pass", old: "3", golden: true, setup: func(w *world) { w.stubs(nil) },
			has:   append(all("PASS  {n}\n"), "  PASS  "+retros+"\n  PASS  "+audits+"\n", summaryHead),
			lacks: []string{"FAIL"}},
		{name: "each banner holds the script output", old: "6", golden: true, setup: func(w *world) { w.stubs(nil) },
			has: []string{banner(retros) + "stub:" + retros + "\n\nPASS  " + retros + "\n", banner(last) + "stub:" + last + "\n\nPASS  " + last + "\n"}},
		{name: "first script fails", old: "4", golden: true, setup: func(w *world) { w.stubs(map[string]int{retros: 1}) }, rc: 1,
			has:   []string{"\nFAIL  " + retros + " (exit 1)\n", "  FAIL  " + retros + " (exit 1)\n", "PASS  " + audits + "\n"},
			lacks: []string{"PASS  " + retros}},
		{name: "second script fails", old: "4", golden: true, setup: func(w *world) { w.stubs(map[string]int{audits: 1}) }, rc: 1,
			has: []string{"FAIL  " + audits + " (exit 1)\n", "PASS  " + retros + "\n", "PASS  " + last + "\n"}},
		{name: "last script fails with exit 3", old: "4", golden: true, setup: func(w *world) { w.stubs(map[string]int{last: 3}) }, rc: 1,
			has: []string{"FAIL  " + last + " (exit 3)\n", "PASS  " + retros + "\n"}},
		{name: "exit codes are reported as they are", old: "4", golden: true, rc: 1, setup: func(w *world) {
			w.stubs(map[string]int{retros: 2, audits: 7, allNames[2]: 125, allNames[3]: 126, allNames[4]: 127, allNames[5]: 255})
		}, has: []string{"FAIL  " + retros + " (exit 2)\n", "FAIL  " + audits + " (exit 7)\n", "(exit 125)\n", "(exit 126)\n", "(exit 127)\n", "(exit 255)\n"}},
		{name: "every script fails", old: "4", golden: true, rc: 1, setup: func(w *world) {
			rc := map[string]int{}
			for _, n := range allNames {
				rc[n] = 1
			}
			w.stubs(rc)
		}, has: all("  FAIL  {n} (exit 1)\n"), lacks: []string{"PASS"}},
		{name: "stderr is merged into stdout in order", old: "6", golden: true, setup: func(w *world) {
			w.stubs(nil)
			w.stub(audits, "echo one\necho two >&2\necho three\necho four >&2")
		}, has: []string{banner(audits) + "one\ntwo\nthree\nfour\n\nPASS  " + audits + "\n"}, errHas: nil},
		{name: "a script that prints only to stderr", old: "6", golden: true, setup: func(w *world) {
			w.stubs(nil)
			w.stub(audits, "echo only-err >&2")
		}, has: []string{banner(audits) + "only-err\n\nPASS  " + audits + "\n"}},
		{name: "output without a trailing newline", old: "6", golden: true, setup: func(w *world) {
			w.stubs(nil)
			w.stub(audits, "printf 'no newline'")
		}, has: []string{banner(audits) + "no newline\nPASS  " + audits + "\n"}},
		{name: "a silent script", old: "6", golden: true, setup: func(w *world) {
			w.stubs(nil)
			w.stub(audits, "exit 0")
		}, has: []string{banner(audits) + "\nPASS  " + audits + "\n"}},
		{name: "a failing script keeps its output", old: "4", golden: true, rc: 1, setup: func(w *world) {
			w.stubs(nil)
			w.stub(audits, "echo before\necho oops >&2\nexit 4")
		}, has: []string{banner(audits) + "before\noops\n\nFAIL  " + audits + " (exit 4)\n"}},
		{name: "scripts run in the caller's directory", old: "3", golden: true, setup: func(w *world) {
			w.stubs(nil)
			w.stub(audits, "pwd")
		}, has: []string{banner(audits) + "{root}\n"}},
		{name: "the environment reaches the scripts", old: "3", golden: true, setup: func(w *world) {
			w.stubs(nil)
			w.env["RSDD_ALL_TEST_VAR"] = "kept " + w.root
			w.stub(audits, "echo \"var=$RSDD_ALL_TEST_VAR\"")
		}, has: []string{"var=kept {root}\n"}},
		{name: "a script reads an empty stdin", old: "3", golden: true, setup: func(w *world) {
			w.stubs(nil)
			w.stub(audits, "n=$(cat | wc -c)\necho \"stdin=$((n))\"")
		}, has: []string{"stdin=0\n"}},
		{name: "a script is run by bash without the execute bit", old: "10", golden: true, setup: func(w *world) {
			w.stubs(nil)
			w.must(os.Chmod(w.kit+"/toolbelt/"+audits, 0o644))
		}, has: []string{"PASS  " + audits + "\n"}},
		{name: "first script is missing", old: "10", golden: true, rc: 1, setup: func(w *world) { w.stubsExcept(nil, retros) },
			errHas: []string{"FAIL  " + retros + " (script not found: {kit}/toolbelt/" + retros + ")\n"},
			has:    []string{banner(retros) + banner(audits) + "stub:" + audits, "  FAIL  " + retros + " (not found)\n", "PASS  " + last + "\n"}},
		{name: "last script is missing", old: "10", golden: true, rc: 1, setup: func(w *world) { w.stubsExcept(nil, last) },
			errHas: []string{"(script not found: {kit}/toolbelt/" + last + ")"}, has: []string{"  FAIL  " + last + " (not found)\n"}},
		{name: "no script exists", old: "10", golden: true, rc: 1, setup: func(w *world) {},
			errHas: all("FAIL  {n} (script not found: {kit}/toolbelt/{n})\n"), lacks: []string{"PASS"}, has: all("  FAIL  {n} (not found)\n")},
		{name: "a directory is not a script", old: "10", golden: true, rc: 1, setup: func(w *world) {
			w.stubsExcept(nil, audits)
			w.must(os.MkdirAll(w.kit+"/toolbelt/"+audits, 0o755))
		}, errHas: []string{"FAIL  " + audits + " (script not found: {kit}/toolbelt/" + audits + ")"}},
		{name: "a hanging script is killed and the rest run", old: "7", golden: true, rc: 1, setup: func(w *world) {
			w.stubs(nil)
			w.env["RSDD_SWEEP_TIMEOUT"] = "1"
			w.stub(audits, "echo before-hang\nsleep 30")
		}, has: []string{banner(audits) + "before-hang\n\nFAIL  " + audits + " (timed out after 1s)\n", "  FAIL  " + audits + " (timed out)\n", "PASS  " + allNames[2] + "\n", "PASS  " + last + "\n"}},
		{name: "a hanging grandchild is killed with its script", old: "7", golden: true, rc: 1, setup: func(w *world) {
			w.stubs(nil)
			w.env["RSDD_SWEEP_TIMEOUT"] = "1"
			w.stub(audits, "sleep 30 &\nwait")
		}, has: []string{"FAIL  " + audits + " (timed out after 1s)\n"}},
		{name: "a fractional timeout", old: "8", golden: true, rc: 1, setup: func(w *world) {
			w.stubs(nil)
			w.env["RSDD_SWEEP_TIMEOUT"] = "0.5"
			w.stub(audits, "sleep 30")
		}, has: []string{"FAIL  " + audits + " (timed out after 0.5s)\n"}},
		{name: "a script within the timeout passes", old: "7", golden: true, setup: func(w *world) {
			w.stubs(nil)
			w.env["RSDD_SWEEP_TIMEOUT"] = "5"
			w.stub(audits, "sleep 0.1\necho slept")
		}, has: []string{"slept\n\nPASS  " + audits + "\n"}},
		{name: "an empty timeout means the default", old: "7", golden: true, setup: func(w *world) {
			w.stubs(nil)
			w.env["RSDD_SWEEP_TIMEOUT"] = ""
		}, has: all("PASS  {n}\n")},
	}
}

// expand replaces {root} and {kit} in an expectation.
func (w *world) expandAll(s string) string {
	return strings.NewReplacer("{root}", w.root, "{kit}", w.kit).Replace(s)
}

func TestAllScenarios(t *testing.T) {
	for _, sc := range allScenarios() {
		t.Run(sc.name, func(t *testing.T) {
			w := newWorld(t)
			sc.setup(w)
			r := w.runAll()
			if r.rc != sc.rc {
				t.Errorf("exit code %d, want %d\nstdout:\n%s\nstderr:\n%s", r.rc, sc.rc, r.out, r.err)
			}
			for _, h := range sc.has {
				if !strings.Contains(r.out, w.expandAll(h)) {
					t.Errorf("stdout lacks %q\nstdout:\n%s", w.expandAll(h), r.out)
				}
			}
			for _, h := range sc.lacks {
				if strings.Contains(r.out, h) {
					t.Errorf("stdout holds %q\nstdout:\n%s", h, r.out)
				}
			}
			for _, h := range sc.errHas {
				if !strings.Contains(r.err, w.expandAll(h)) {
					t.Errorf("stderr lacks %q\nstderr:\n%s", w.expandAll(h), r.err)
				}
			}
			if len(sc.errHas) == 0 && r.err != "" {
				t.Errorf("stderr is not empty: %q", r.err)
			}
		})
	}
}
