//go:build unix && !nodiff

package sweep

import (
	"flag"
	"os"
	"strings"
	"testing"
)

var updateTools = flag.Bool("update-tools", false, "rewrite testdata/tools/golden/cases.txt from the frozen scripts")

// recordTools runs the frozen scripts in the world and notes what they printed. The hook has no --full.
func (w *world) recordTools(c *auditGold) {
	w.t.Helper()
	norm := func(s string) string { return strings.ReplaceAll(s, w.root, "{root}") }
	r := w.bashTools("sweep-tools.sh")
	c.rc, c.out, c.err = r.rc, norm(r.out), norm(r.err)
	h := w.bashTools("sweep-tools-hook.sh")
	if h.rc != 0 || h.err != "" {
		w.t.Fatalf("a hook must exit 0 with an empty stderr: %+v", h)
	}
	c.hook = norm(h.out)
}

// TestUpdateToolsGolden rewrites the whole golden from the frozen scripts (run with -update-tools). It is one
// flat test, not a table of subtests, so a -run filter cannot regenerate a part of the corpus.
func TestUpdateToolsGolden(t *testing.T) {
	if !*updateTools {
		t.Skip("run with -update-tools to regenerate the golden from the frozen scripts")
	}
	var cases []auditGold
	for _, sc := range goldenToolScenarios() {
		w := newWorld(t)
		sc.setup(w)
		c := snapshotAuditGold(w, sc.name)
		w.recordTools(&c)
		cases = append(cases, c)
	}
	if err := os.WriteFile(toolGoldPath, formatAuditGold(cases), 0o644); err != nil {
		t.Fatal(err)
	}
}

// TestToolsGoldenDifferential runs every golden world through the frozen scripts again and compares with what
// the golden holds: the golden is what the scripts printed, and this is what keeps it honest.
func TestToolsGoldenDifferential(t *testing.T) {
	for _, c := range readToolGold(t) {
		t.Run(c.name, func(t *testing.T) {
			t.Parallel()
			w := newWorld(t)
			c.build(w)
			got := auditGold{}
			w.recordTools(&got)
			if got.rc != c.rc || got.out != c.out || got.err != c.err || got.hook != c.hook {
				t.Errorf("the frozen scripts print something else than the golden\nrc %d want %d\nstdout:\n%s\nwant:\n%s\nstderr:\n%s\nwant:\n%s\nhook:\n%s\nwant:\n%s",
					got.rc, c.rc, got.out, c.out, got.err, c.err, got.hook, c.hook)
			}
		})
	}
}
