//go:build unix

package gh

import "testing"

func TestRun(t *testing.T) {
	b20 := Bound{Seconds: 20}
	cases := []struct {
		name           string
		extra          []string
		bin            string
		want           RunResult
		stdout, stderr string
	}{
		{"success hands the output back", []string{"GH_OUT=made", "GH_ERR=note"}, "", RunResult{State: StateOK, Bound: b20}, "made", "note"},
		{"failure keeps its code and output", []string{"GH_RC=3", "GH_ERR=boom"}, "", RunResult{State: StateError, RC: 3, Bound: b20}, "", "boom"},
		{"missing gh is 127", nil, "gh-absent", RunResult{State: StateMissing, RC: 127}, "", ""},
		{"KILLed gh is the bound's escalation", []string{"GH_SELFKILL=KILL"}, "", RunResult{State: StateTimeout, RC: 124, Bound: b20}, "", ""},
		{"TERMed gh stays an error", []string{"GH_SELFKILL=TERM"}, "", RunResult{State: StateError, RC: 143, Bound: b20}, "", ""},
		{"bad knob still runs", []string{"RSDD_GH_TIMEOUT=abc", "GH_OUT=x"}, "", RunResult{State: StateOK, Bound: Bound{Seconds: 20, Bad: true}}, "x", ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			o := opts(t, c.extra...)
			o.Bin = c.bin
			r, err := Run(o, "repo", "edit", "o/r")
			if err != nil {
				t.Fatal(err)
			}
			if r.State != c.want.State || r.RC != c.want.RC || r.Bound != c.want.Bound || string(r.Stdout) != c.stdout || string(r.Stderr) != c.stderr {
				t.Fatalf("got %+v (stdout %q stderr %q), want %+v (%q %q)", r, r.Stdout, r.Stderr, c.want, c.stdout, c.stderr)
			}
		})
	}
}

func TestRunProbeFailedCarriesTheError(t *testing.T) {
	o := opts(t)
	o.MaxBytes = -1
	if r, err := Run(o); err == nil || r.State != StateProbeFailed {
		t.Fatalf("got %+v, %v", r, err)
	}
}
