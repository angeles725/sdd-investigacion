package show

import (
	"os"
	"testing"
)

// TestReplayS3 replays the frozen oracle outputs (testdata/golden/s3.golden, generated from the frozen script by
// the differential test) through the Go port: every invocation's rc, stdout and stderr, and the tree it leaves.
// It runs without bash, so a mutant of the port dies here under -tags nodiff.
func TestReplayS3(t *testing.T) {
	golden := parseGolden(t, goldenS3)
	scs := s3Scenarios()
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
			got := renderS3(t, sc, runGoS3(t, sc, root), root)
			if got != want {
				t.Errorf("replay differs at %s\nwant:\n%s\ngot:\n%s", firstDiff(want, got), want, got)
			}
		})
	}
}

// The golden is keyed by scenario name, so a duplicate would silently shadow a case.
func TestS3ScenarioNamesAreUnique(t *testing.T) {
	seen := map[string]bool{}
	for _, sc := range s3Scenarios() {
		if seen[sc.name] {
			t.Errorf("duplicate scenario name %s", sc.name)
		}
		seen[sc.name] = true
	}
}
