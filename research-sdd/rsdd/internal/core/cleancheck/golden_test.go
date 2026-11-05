package cleancheck

import (
	"encoding/json"
	"os"
	"testing"
)

const goldenFile = "testdata/golden/scenarios.json"

// goldenCase is what the frozen legacy script printed for one scenario (the world root is <R>).
type goldenCase struct {
	Merged string `json:"merged"`
	Out    string `json:"out"`
	Err    string `json:"err"`
	RC     int    `json:"rc"`
}

// prepare builds the world of a scenario (the build step is optional).
func (sc scenario) prepare(w *world) {
	if sc.build != nil {
		sc.build(w)
	}
}

// environ is the extra environment of a scenario (optional).
func (sc scenario) environ(w *world) []string {
	if sc.env == nil {
		return nil
	}
	return sc.env(w)
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
	ran := 0
	for _, sc := range scs {
		t.Run(sc.name, func(t *testing.T) {
			if sc.skip(t) {
				return
			}
			want, ok := golden[sc.name]
			if !ok {
				t.Fatalf("no golden for %s: regenerate with -update-golden", sc.name)
			}
			w := newWorld(t)
			sc.prepare(w)
			got := Check(w.optionsFor(sc.environ(w), sc.args(w)...))
			ran++
			if got.Exit != want.RC || w.show(got.Merged()) != want.Merged || w.show(got.Stdout()) != want.Out || w.show(got.Stderr()) != want.Err {
				t.Errorf("rc %d\n%s\nwant rc %d\n%s", got.Exit, w.show(got.Merged()), want.RC, want.Merged)
			}
		})
	}
	if ran == 0 {
		t.Fatal("no scenario ran: the replay compared nothing")
	}
}
