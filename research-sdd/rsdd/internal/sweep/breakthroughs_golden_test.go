package sweep

import (
	"os"
	"strings"
	"testing"
)

// testdata/breakthroughs/golden/cases.txt is the recorded behaviour of the frozen scripts: for every scenario of
// breakthroughs_scenarios_test.go marked golden, the world it builds and what sweep-breakthroughs.sh and sweep-breakthroughs-hook.sh
// printed there. This file replays the golden against the Go command without bash, so it also runs under
// -tags nodiff; breakthroughs_golden_diff_test.go (!nodiff) records it and checks it against the live frozen scripts,
// which is what keeps it honest. The frame format, the parser and the world builder are the ones of the audit
// golden (audits_golden_test.go); the hook is recorded with and without --full.
//
// The file is regenerated whole by `go test -run TestUpdateBreakthroughsGolden -update-breakthroughs` (every golden scenario,
// whatever -run says), never by hand. A scenario with unreadable files carries them as an @@env frame
// (RSDD_TOOLS_TEST_UNREADABLE): the recording chmods them for the script, the replay reads them through the
// readFunc seam.

const btGoldPath = "testdata/breakthroughs/golden/cases.txt"

func readBTGold(t testing.TB) []auditGold {
	t.Helper()
	b, err := os.ReadFile(btGoldPath)
	if err != nil {
		t.Fatal(err)
	}
	return parseAuditGold(t, b)
}

func goldenBTScenarios() []btScenario {
	var out []btScenario
	for _, sc := range btScenarios() {
		if sc.golden {
			out = append(out, sc)
		}
	}
	return out
}

func TestBreakthroughsGoldenReplay(t *testing.T) {
	for _, c := range readBTGold(t) {
		t.Run(c.name, func(t *testing.T) {
			w := newWorld(t)
			c.build(w)
			r := w.runBT()
			if r.rc != c.rc || r.out != c.want(w, c.out) || r.err != c.want(w, c.err) {
				t.Errorf("report: rc=%d want %d\nstdout:\n%s\nwant:\n%s\nstderr:\n%s\nwant:\n%s", r.rc, c.rc, r.out, c.want(w, c.out), r.err, c.want(w, c.err))
			}
			for _, h := range []struct {
				what, want string
				args       []string
			}{{"hook", c.hook, nil}, {"hook --full", c.hookFull, []string{"--full"}}} {
				r := w.runBTHook(h.args...)
				if r.rc != 0 || r.err != "" || r.out != c.want(w, h.want) {
					t.Errorf("%s: rc=%d stderr=%q\ngot:\n%s\nwant:\n%s", h.what, r.rc, r.err, r.out, c.want(w, h.want))
				}
			}
		})
	}
}

// A golden that lost a case, or kept one whose scenario is gone, must fail: an update that was filtered or
// aborted half-way would otherwise replay a shorter corpus and pass.
func TestBreakthroughsGoldenIsComplete(t *testing.T) {
	cases := readBTGold(t)
	want := goldenBTScenarios()
	if len(cases) != len(want) {
		t.Fatalf("golden holds %d cases, the scenario table marks %d golden: regenerate with -update-breakthroughs", len(cases), len(want))
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
func TestBreakthroughsGoldenCoverage(t *testing.T) {
	var out, hook, hookFull strings.Builder
	for _, c := range readBTGold(t) {
		out.WriteString(c.out + c.err)
		hook.WriteString(c.hook)
		hookFull.WriteString(c.hookFull)
	}
	for _, want := range []string{"INFO: corpus not found (absent-input): ", "INFO: corpus exists, no block files (empty-input): ",
		"INFO: no tagged breakthroughs in corpus (no-match — expected while back-fill pending): ", "WARN: unindexed breakthrough — tagged block not in BREAKTHROUGHS.md: ",
		"WARN: drift — indexed block file no longer exists: ", "WARN: drift — indexed block no longer carries the **Breakthrough:** marker: ",
		"WARN: drift — indexed line does not carry the **Breakthrough:** marker (block still has it elsewhere): ",
		"WARN: block file unreadable, marker scan skipped: ", "\nSummary: ", "target(s) not traversed (absent-input)", "WARN: 1 target(s) skipped", "PARTIAL: ",
		"Ledger consistent — all tagged breakthroughs indexed, no drift.\n", "For each unindexed breakthrough: ", "For each drifted row: ",
		"sweep-breakthroughs: cannot find ", "sweep-breakthroughs: ERROR — no usable target paths in ", "sweep-breakthroughs: check TARGETS.md has"} {
		if !strings.Contains(out.String(), want) {
			t.Errorf("no golden case prints %q", want)
		}
	}
	for _, want := range []string{btHookHeader, "Research-SDD breakthroughs sweep could not run (exit 1 — check TARGETS.md and lib/ helper):",
		"unindexed breakthrough(s) not in BREAKTHROUGHS.md: ", ", +2 more — add a row each", "corpus(es) empty-input, ", "corpus(es) no-match — run --full", "corpus(es) empty-input — run --full",
		"run --full to list them."} {
		if !strings.Contains(hook.String(), want) {
			t.Errorf("no golden hook output holds %q", want)
		}
	}
	if !strings.Contains(hookFull.String(), "INFO: corpus not found (absent-input): ") {
		t.Error("no golden --full hook output keeps a per-target absent-input line")
	}
}
