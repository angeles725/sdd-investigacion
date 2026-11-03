//go:build unix && !nodiff

package install

import (
	"os"
	"strings"
	"testing"
)

// The golden (Go output, fixed host paths relocated) must read like the frozen script's report: every line of the
// legacy output equals the golden's, except the rows the host really resolves, which keep their label column. It is
// the independent anchor of the golden: the text is checked against the oracle, not only against itself.
func TestDiffAllMissingGoldenMatchesLegacy(t *testing.T) {
	e := newDiff(t)
	l := e.legacy()
	golden, err := os.ReadFile(goldenAllMissing)
	if err != nil {
		t.Fatal(err)
	}
	var legacy []string
	for _, ln := range strings.Split(strings.ReplaceAll(maskDate(l.out), e.root, "<ROOT>"), "\n") {
		if !strings.HasPrefix(ln, "  ") || len(ln) < 31 || ln[25:29] != "WARN" { // binwalk notes exist only on hosts with binwalk
			legacy = append(legacy, ln)
		}
	}
	want := strings.Split(maskDate(string(golden)), "\n")
	if len(legacy) != len(want) {
		t.Fatalf("legacy report has %d lines, golden %d\n%s", len(legacy), len(want), firstDiff(strings.Join(want, "\n"), strings.Join(legacy, "\n")))
	}
	for i := range want {
		if legacy[i] == want[i] || (i == 1 && strings.HasSuffix(legacy[i], "· date: <D> · brew: <ROOT>/brew")) { // uname is the host's
			continue
		}
		isRow := strings.HasPrefix(want[i], "  ") && len(want[i]) > 24 && len(legacy[i]) > 24
		if !isRow || legacy[i][:24] != want[i][:24] {
			t.Errorf("line %d\n legacy: %q\n golden: %q", i+1, legacy[i], want[i])
		}
	}
}
