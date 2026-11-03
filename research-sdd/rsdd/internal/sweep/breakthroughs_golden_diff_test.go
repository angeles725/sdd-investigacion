//go:build unix && !nodiff

package sweep

import (
	"flag"
	"os"
	"strings"
	"testing"
)

var updateBT = flag.Bool("update-breakthroughs", false, "rewrite testdata/breakthroughs/golden/cases.txt from the frozen scripts")

// recordBT runs the frozen scripts in the world and notes what they printed. The hook is recorded with and without --full.
func (w *world) recordBT(c *auditGold) {
	w.t.Helper()
	norm := func(s string) string { return strings.ReplaceAll(s, w.root, "{root}") }
	r := w.bashBT("sweep-breakthroughs.sh")
	c.rc, c.out, c.err = r.rc, norm(r.out), norm(r.err)
	h := w.bashBT("sweep-breakthroughs-hook.sh")
	if h.rc != 0 || h.err != "" {
		w.t.Fatalf("a hook must exit 0 with an empty stderr: %+v", h)
	}
	hf := w.bashBT("sweep-breakthroughs-hook.sh", "--full")
	if hf.rc != 0 || hf.err != "" {
		w.t.Fatalf("a hook --full must exit 0 with an empty stderr: %+v", hf)
	}
	c.hook, c.hookFull = norm(h.out), norm(hf.out)
}

// TestUpdateBreakthroughsGolden rewrites the whole golden from the frozen scripts (run with -update-breakthroughs). It is one
// flat test, not a table of subtests, so a -run filter cannot regenerate a part of the corpus.
func TestUpdateBreakthroughsGolden(t *testing.T) {
	if !*updateBT {
		t.Skip("run with -update-breakthroughs to regenerate the golden from the frozen scripts")
	}
	var cases []auditGold
	for _, sc := range goldenBTScenarios() {
		w := newWorld(t)
		sc.setup(w)
		c := snapshotAuditGold(w, sc.name)
		w.recordBT(&c)
		cases = append(cases, c)
	}
	if err := os.WriteFile(btGoldPath, formatAuditGold(cases), 0o644); err != nil {
		t.Fatal(err)
	}
}

// TestBreakthroughsGoldenDifferential runs every golden world through the frozen scripts again and compares with what
// the golden holds: the golden is what the scripts printed, and this is what keeps it honest.
func TestBreakthroughsGoldenDifferential(t *testing.T) {
	for _, c := range readBTGold(t) {
		t.Run(c.name, func(t *testing.T) {
			w := newWorld(t)
			c.build(w)
			got := auditGold{}
			w.recordBT(&got)
			if got.rc != c.rc || got.out != c.out || got.err != c.err || got.hook != c.hook || got.hookFull != c.hookFull {
				t.Errorf("the frozen scripts print something else than the golden\nrc %d want %d\nstdout:\n%s\nwant:\n%s\nstderr:\n%s\nwant:\n%s\nhook:\n%s\nwant:\n%s",
					got.rc, c.rc, got.out, c.out, got.err, c.err, got.hook, c.hook)
			}
		})
	}
}
