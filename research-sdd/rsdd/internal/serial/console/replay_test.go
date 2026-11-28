//go:build unix

package console

import (
	"os"
	"testing"
)

// TestReplay runs every scenario against the answers the differential recorded from the frozen legacy script, so
// the same checks run where there is no bash oracle (the mutation run, -tags nodiff). A scenario with no recorded
// answer is a failure: the replay must never pass because it compared nothing.
func TestReplay(t *testing.T) {
	recorded := loadRecorded(t)
	scs := scenarios()
	if len(recorded) != len(scs) {
		t.Fatalf("%d recorded answers for %d scenarios: regenerate with -update-golden", len(recorded), len(scs))
	}
	for _, sc := range scs {
		t.Run(sc.name, func(t *testing.T) {
			if sc.needsUser && os.Geteuid() == 0 {
				t.Skip("root ignores the permission bits this scenario relies on")
			}
			want, ok := recorded[sc.name]
			if !ok {
				t.Fatalf("no recorded answer for %s", sc.name)
			}
			if sc.intended != nil {
				i := *sc.intended
				i.Tree = want.Tree
				want = i
			}
			w := newWorld(t)
			sc.prepare(w)
			if got := w.norm(w.goRun(sc), sc, false); got != want {
				t.Errorf("the Go command differs from the recorded answer\n--- want\nrc=%d\nstdout=%q\nstderr=%q\ntree:\n%s\n--- got\nrc=%d\nstdout=%q\nstderr=%q\ntree:\n%s",
					want.RC, want.Out, want.Err, want.Tree, got.RC, got.Out, got.Err, got.Tree)
			}
		})
	}
}
