package gate

import (
	"os"
	"strings"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/kitmaint"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/testkit/kitworld"
)

const gateCmd = `echo GATE-RAN >> "$SHIM_STATE/calls.log"; echo "AGGREGATE RESULT: 3 passed"; exit 7`

func TestFailingGateExits16WithSummaryAndLog(t *testing.T) {
	w := kitworld.New(t)
	headRule(w)
	r := goRun(w, []string{"--state-dir", w.Dir + "/st", "--cmd", gateCmd, w.Wt, "lbl"})
	if r.rc != 16 || !strings.Contains(r.out, "AGGREGATE RESULT: 3 passed\n") || !strings.HasSuffix(r.out, "kit-gate: gate rc=7 log="+w.Dir+"/st/gate-lbl.log\n") {
		t.Fatalf("%+v", r)
	}
	b, _ := os.ReadFile(w.Dir + "/st/gate-lbl.log")
	if !strings.HasPrefix(string(b), "head abc1234\n") || !strings.HasSuffix(string(b), "gate rc=7\n") {
		t.Errorf("log = %q", b)
	}
	if got := w.Calls(); got != "git -C "+w.Wt+" rev-parse --short HEAD\nGATE-RAN\n" {
		t.Errorf("calls = %q: git for the head, then the gate, and no flock child (the lock is in process)", got)
	}
}

func TestSerialAndDefaultGate(t *testing.T) {
	w := kitworld.New(t)
	headRule(w)
	runAll(t, w)
	if r := goRun(w, []string{"--state-dir", w.Dir + "/st", "--serial", w.Wt, "lbl"}); r.rc != 0 || !strings.Contains(w.Calls(), "RUNALL --prove-teeth\n") || strings.Contains(w.Calls(), "-j 4") {
		t.Errorf("serial: %+v calls=%q", r, w.Calls())
	}
	w2 := kitworld.New(t)
	headRule(w2)
	runAll(t, w2)
	if r := goRun(w2, []string{"--state-dir", w2.Dir + "/st", w2.Wt, "lbl"}); r.rc != 0 || !strings.Contains(w2.Calls(), "RUNALL -j 4 --prove-teeth\n") {
		t.Errorf("default: %+v calls=%q", r, w2.Calls())
	}
	// an explicitly empty --cmd runs nothing and passes (bash -c ''), it is not "the default gate"
	w3 := kitworld.New(t)
	headRule(w3)
	runAll(t, w3)
	if r := goRun(w3, []string{"--state-dir", w3.Dir + "/st", "--cmd", "", w3.Wt, "lbl"}); r.rc != 0 || strings.Contains(w3.Calls(), "RUNALL") {
		t.Errorf("empty --cmd: %+v calls=%q", r, w3.Calls())
	}
}

func TestStateDirDefaultsUnderXDG(t *testing.T) {
	w := kitworld.New(t)
	headRule(w)
	r := goRun(w, []string{"--cmd", "true", w.Wt, "lbl"}, "XDG_STATE_HOME="+w.Dir+"/xdg")
	if r.rc != 0 {
		t.Fatalf("%+v", r)
	}
	if _, err := os.Stat(w.Dir + "/xdg/research-sdd/pipeline/gate-lbl.log"); err != nil {
		t.Errorf("state lives in $XDG_STATE_HOME/research-sdd/pipeline: %v", err)
	}
}

