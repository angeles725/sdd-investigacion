package show

import (
	"os"
	"strings"
	"testing"
)

// TestReplayS4 replays the frozen oracle outputs (testdata/golden/s4.golden, generated from the frozen script by
// the differential test) through the Go port: every invocation's rc, stdout and stderr, and the tree it leaves.
// It runs without bash, so a mutant of the port dies here under -tags nodiff.
func TestReplayS4(t *testing.T) {
	golden := parseGolden(t, goldenS4)
	scs := s4Scenarios()
	if len(golden) != len(scs) {
		t.Fatalf("golden has %d scenarios, the table %d", len(golden), len(scs))
	}
	for _, sc := range scs {
		t.Run(sc.name, func(t *testing.T) {
			if sc.needsUser && os.Geteuid() == 0 {
				t.Skip("mode-000 files are readable by root")
			}
			want, ok := golden[sc.name]
			if !ok {
				t.Fatalf("no golden section for %s", sc.name)
			}
			root := sc.build(t)
			var calls []verifyCall
			outs := runGoS4(t, sc, root, replayEnv(parseVerifyBlock(t, want), root, &calls))
			got := renderS4(t, sc, outs, root, calls)
			if got != want {
				t.Errorf("replay differs at %s\nwant:\n%s\ngot:\n%s", firstDiff(want, got), want, got)
			}
			// The intent guard: a scenario that was written to reach a verdict reaches it, so the golden
			// cannot silently record a STALE where a NEXT was meant.
			if sc.want != "" && !strings.Contains(strings.ReplaceAll(outs[0].out, root, "<ROOT>"), sc.want) {
				t.Errorf("scenario meant to print %q, printed %q", sc.want, outs[0].out)
			}
		})
	}
}

// The golden is keyed by scenario name, so a duplicate would silently shadow a case.
func TestS4ScenarioNamesAreUnique(t *testing.T) {
	seen := map[string]bool{}
	for _, sc := range s4Scenarios() {
		if seen[sc.name] {
			t.Errorf("duplicate scenario name %s", sc.name)
		}
		seen[sc.name] = true
	}
}
