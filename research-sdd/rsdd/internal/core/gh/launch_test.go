//go:build unix

package gh

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/proc"
)

func TestLaunchCleansTheEnvironment(t *testing.T) {
	o := opts(t, "GH_REPO=other/repo", "GH_PROMPT_DISABLED=0", "FOO=kept")
	o.Dir = t.TempDir()
	log := withLog(t, &o)
	if _, err := o.launch([]string{"repo", "create", "o/r", "--private"}); err != nil {
		t.Fatal(err)
	}
	l := log()
	for k, v := range map[string]string{"argv": "repo create o/r --private", "prompt": "1", "repo": "unset", "foo": "kept", "cwd": o.Dir} {
		if l[k] != v {
			t.Errorf("stub saw %s=%q, want %q", k, l[k], v)
		}
	}
}

func TestLaunchStates(t *testing.T) {
	notExec := filepath.Join(t.TempDir(), "gh")
	if err := os.WriteFile(notExec, []byte("\x7fnot a program"), 0o755); err != nil {
		t.Fatal(err)
	}
	b20 := Bound{Seconds: 20}
	cases := []struct {
		name  string
		extra []string
		edit  func(*Options)
		state State
		rc    int // -1: not checked (a race)
		bound Bound
	}{
		{"clean exit", nil, nil, "", 0, b20},
		{"failing gh", []string{"GH_RC=3"}, nil, StateError, 3, b20},
		{"gh exiting 124 reads as the bound", []string{"GH_RC=124"}, nil, StateTimeout, 124, b20},
		{"signalled gh", []string{"GH_SELFKILL=TERM"}, nil, StateError, 143, b20},
		{"missing gh", nil, func(o *Options) { o.Bin = "gh-absent" }, StateMissing, 0, Bound{}},
		{"missing gh by path", nil, func(o *Options) { o.Bin = "/nonexistent/gh" }, StateMissing, 0, Bound{}},
		{"unrunnable gh", nil, func(o *Options) { o.Bin = notExec }, StateError, 126, b20},
		{"missing directory", nil, func(o *Options) { o.Dir = "/nonexistent-rsdd-dir" }, StateError, 1, b20},
		{"not a directory", nil, func(o *Options) { o.Dir = notExec }, StateError, 1, b20},
		{"missing gh before a missing directory", nil, func(o *Options) { o.Bin, o.Dir = "gh-absent", "/nonexistent-rsdd-dir" }, StateMissing, 0, Bound{}},
		{"own knob and default", []string{"RSDD_GH_TIMEOUT=3", "K=x"}, func(o *Options) { o.Knob, o.Default = "K", 60 }, "", 0, Bound{Seconds: 60, Bad: true}},
		{"output cap", []string{"GH_OUT=0123456789"}, func(o *Options) { o.MaxBytes = 4 }, StateOutputCap, -1, b20},
		{"output under the cap", []string{"GH_OUT=0123"}, func(o *Options) { o.MaxBytes = 5 }, "", 0, b20},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			o := opts(t, c.extra...)
			if c.edit != nil {
				c.edit(&o)
			}
			out, err := o.launch([]string{"repo", "edit"})
			if err != nil {
				t.Fatal(err)
			}
			if c.rc < 0 {
				out.rc = c.rc
			}
			if out.state != c.state || out.rc != c.rc || out.bound != c.bound {
				t.Fatalf("got state=%q rc=%d bound=%+v, want %q %d %+v", out.state, out.rc, out.bound, c.state, c.rc, c.bound)
			}
		})
	}
}

func TestLaunchBoundStopsAStalledGh(t *testing.T) {
	for _, ignore := range []string{"", "1"} {
		t.Run("ignore-term="+ignore, func(t *testing.T) {
			o := opts(t, "RSDD_GH_TIMEOUT=1", "GH_SLEEP=30", "GH_IGNORE_TERM="+ignore)
			start := time.Now()
			out, err := o.launch(nil)
			if err != nil {
				t.Fatal(err)
			}
			if out.state != StateTimeout || out.rc != 124 || out.bound != (Bound{Seconds: 1}) {
				t.Fatalf("got state=%q rc=%d bound=%+v", out.state, out.rc, out.bound)
			}
			if d := time.Since(start); d > 10*time.Second {
				t.Fatalf("took %v: the bound did not hold", d)
			}
		})
	}
}

func TestLaunchRefusedSpecIsProbeFailed(t *testing.T) {
	o := opts(t)
	o.MaxBytes = -1
	out, err := o.launch(nil)
	if !errors.Is(err, proc.ErrInvalidSpec) || out.state != StateProbeFailed {
		t.Fatalf("got state=%q, %v", out.state, err)
	}
}

func TestStateDecided(t *testing.T) {
	for s, want := range map[State]bool{
		StatePublic: true, StatePrivate: true, StateInternal: true, StateOK: false, StateTimeout: false,
		StateMissing: false, StateError: false, StateUnrecognised: false, StateProbeFailed: false, StateOutputCap: false,
	} {
		if s.Decided() != want {
			t.Errorf("%s.Decided() = %v", s, !want)
		}
	}
}
