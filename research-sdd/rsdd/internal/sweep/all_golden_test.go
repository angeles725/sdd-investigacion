package sweep

import (
	"os"
	"strings"
	"testing"
)

// testdata/all/golden/cases.txt is the recorded behaviour of the frozen script: for every scenario of
// all_scenarios_test.go marked golden, the world it builds (the stub scripts of a toolbelt, each file with its
// age) and what sweep-all.sh printed there. This file replays the golden against the Go command without bash, so
// it also runs under -tags nodiff; all_golden_diff_test.go (!nodiff) records it and checks it against the live
// frozen script, which is what keeps it honest. The frame format, the parser and the world builder are the ones of
// the audit golden (audits_golden_test.go); the script has no hook, so its hook frames stay empty.
//
// The file is regenerated whole by `go test -run TestUpdateAllGolden -update-all` (every golden scenario,
// whatever -run says), never by hand.

const allGoldPath = "testdata/all/golden/cases.txt"

func readAllGold(t testing.TB) []auditGold {
	t.Helper()
	b, err := os.ReadFile(allGoldPath)
	if err != nil {
		t.Fatal(err)
	}
	return parseAuditGold(t, b)
}

func goldenAllScenarios() []allScenario {
	var out []allScenario
	for _, sc := range allScenarios() {
		if sc.golden {
			out = append(out, sc)
		}
	}
	return out
}

func TestAllGoldenReplay(t *testing.T) {
	for _, c := range readAllGold(t) {
		t.Run(c.name, func(t *testing.T) {
			w := newWorld(t)
			c.build(w)
			r := w.runAll()
			if r.rc != c.rc || r.out != c.want(w, c.out) || r.err != c.want(w, c.err) {
				t.Errorf("rc=%d want %d\nstdout:\n%s\nwant:\n%s\nstderr:\n%s\nwant:\n%s", r.rc, c.rc, r.out, c.want(w, c.out), r.err, c.want(w, c.err))
			}
		})
	}
}

// A golden that lost a case, or kept one whose scenario is gone, must fail: an update that was filtered or
// aborted half-way would otherwise replay a shorter corpus and pass.
func TestAllGoldenIsComplete(t *testing.T) {
	cases := readAllGold(t)
	want := goldenAllScenarios()
	if len(cases) != len(want) {
		t.Fatalf("golden holds %d cases, the scenario table marks %d golden: regenerate with -update-all", len(cases), len(want))
	}
	for i, c := range cases {
		if c.name != want[i].name {
			t.Errorf("golden case %d is %q, the table has %q", i, c.name, want[i].name)
		}
	}
	if len(cases) < 20 {
		t.Errorf("the golden holds %d cases; a truncated golden must fail, not pass", len(cases))
	}
}

// The corpus is meaningful: it holds each line the aggregator can print, so a golden recorded from a broken
// script cannot silently drop one (CLAUDE.md section 7).
func TestAllGoldenCoverage(t *testing.T) {
	var out, err strings.Builder
	for _, c := range readAllGold(t) {
		out.WriteString(c.out)
		err.WriteString(c.err)
	}
	for _, want := range []string{"\n== sweep-all summary\n", "\nPASS  sweep-retros.sh\n", "\nFAIL  sweep-audits.sh (exit 1)\n",
		"\nFAIL  sweep-audits.sh (timed out after 1s)\n", "\nFAIL  sweep-audits.sh (timed out after 0.5s)\n", "  PASS  verify-skill-drift.sh\n",
		"  FAIL  sweep-retros.sh (not found)\n", "  FAIL  sweep-audits.sh (timed out)\n", "  FAIL  sweep-audits.sh (exit 7)\n"} {
		if !strings.Contains(out.String(), want) {
			t.Errorf("no golden case prints %q on stdout", want)
		}
	}
	if !strings.Contains(err.String(), "FAIL  sweep-retros.sh (script not found: {root}/kit/toolbelt/sweep-retros.sh)\n") {
		t.Errorf("no golden case prints the not-found banner on stderr")
	}
}
