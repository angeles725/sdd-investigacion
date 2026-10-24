//go:build unix

package gh

import "testing"

func TestProbe(t *testing.T) {
	b20 := Bound{Seconds: 20}
	cases := []struct {
		name  string
		extra []string
		bin   string
		want  Visibility
	}{
		{"public", []string{"GH_OUT=PUBLIC\n"}, "", Visibility{State: StatePublic, Raw: "PUBLIC", Bound: b20}},
		{"private lower-case", []string{"GH_OUT=private\n\n"}, "", Visibility{State: StatePrivate, Raw: "PRIVATE", Bound: b20}},
		{"internal", []string{"GH_OUT=Internal"}, "", Visibility{State: StateInternal, Raw: "INTERNAL", Bound: b20}},
		{"error even printing PRIVATE", []string{"GH_OUT=PRIVATE", "GH_RC=1", "GH_ERR=HTTP 401: bad credentials\nmore"}, "",
			Visibility{State: StateError, RC: 1, Why: "HTTP 401: bad credentials", Raw: "PRIVATE", Bound: b20}},
		{"unrecognised", []string{"GH_OUT=weird"}, "", Visibility{State: StateUnrecognised, Raw: "WEIRD", Bound: b20}},
		{"empty answer", nil, "", Visibility{State: StateUnrecognised, Bound: b20}},
		{"inner newline is not decided", []string{"GH_OUT=PRIVATE\nX"}, "", Visibility{State: StateUnrecognised, Raw: "PRIVATE\nX", Bound: b20}},
		{"only ASCII is upper-cased", []string{"GH_OUT=prïvate"}, "", Visibility{State: StateUnrecognised, Raw: "PRïVATE", Bound: b20}},
		{"control bytes are kept", []string{"GH_OUT=PUB\x01LIC"}, "", Visibility{State: StateUnrecognised, Raw: "PUB\x01LIC", Bound: b20}},
		{"NUL bytes are dropped as $(...) does", []string{`GH_OUT=PUB\0LIC`}, "", Visibility{State: StatePublic, Raw: "PUBLIC", Bound: b20}},
		{"stderr without newline", []string{"GH_RC=4", "GH_ERR=no newline"}, "", Visibility{State: StateError, RC: 4, Why: "no newline", Bound: b20}},
		{"blank first stderr line", []string{"GH_RC=4", "GH_ERR=\nsecond"}, "", Visibility{State: StateError, RC: 4, Bound: b20}},
		{"missing", nil, "gh-absent", Visibility{State: StateMissing}},
		{"exit 124", []string{"GH_RC=124"}, "", Visibility{State: StateTimeout, RC: 124, Bound: b20}},
		{"KILLed gh is an error here", []string{"GH_SELFKILL=KILL"}, "", Visibility{State: StateError, RC: 137, Bound: b20}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			o := opts(t, c.extra...)
			o.Bin = c.bin
			v, err := Probe(o, "owner/repo")
			if err != nil {
				t.Fatal(err)
			}
			if v != c.want {
				t.Fatalf("got %+v, want %+v", v, c.want)
			}
		})
	}
}

func TestProbeArgvAndDecidedRC(t *testing.T) {
	o := opts(t, "GH_OUT=PRIVATE")
	log := withLog(t, &o)
	v, err := Probe(o, "o/r")
	if err != nil || !v.State.Decided() {
		t.Fatalf("got %+v, %v", v, err)
	}
	if got := log()["argv"]; got != "repo view o/r --json visibility --jq .visibility" {
		t.Fatalf("argv %q", got)
	}
}

func TestProbeFailedCarriesTheError(t *testing.T) {
	o := opts(t)
	o.MaxBytes = -1
	if v, err := Probe(o, "o/r"); err == nil || v.State != StateProbeFailed {
		t.Fatalf("got %+v, %v", v, err)
	}
}
