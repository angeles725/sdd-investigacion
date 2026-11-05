package fetchdoc

import (
	"encoding/json"
	"os"
	"testing"
)

const goldenFile = "testdata/golden/scenarios.json"

// goldenCase is what the frozen legacy script produced for one scenario (paths are <R>, timestamps <DATE>).
type goldenCase struct {
	Out  string `json:"out"`
	Err  string `json:"err"`
	RC   int    `json:"rc"`
	Tree string `json:"tree"`
}

// TestGoldenReplay replays every differential scenario against the frozen oracle's recorded answers, so the checks
// also run where there is no bash oracle (the mutation run, -tags nodiff). A scenario with no golden is a failure:
// the replay must never pass because it compared nothing.
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
	if len(golden) != len(scs) {
		t.Fatalf("%d goldens for %d scenarios: regenerate with -update-golden", len(golden), len(scs))
	}
	for _, sc := range scs {
		t.Run(sc.name, func(t *testing.T) {
			want, ok := golden[sc.name]
			if !ok {
				t.Fatalf("no golden for %s", sc.name)
			}
			w := newWorld(t, sc.stubs...)
			w.setEnv(sc.env...)
			if sc.setup != nil {
				sc.setup(w)
			}
			got := w.goRun(sc.args(w)...)
			gc := goldenCase{Out: w.norm(got.out), Err: w.norm(got.err), RC: got.rc, Tree: got.tree}
			if gc != want {
				t.Errorf("rc %d out %q err %q tree\n%s\nwant rc %d out %q err %q tree\n%s", gc.RC, gc.Out, gc.Err, gc.Tree, want.RC, want.Out, want.Err, want.Tree)
			}
		})
	}
}
