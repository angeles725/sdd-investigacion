package show

import (
	"os"
	"testing"
)

// TestReplayBlockedOpen replays the oracle outputs of blocked_open_count (testdata/golden/s3-blocked.golden)
// through the Go port. No bash is needed, so a mutant of the port dies here under -tags nodiff.
func TestReplayBlockedOpen(t *testing.T) {
	golden := parseGolden(t, goldenBlockedOpen)
	scs := blockedOpenScenarios()
	if len(golden) != len(scs) {
		t.Fatalf("golden has %d scenarios, the table %d", len(golden), len(scs))
	}
	for _, sc := range scs {
		t.Run(sc.name, func(t *testing.T) {
			if sc.unreadable && os.Geteuid() == 0 {
				t.Skip("mode-000 files are readable by root")
			}
			want, ok := golden[sc.name]
			if !ok {
				t.Fatalf("no golden section for %s", sc.name)
			}
			root := sc.build(t)
			got := renderS2(sc, runGoOps(t, sc, root), root)
			if got != want {
				t.Errorf("replay differs at %s\nwant:\n%s\ngot:\n%s", firstDiff(want, got), want, got)
			}
		})
	}
}

// The golden is keyed by scenario name, so a duplicate would silently shadow a case.
func TestBlockedOpenScenarioNamesAreUnique(t *testing.T) {
	seen := map[string]bool{}
	for _, sc := range blockedOpenScenarios() {
		if seen[sc.name] {
			t.Errorf("duplicate scenario name %s", sc.name)
		}
		seen[sc.name] = true
	}
}