func TestLockTimeoutIsTypedNotAGateFailure(t *testing.T) {
	w := kitworld.New(t)
	headRule(w)
	if err := os.MkdirAll(w.Dir+"/st", 0o755); err != nil {
		t.Fatal(err)
	}
	held, err := os.OpenFile(w.Dir+"/st/gate.lock", os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	defer held.Close()
	if !kitmaint.Flock(held, 0, time.Sleep) {
		t.Fatal("cannot hold the lock")
	}
	r := goRun(w, []string{"--state-dir", w.Dir + "/st", "--lock-timeout", "0", "--cmd", gateCmd, w.Wt, "lbl"})
	if r.rc != 22 || r.out != "kit-gate: gate-lock-timeout: could not take "+w.Dir+"/st/gate.lock within 0s\n" || strings.Contains(w.Calls(), "GATE-RAN") {
		t.Errorf("%+v", r)
	}
	// the environment knob feeds the same timeout
	r = goRun(w, []string{"--state-dir", w.Dir + "/st", "--cmd", gateCmd, w.Wt, "lbl"}, "KIT_GATE_LOCK_TIMEOUT=0")
	if r.rc != 22 || !strings.Contains(r.out, "within 0s") {
		t.Errorf("env: %+v", r)
	}
	// ... and a flag beats the environment
	r = goRun(w, []string{"--state-dir", w.Dir + "/st", "--lock-timeout", "0", "--cmd", gateCmd, w.Wt, "lbl"}, "KIT_GATE_LOCK_TIMEOUT=x")
	if r.rc != 22 {
		t.Errorf("flag over env: %+v", r)
	}
	r = goRun(w, []string{"--state-dir", w.Dir + "/st", "--cmd", gateCmd, w.Wt, "lbl"}, "KIT_GATE_LOCK_TIMEOUT=x")
	if r.rc != 2 || r.out != "kit-gate: usage: --lock-timeout must be a number of seconds\n" {
		t.Errorf("bad env: %+v", r)
	}
}

func TestStateNeverInsideTheWorktree(t *testing.T) {
	w := kitworld.New(t)
	headRule(w)
	if err := os.MkdirAll(w.Wt+"/sub", 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(w.Wt+"/sub", w.Dir+"/lnk"); err != nil {
		t.Fatal(err)
	}
	for _, st := range []string{w.Wt + "/state", w.Dir + "/lnk/state"} {
		r := goRun(w, []string{"--state-dir", st, "--cmd", "true", w.Wt, "lbl"})
		if r.rc != 2 || !strings.Contains(r.out, "is inside the worktree; state never lives in the repo") {
			t.Errorf("%s: %+v", st, r)
		}
	}
	if _, err := os.Stat(w.Wt + "/sub/state"); err == nil {
		t.Error("nothing is created for a refused state dir")
	}
}

func TestMissingDependenciesAreTypedDegraded(t *testing.T) {
	for _, c := range []struct {
		drop []string
		list string
	}{
		{[]string{"flock"}, "flock"}, {[]string{"git"}, "git"}, {[]string{"git", "flock"}, "flock git"},
	} {
		w := kitworld.New(t)
		for _, d := range c.drop {
			w.Drop(d)
		}
		r := goRun(w, []string{"--state-dir", w.Dir + "/st", "--cmd", "true", w.Wt, "lbl"})
		want := "kit-gate: degraded: missing runtime dependency: " + c.list + "\n"
		if r.rc != 3 || r.out != want || r.err != "DEGRADED: missing runtime dependency: "+c.list+"\n" {
			t.Errorf("drop %v: %+v", c.drop, r)
		}
		if _, err := os.Stat(w.Dir + "/st"); err == nil {
			t.Errorf("drop %v: nothing is created when a dependency is missing", c.drop)
		}
	}
	// a missing worktree is a usage error even when a dependency is also missing (the bash order)
	w := kitworld.New(t)
	w.Drop("flock")
	if r := goRun(w, []string{"--cmd", "true", w.Dir + "/nope", "lbl"}); r.rc != 2 || !strings.Contains(r.out, "usage: worktree is not a directory: "+w.Dir+"/nope") {
		t.Errorf("%+v", r)
	}
}

func TestSignalEndsTheRunTyped(t *testing.T) {
	w := kitworld.New(t)
	headRule(w)
	sig := make(chan os.Signal, 1)
	stopped := false
	s, o, _ := w.Stdio(w.Wt)
	go func() {
		for i := 0; i < 300 && !strings.Contains(w.Calls(), "STARTED"); i++ {
			time.Sleep(10 * time.Millisecond)
		}
		sig <- os.Interrupt
	}()
	rc := run([]string{"--state-dir", w.Dir + "/st", "--cmd", `echo STARTED >> "$SHIM_STATE/calls.log"; sleep 30 & wait`, w.Wt, "lbl"}, s,
		deps{sleep: time.Sleep, notify: func() (<-chan os.Signal, func()) { return sig, func() { stopped = true } }})
	if rc != 16 || !strings.HasSuffix(o.String(), "kit-gate: interrupted: the gate was stopped by a signal\n") || !stopped {
		t.Errorf("rc=%d out=%q stopped=%v", rc, o.String(), stopped)
	}
	if strings.Contains(o.String(), "gate rc=") {
		t.Errorf("an interrupted run prints no gate rc line: %q", o.String())
	}
}
