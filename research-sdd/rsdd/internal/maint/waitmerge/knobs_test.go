package waitmerge

import (
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/kitwait"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/testkit/kitworld"
)

func TestNonNumericKnobsAreUsageErrors(t *testing.T) {
	for _, k := range kitwait.Knobs {
		w := kitworld.New(t)
		happy(w)
		r := goRun(t, w, []string{w.Wt, "7"}, k+"=1x")
		if r.rc != 2 || r.out != "kit-wait-merge: usage: "+k+" must be a whole number: 1x\n" || r.err != "" || w.Calls() != "" {
			t.Errorf("%s: %+v calls=%q", k, r, w.Calls())
		}
		// whole numbers and the empty string (unset) are fine
		for _, ok := range []string{"1", "5", ""} {
			w2 := kitworld.New(t)
			happy(w2)
			if r := goRun(t, w2, []string{w2.Wt, "7"}, k+"="+ok); r.rc != 0 {
				t.Errorf("%s=%q: %+v", k, ok, r)
			}
		}
	}
	// the first bad knob in table order is the one named
	if got := kitwait.BadKnob(func(k string) string {
		if k == "KIT_MERGE_SLEEP" || k == "KIT_POLL_SLEEP" {
			return "x"
		}
		return ""
	}); got != "KIT_POLL_SLEEP" {
		t.Errorf("badKnob = %q", got)
	}
}
