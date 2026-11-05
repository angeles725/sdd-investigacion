//go:build unix && !nodiff

package sweep

import (
	"flag"
	"os"
	"strings"
	"testing"
)

var updateAll = flag.Bool("update-all", false, "rewrite testdata/all/golden/cases.txt from the frozen script")

// recordAll runs the frozen script in the world and notes what it printed.
func (w *world) recordAll(c *auditGold) {
	w.t.Helper()
	r := w.bashAll()
	norm := func(s string) string { return strings.ReplaceAll(s, w.root, "{root}") }
	c.rc, c.out, c.err = r.rc, norm(r.out), norm(r.err)
}

// TestUpdateAllGolden rewrites the whole golden from the frozen script (run with -update-all). It is one flat
// test, not a table of subtests, so a -run filter cannot regenerate a part of the corpus.
func TestUpdateAllGolden(t *testing.T) {
	if !*updateAll {
		t.Skip("run with -update-all to regenerate the golden from the frozen script")
	}
	var cases []auditGold
	for _, sc := range goldenAllScenarios() {
		w := newWorld(t)
		sc.setup(w)
		c := snapshotAuditGold(w, sc.name)
		w.recordAll(&c)
		cases = append(cases, c)
	}
	if err := os.WriteFile(allGoldPath, formatAuditGold(cases), 0o644); err != nil {
		t.Fatal(err)
	}
}

// TestAllGoldenDifferential runs every golden world through the frozen script again and compares with what the
// golden holds: the golden is what the script printed, and this is what keeps it honest.
func TestAllGoldenDifferential(t *testing.T) {
	for _, c := range readAllGold(t) {
		t.Run(c.name, func(t *testing.T) {
			w := newWorld(t)
			c.build(w)
			got := auditGold{}
			w.recordAll(&got)
			if got.rc != c.rc || got.out != c.out || got.err != c.err {
				t.Errorf("the frozen script prints something else than the golden\nrc %d want %d\nstdout:\n%s\nwant:\n%s\nstderr:\n%s\nwant:\n%s",
					got.rc, c.rc, got.out, c.out, got.err, c.err)
			}
		})
	}
}
