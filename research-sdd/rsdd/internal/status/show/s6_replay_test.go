package show

import (
	"os"
	"strings"
	"testing"
)

// TestReplayS6 replays the frozen oracle outputs (testdata/golden/s6.golden, generated from the frozen script by the
// differential test) through the Go port: every run's rc, stdout and stderr, the tree it leaves, and the
// subprocesses it starts (the visibility probe and verify-state). The port's children are answered in process from
// the scenario's spec, so it runs without bash and a mutant of the port dies here under -tags nodiff.
func TestReplayS6(t *testing.T) {
	golden := parseGolden(t, goldenS6)
	scs := s6Scenarios()
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
			calls := &s6Calls{}
			tb := t.TempDir()
			e := s5Env{environ: sc.environ(root, t.TempDir(), "/nonexistent-bin"), toolbelt: tb}
			outs := runGoS6(t, sc, root, e, &s6Replay{root: root, calls: calls})
			got := renderS6(t, sc, outs, root, tb, *calls)
			if got != want {
				t.Errorf("replay differs at %s\nwant:\n%s\ngot:\n%s", firstDiff(want, got), want, got)
			}
			// The intent guard: a scenario that was written to reach a line reaches it.
			if sc.want != "" && !strings.Contains(strings.ReplaceAll(outs[0].out, root, "<ROOT>"), sc.want) {
				t.Errorf("scenario meant to print %q, printed %q", sc.want, outs[0].out)
			}
		})
	}
}

// The golden is keyed by scenario name, so a duplicate would silently shadow a case.
func TestS6ScenarioNamesAreUnique(t *testing.T) {
	seen := map[string]bool{}
	for _, sc := range s6Scenarios() {
		if seen[sc.name] {
			t.Errorf("duplicate scenario name %s", sc.name)
		}
		seen[sc.name] = true
	}
}
