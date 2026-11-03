//go:build unix

package install

import (
	"flag"
	"os"
	"strconv"
	"strings"
	"testing"
)

// The all-MISSING report is the exact text a host with none of the tools prints; the fixed host paths are relocated
// under the fixture root so the real machine never leaks in. The golden pins every section header, row label, row
// order, column width and message in one comparison. It is Go output checked against the frozen script by
// TestDiffAllMissing on a host with the same absences, and read line by line when it was recorded (-update-golden).
var updateGolden = flag.Bool("update-golden", false, "rewrite testdata/golden from the current output")

const goldenAllMissing = "testdata/golden/all-missing.txt"

func TestAllMissingGolden(t *testing.T) {
	e := newDT(t)
	got := strings.ReplaceAll(e.report(), e.root, "<ROOT>")
	if *updateGolden {
		if err := os.WriteFile(goldenAllMissing, []byte(got), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	want, err := os.ReadFile(goldenAllMissing)
	if err != nil {
		t.Fatalf("golden unreadable (an absent golden proves nothing): %v", err)
	}
	if string(want) != got {
		t.Errorf("all-missing report differs from %s\n%s", goldenAllMissing, firstDiff(string(want), got))
	}
}

// firstDiff names the first line on which the two texts differ.
func firstDiff(a, b string) string {
	al, bl := strings.Split(a, "\n"), strings.Split(b, "\n")
	for i := 0; i < len(al) || i < len(bl); i++ {
		var x, y string
		if i < len(al) {
			x = al[i]
		}
		if i < len(bl) {
			y = bl[i]
		}
		if x != y {
			return "line " + strconv.Itoa(i+1) + "\n first:  " + x + "\n second: " + y
		}
	}
	return "identical"
}
