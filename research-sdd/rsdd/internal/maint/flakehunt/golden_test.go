package flakehunt

import (
	"encoding/json"
	"os"
	"reflect"
	"testing"
)

const goldenFile = "testdata/golden/scenarios.json"

// TestGoldenReplay replays every differential scenario against the frozen oracle's recorded answers, so the checks
// also run where there is no bash oracle (the mutation run, -tags nodiff). A scenario with no golden is a failure:
// the replay must never pass because it compared nothing. A `diverges` scenario compares the exit code only.
func TestGoldenReplay(t *testing.T) {
	b, err := os.ReadFile(goldenFile)
	if err != nil {
		t.Fatal(err)
	}
	golden := map[string]snapshot{}
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
			w, args, cwd := sc.build(t)
			w.cwd = cwd
			got := w.snap(w.goRun(args...))
			if got.RC != want.RC {
				t.Fatalf("exit %d, golden %d\nout=%q err=%q", got.RC, want.RC, got.Out, got.Err)
			}
			if sc.diverges {
				return
			}
			if got.Out != want.Out || got.Err != want.Err || !reflect.DeepEqual(got.Files, want.Files) {
				t.Errorf("differs from the golden\nout %q\nwant %q\nerr %q\nwant %q\n%s", got.Out, want.Out, got.Err, want.Err, filesDiff(want.Files, got.Files))
			}
		})
	}
}
