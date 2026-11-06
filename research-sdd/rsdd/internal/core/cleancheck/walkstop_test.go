package cleancheck

import "testing"

// never is the stop of a walk nobody cancels.
func never() bool { return false }

// The walks stop at the next entry once asked to; one that is never asked stays whole.
func TestWalkTreeStops(t *testing.T) {
	w := newWorld(t)
	for _, n := range []string{"a", "b", "c"} {
		w.writeAt(w.scratch+"/"+n+"/f", "x")
	}
	count := func(stop func() bool) int {
		n := 0
		walkTree(stop, w.scratch, noLimit, func(string, int, entry) bool { n++; return true })
		return n
	}
	if got := count(never); got != 6 {
		t.Fatalf("an unstopped walk visited %d entries, want 6", got)
	}
	asked := 0
	if got := count(func() bool { asked++; return asked > 2 }); got != 2 {
		t.Errorf("a walk stopped at the third question visited %d entries, want 2", got)
	}
}
