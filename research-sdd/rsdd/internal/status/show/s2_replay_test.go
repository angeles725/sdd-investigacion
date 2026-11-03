package show

import (
	"fmt"
	"os"
	"strings"
	"testing"
)

const goldenS2 = goldenS2Dir + "s2.golden"

// TestReplayS2 replays the frozen oracle outputs (testdata/golden/s2.golden, generated from the frozen excerpts of
// research-sdd-status.sh by the differential test) through the Go port. It runs without bash, so a mutant of the
// port dies here under -tags nodiff.
func TestReplayS2(t *testing.T) {
	golden := parseGolden(t, goldenS2)
	scs := s2Scenarios()
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

// firstDiff names the first line where two renderings differ.
func firstDiff(want, got string) string {
	w, g := strings.Split(want, "\n"), strings.Split(got, "\n")
	for i := 0; i < len(w) || i < len(g); i++ {
		var a, b string
		if i < len(w) {
			a = w[i]
		}
		if i < len(g) {
			b = g[i]
		}
		if a != b {
			return fmt.Sprintf("line %d: want %q, got %q", i+1, a, b)
		}
	}
	return "no difference"
}
