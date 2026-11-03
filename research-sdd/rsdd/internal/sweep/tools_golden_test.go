package sweep

import (
	"os"
	"strings"
	"testing"
)

// testdata/tools/golden/cases.txt is the recorded behaviour of the frozen scripts: for every scenario of
// tools_scenarios_test.go marked golden, the world it builds and what sweep-tools.sh and sweep-tools-hook.sh
// printed there. This file replays the golden against the Go command without bash, so it also runs under
// -tags nodiff; tools_golden_diff_test.go (!nodiff) records it and checks it against the live frozen scripts,
// which is what keeps it honest. The frame format, the parser and the world builder are the ones of the audit
// golden (audits_golden_test.go); the hook has no --full, so its hookfull frame stays empty.
//
// The file is regenerated whole by `go test -run TestUpdateToolsGolden -update-tools` (every golden scenario,
// whatever -run says), never by hand. A scenario with unreadable files carries them as an @@env frame
// (RSDD_TOOLS_TEST_UNREADABLE): the recording chmods them for the script, the replay reads them through the
// readFunc seam.

const toolGoldPath = "testdata/tools/golden/cases.txt"

func readToolGold(t testing.TB) []auditGold {
	t.Helper()
	b, err := os.ReadFile(toolGoldPath)
	if err != nil {
		t.Fatal(err)
	}
	return parseAuditGold(t, b)
}

func goldenToolScenarios() []toolScenario {
	var out []toolScenario
	for _, sc := range toolScenarios() {
		if sc.golden {
			out = append(out, sc)
		}
	}
	return out
}

func TestToolsGoldenReplay(t *testing.T) {
	for _, c := range readToolGold(t) {
		t.Run(c.name, func(t *testing.T) {
			w := newWorld(t)
			c.build(w)
			r := w.runTools()
			if r.rc != c.rc || r.out != c.want(w, c.out) || r.err != c.want(w, c.err) {
				t.Errorf("report: rc=%d want %d\nstdout:\n%s\nwant:\n%s\nstderr:\n%s\nwant:\n%s", r.rc, c.rc, r.out, c.want(w, c.out), r.err, c.want(w, c.err))
			}
			h := w.runToolsHook()
			if h.rc != 0 || h.err != "" || h.out != c.want(w, c.hook) {
				t.Errorf("hook: rc=%d stderr=%q\ngot:\n%s\nwant:\n%s", h.rc, h.err, h.out, c.want(w, c.hook))
			}
		})
	}
}

// A golden that lost a case, or kept one whose scenario is gone, must fail: an update that was filtered or
// aborted half-way would otherwise replay a shorter corpus and pass.
func TestToolsGoldenIsComplete(t *testing.T) {
	cases := readToolGold(t)
	want := goldenToolScenarios()
	if len(cases) != len(want) {
		t.Fatalf("golden holds %d cases, the scenario table marks %d golden: regenerate with -update-tools", len(cases), len(want))
	}
	for i, c := range cases {
		if c.name != want[i].name {
			t.Errorf("golden case %d is %q, the table has %q", i, c.name, want[i].name)
		}
	}
	if len(cases) < 25 {
		t.Errorf("the golden holds %d cases; a truncated golden must fail, not pass", len(cases))
	}
}

// The corpus is meaningful: it holds each line the census can print and each hook headline it can emit, so a
// golden recorded from a broken script cannot silently drop one (CLAUDE.md section 7).
func TestToolsGoldenCoverage(t *testing.T) {
	var out, hook strings.Builder
	for _, c := range readToolGold(t) {
		out.WriteString(c.out + c.err)
		hook.WriteString(c.hook)
	}
	for _, want := range []string{"TARGET  ", "        tools: ", " library module(s) not counted as tools)", " non-tool file(s) in tools/ not counted)",
		"INFO: no tools/ directory (empty-input)\n", "INFO: tools/ directory exists but is empty (empty-input)\n",
		"   WARN: 1 retro(s) unreadable during T-row scan (grep error)\n", "WARN: tools/README.md scan FAILED (grep error) — ledger count unavailable\n",
		"WARN: tools/README.md has no table — ledger unreadable\n", "recorded (retro): ", "recorded (ledger): ",
		"  ·  no retros found\n", "  ·  no retro has a tools table\n", "\nSummary: ", "INFO: corpus not found (absent-input): ",
		"target(s) not traversed (absent-input)", "WARN: 1 target(s) skipped", "PARTIAL: ",
		"sweep-tools: cannot find ", "sweep-tools: ERROR — no usable target paths in "} {
		if !strings.Contains(out.String(), want) {
			t.Errorf("no golden case prints %q", want)
		}
	}
	for _, want := range []string{"Research-SDD tool ledger (unrecorded tools found):", "Research-SDD tool ledger (targets not traversed):",
		"Research-SDD tools sweep could not run (exit 1 — check TARGETS.md and lib/ helper):", toolsHookBreakdown} {
		if !strings.Contains(hook.String(), want) {
			t.Errorf("no golden hook output holds %q", want)
		}
	}
}
