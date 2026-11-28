//go:build !nodiff

package reviewslices

import (
	"encoding/json"
	"flag"
	"os"
	"strings"
	"sync"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/testkit/kitworld"
)

// updateGolden rewrites testdata/golden/scenarios.json from the frozen legacy script:
//
//	go test ./internal/lint/reviewslices -run TestPlanDifferential -update-golden
var updateGolden = flag.Bool("update-golden", false, "rewrite testdata/golden/scenarios.json from the legacy script")

// TestPlanDifferential runs every scenario's repository through the frozen legacy script (testdata/legacy) and the Go
// command and demands the same stdout, stderr and exit code, byte for byte, and a repository left as it was. A
// scenario with a declared divergence must differ from the script AND match the declared answer. Under -tags nodiff
// (the mutation run, which has no bash oracle) the same scenarios replay against the answers the oracle gave
// (golden_test.go).
func TestPlanDifferential(t *testing.T) {
	stage := kitworld.Stage(t, "testdata/legacy", "plan-review-slices.sh")
	golden := map[string]goldenCase{}
	var mu sync.Mutex
	t.Run("scenarios", func(t *testing.T) {
		forEach(t, func(t *testing.T, r *repo, sc scenario) {
			before := r.state()
			l := r.bashRun(t, stage+"/plan-review-slices.sh", r.expand(orDir(sc.cwd, r.dir)), r.runEnv(sc, "legacy"), r.expandAll(sc.args)...)
			g := r.goRun(r.expand(orDir(sc.cwd, r.dir)), r.runEnv(sc, "go"), r.expandAll(sc.args)...)
			if after := r.state(); after != before {
				t.Errorf("a report-only run changed the repository:\n--- before\n%s\n--- after\n%s", before, after)
			}
			norm := func(s string) string { return strings.ReplaceAll(s, r.root, "<ROOT>") }
			l, g = ran{norm(l.out), norm(l.err), l.rc}, ran{norm(g.out), norm(g.err), g.rc}
			if strings.TrimSpace(l.out) == "" {
				t.Errorf("the oracle printed nothing on stdout: the comparison would prove nothing (stderr %q)", l.err)
			}
			if sc.diverge == nil {
				if g != l {
					t.Errorf("differs from the frozen script\n--- legacy rc=%d\nstdout:\n%s\nstderr:\n%s\n--- go rc=%d\nstdout:\n%s\nstderr:\n%s", l.rc, l.out, l.err, g.rc, g.out, g.err)
				}
				mu.Lock()
				golden[sc.name] = goldenCase{Out: l.out, Err: l.err, RC: l.rc}
				mu.Unlock()
				return
			}
			want := ran{norm(r.expandC1(sc.diverge.out)), norm(r.expandC1(sc.diverge.err)), sc.diverge.rc}
			if g != want {
				t.Errorf("declared divergence not met\n--- want rc=%d\nstdout:\n%s\nstderr:\n%s\n--- go rc=%d\nstdout:\n%s\nstderr:\n%s", want.rc, want.out, want.err, g.rc, g.out, g.err)
			}
			if g == l {
				t.Errorf("stale divergence %q: the Go command now equals the script", sc.diverge.reason)
			}
		})
	})
	if *updateGolden && !t.Failed() {
		b, err := json.MarshalIndent(golden, "", " ")
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(goldenFile, append(b, '\n'), 0o644); err != nil {
			t.Fatal(err)
		}
	}
}
