package reviewslices

import (
	"encoding/json"
	"os"
	"strings"
	"testing"
)

const goldenFile = "testdata/golden/scenarios.json"

// goldenCase is what the frozen legacy script printed for one scenario (the temp root is <ROOT>).
type goldenCase struct {
	Out string `json:"out"`
	Err string `json:"err"`
	RC  int    `json:"rc"`
}

// TestGoldenReplay replays every differential scenario against the frozen oracle's recorded answers, so the checks
// also run where there is no bash oracle (the mutation run, -tags nodiff). A scenario with no golden is a failure,
// and so is a golden with no scenario: the replay must never pass because it compared nothing.
func TestGoldenReplay(t *testing.T) {
	b, err := os.ReadFile(goldenFile)
	if err != nil {
		t.Fatal(err)
	}
	golden := map[string]goldenCase{}
	if err := json.Unmarshal(b, &golden); err != nil {
		t.Fatal(err)
	}
	scs := scenarios()
	diverging := 0
	for _, sc := range scs {
		if sc.diverge != nil {
			diverging++
		}
	}
	if len(golden)+diverging != len(scs) {
		t.Fatalf("%d goldens and %d declared divergences for %d scenarios: regenerate with -update-golden", len(golden), diverging, len(scs))
	}
	forEach(t, func(t *testing.T, r *repo, sc scenario) {
		before := r.state()
		got := r.goRun(r.expand(orDir(sc.cwd, r.dir)), r.runEnv(sc, "go"), r.expandAll(sc.args)...)
		if after := r.state(); after != before {
			t.Errorf("a report-only run changed the repository:\n--- before\n%s\n--- after\n%s", before, after)
		}
		norm := func(s string) string { return strings.ReplaceAll(s, r.root, "<ROOT>") }
		got = ran{norm(got.out), norm(got.err), got.rc}
		if sc.light && (strings.Contains(got.out, "git repository") || strings.Contains(got.out, "does not resolve") || strings.Contains(got.out, "PLAN:")) {
			t.Errorf("a light scenario reached git (its root is not a repository): %q", got.out)
		}
		var want ran
		if sc.diverge != nil {
			want = ran{norm(r.expandC1(sc.diverge.out)), norm(r.expandC1(sc.diverge.err)), sc.diverge.rc}
		} else {
			g, ok := golden[sc.name]
			if !ok {
				t.Fatalf("no golden for %s", sc.name)
			}
			want = ran{g.Out, g.Err, g.RC}
		}
		if got != want {
			t.Errorf("rc %d out %q err %q\nwant rc %d out %q err %q", got.rc, got.out, got.err, want.rc, want.out, want.err)
		}
	})
}
