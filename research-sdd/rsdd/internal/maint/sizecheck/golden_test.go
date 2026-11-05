package sizecheck

import (
	"encoding/json"
	"os"
	"strings"
	"testing"
)

const goldenFile = "testdata/golden/scenarios.json"

// goldenCase is what the frozen legacy script printed for one scenario (the temp repository path is <R>).
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
			r := newRepo(t)
			sc.build(r)
			got := r.goRun(sc.args...)
			out, errs := strings.ReplaceAll(got.out, r.dir, "<R>"), strings.ReplaceAll(got.err, r.dir, "<R>")
			if got.rc != want.RC || out != want.Out || errs != want.Err {
				t.Errorf("rc %d out %q err %q\nwant rc %d out %q err %q", got.rc, out, errs, want.RC, want.Out, want.Err)
			}
		})
	}
}
