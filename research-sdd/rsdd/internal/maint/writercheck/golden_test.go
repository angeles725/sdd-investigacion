package writercheck

import (
	"encoding/json"
	"os"
	"testing"
)

const goldenFile = "testdata/golden/scenarios.json"

// goldenCase is what the frozen legacy script printed for one scenario (the case root is <R>).
type goldenCase struct {
	Out string `json:"out"`
	Err string `json:"err"`
	RC  int    `json:"rc"`
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
	scs := allScenarios()
	if len(golden) != len(scs) {
		t.Fatalf("%d goldens for %d scenarios: regenerate with -update-golden", len(golden), len(scs))
	}
	for _, sc := range scs {
		t.Run(sc.name, func(t *testing.T) {
			want, ok := golden[sc.name]
			if !ok {
				t.Fatalf("no golden for %s", sc.name)
			}
			k := newKase(t)
			sc.build(k)
			got := k.goRun(k.envFor(sc), sc.args(k)...)
			out, errs := k.norm(got.out), k.norm(got.err)
			if got.rc != want.RC || out != want.Out || errs != want.Err {
				t.Errorf("rc %d out %q err %q\nwant rc %d out %q err %q", got.rc, out, errs, want.RC, want.Out, want.Err)
			}
		})
	}
}
