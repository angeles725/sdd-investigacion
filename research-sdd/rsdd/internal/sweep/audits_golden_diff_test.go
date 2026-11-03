//go:build unix && !nodiff

package sweep

import (
	"flag"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
	"time"
)

var updateAudits = flag.Bool("update-audits", false, "rewrite testdata/audits/golden/cases.txt from the frozen scripts")

// baseEnvKeys are the variables newWorld sets itself; every other variable of a scenario is part of the case.
var baseEnvKeys = map[string]bool{"PATH": true, "HOME": true, "LC_ALL": true, "GIT_CONFIG_GLOBAL": true, "GIT_CONFIG_NOSYSTEM": true,
	"RSDD_HOOK_WIRING_CEILING": true, "RSDD_CLAUDE_PROJECTS_DIR": true}

// snapshotAuditGold records the world of a scenario: its directories and regular files with their age. The
// sandbox scaffolding (home, the empty toolbelt) is part of every world already. A symbolic link or a special
// file cannot be recorded, so a scenario that holds one must not be marked golden.
func snapshotAuditGold(w *world, name string) auditGold {
	w.t.Helper()
	c := auditGold{name: name}
	w.must(filepath.WalkDir(w.root, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(w.root, p)
		if rel == "." || rel == "home" || rel == "kit" || rel == "kit/toolbelt" {
			return nil
		}
		switch {
		case d.IsDir():
			c.dirs = append(c.dirs, rel)
		case d.Type().IsRegular():
			b, err := os.ReadFile(p)
			if err != nil {
				return err
			}
			st, err := os.Stat(p)
			if err != nil {
				return err
			}
			age := int64(w.now.Sub(st.ModTime()) / time.Second)
			if age < 0 {
				age = 0
			}
			c.files = append(c.files, auditGoldFile{rel: rel, age: age, data: []byte(strings.ReplaceAll(string(b), w.root, "{root}"))})
		default:
			w.t.Fatalf("scenario %q holds %s, which a golden cannot record: drop golden from it", name, rel)
		}
		return nil
	}))
	var keys []string
	for k := range w.env {
		if !baseEnvKeys[k] {
			keys = append(keys, k)
		}
	}
	sort.Strings(keys)
	for _, k := range keys {
		c.env = append(c.env, [2]string{k, strings.ReplaceAll(w.env[k], w.root, "{root}")})
	}
	return c
}

func (w *world) record(c *auditGold) {
	w.t.Helper()
	norm := func(s string) string { return strings.ReplaceAll(s, w.root, "{root}") }
	r := w.bashAudits("sweep-audits.sh")
	c.rc, c.out, c.err = r.rc, norm(r.out), norm(r.err)
	h := w.bashAudits("sweep-audits-hook.sh")
	hf := w.bashAudits("sweep-audits-hook.sh", "--full")
	if h.rc != 0 || hf.rc != 0 || h.err != "" || hf.err != "" {
		w.t.Fatalf("a hook must exit 0 with an empty stderr: %+v %+v", h, hf)
	}
	c.hook, c.hookFull = norm(h.out), norm(hf.out)
}

// TestUpdateAuditsGolden rewrites the whole golden from the frozen scripts (run with -update-audits). It is one
// flat test, not a table of subtests, so a -run filter cannot regenerate a part of the corpus.
func TestUpdateAuditsGolden(t *testing.T) {
	if !*updateAudits {
		t.Skip("run with -update-audits to regenerate the golden from the frozen scripts")
	}
	var cases []auditGold
	for _, sc := range goldenAuditScenarios() {
		w := newWorld(t)
		sc.setup(w)
		c := snapshotAuditGold(w, sc.name)
		w.record(&c)
		cases = append(cases, c)
	}
	if err := os.WriteFile(auditGoldPath, formatAuditGold(cases), 0o644); err != nil {
		t.Fatal(err)
	}
}

// TestAuditsGoldenDifferential runs every golden world through the frozen scripts again and compares with what
// the golden holds: the golden is what the scripts printed, and this is what keeps it honest.
func TestAuditsGoldenDifferential(t *testing.T) {
	for _, c := range readAuditGold(t) {
		t.Run(c.name, func(t *testing.T) {
			w := newWorld(t)
			c.build(w)
			got := auditGold{}
			w.record(&got)
			if got.rc != c.rc || got.out != c.out || got.err != c.err || got.hook != c.hook || got.hookFull != c.hookFull {
				t.Errorf("the frozen scripts print something else than the golden\nrc %d want %d\nstdout:\n%s\nwant:\n%s\nstderr:\n%s\nwant:\n%s\nhook:\n%s\nwant:\n%s",
					got.rc, c.rc, got.out, c.out, got.err, c.err, got.hook, c.hook)
			}
		})
	}
}
