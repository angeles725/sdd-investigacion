package kitgate

import "testing"

// SilentNoBash is the merge train's form: the same exit 3, no line.
func TestGateWithoutBashSilent(t *testing.T) {
	e := newEnv(t)
	e.runner.Env = []string{"PATH=" + e.root}
	o := e.opts("true")
	o.SilentNoBash = true
	if res := Run(o); res.Code != ExitDegraded || e.out.String() != "" {
		t.Errorf("res=%+v out=%q", res, e.out.String())
	}
}

// A lock timeout too long for an int: waited as long as possible by default, zero seconds (one try) for the train.
func TestLockSecondsOverflow(t *testing.T) {
	for _, c := range []struct {
		in   string
		once bool
		want int
	}{
		{"30", false, 30}, {"30", true, 30}, {"0", true, 0},
		{"99999999999999999999", false, maxLockSeconds}, {"99999999999999999999", true, 0},
		{"2147483648", false, maxLockSeconds},
	} {
		if got := lockSeconds(c.in, c.once); got != c.want {
			t.Errorf("lockSeconds(%q, %v) = %d, want %d", c.in, c.once, got, c.want)
		}
	}
}
