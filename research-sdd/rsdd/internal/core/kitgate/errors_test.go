package kitgate

import (
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/kitmaint"
)

func TestGateUsageAndDegradedStates(t *testing.T) {
	e := newEnv(t)
	o := e.opts("true")
	o.LockTimeout = "12x"
	if res := Run(o); res.Code != ExitUsage || e.out.String() != "kit-gate: usage: --lock-timeout must be a number of seconds\n" || e.probed != 0 {
		t.Errorf("lock timeout: %+v %q", res, e.out.String())
	}

	e = newEnv(t)
	o = e.opts("true")
	o.Wt = filepath.Join(e.root, "nope")
	if res := Run(o); res.Code != ExitUsage || e.out.String() != "kit-gate: usage: worktree is not a directory: "+o.Wt+"\n" || e.probed != 0 {
		t.Errorf("missing worktree: %+v %q probed=%d (usage wins over the dependency probe)", res, e.out.String(), e.probed)
	}

	e = newEnv(t)
	e.probeSays = false
	if res := Run(e.opts("true")); res.Code != ExitDegraded || e.out.Len() != 0 {
		t.Errorf("failed probe: %+v %q (the probe prints its own line)", res, e.out.String())
	}
	if _, err := os.Stat(e.state); err == nil {
		t.Error("nothing is created when the probe fails")
	}

	// state inside the worktree, also through a symlink
	e = newEnv(t)
	if err := os.Symlink(e.wt, filepath.Join(e.root, "lnk")); err != nil {
		t.Fatal(err)
	}
	for _, st := range []string{filepath.Join(e.wt, "state"), filepath.Join(e.root, "lnk", "state"), e.wt} {
		e.out.Reset()
		o = e.opts("true")
		o.State = st
		if res := Run(o); res.Code != ExitUsage || !strings.Contains(e.out.String(), "is inside the worktree; state never lives in the repo") {
			t.Errorf("state %s: %+v %q", st, res, e.out.String())
		}
	}
	if _, err := os.Stat(filepath.Join(e.wt, "state")); err == nil {
		t.Error("a refused state dir is never created")
	}

	// a state dir that cannot be created, a relative state dir resolved against cwd
	e = newEnv(t)
	blocker := filepath.Join(e.root, "file")
	if err := os.WriteFile(blocker, nil, 0o644); err != nil {
		t.Fatal(err)
	}
	o = e.opts("true")
	o.State = filepath.Join(blocker, "sub")
	if res := Run(o); res.Code != ExitUsage {
		t.Errorf("uncreatable state: %+v %q", res, e.out.String())
	}
	e = newEnv(t)
	o = e.opts("true")
	o.State = "rel-state"
	if res := Run(o); res.Code != 0 {
		t.Fatalf("relative state: %+v %q", res, e.out.String())
	}
	if _, err := os.Stat(filepath.Join(e.root, "rel-state", "gate.lock")); err != nil {
		t.Errorf("a relative --state-dir lives under the runner's cwd: %v", err)
	}
}

func TestGateLockTimeout(t *testing.T) {
	e := newEnv(t)
	if err := os.MkdirAll(e.state, 0o755); err != nil {
		t.Fatal(err)
	}
	held, err := os.OpenFile(filepath.Join(e.state, "gate.lock"), os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	defer held.Close()
	if !kitmaint.Flock(held, 0, time.Sleep) {
		t.Fatal("cannot hold the lock")
	}
	o := e.opts("echo SHOULD-NOT-RUN > " + filepath.Join(e.root, "ran"))
	o.LockTimeout = "0"
	res := Run(o)
	want := "kit-gate: gate-lock-timeout: could not take " + filepath.Join(e.state, "gate.lock") + " within 0s\n"
	if res.Code != ExitLockTimeout || e.out.String() != want {
		t.Errorf("res=%+v out=%q", res, e.out.String())
	}
	if _, err := os.Stat(filepath.Join(e.root, "ran")); err == nil {
		t.Error("the gate must not run without the lock")
	}
	if _, err := os.Stat(filepath.Join(e.state, "gate-lbl.log")); err == nil {
		t.Error("no log without the lock")
	}
}

func TestGateSignalIsForwardedToTheGroup(t *testing.T) {
	e := newEnv(t)
	sig := make(chan os.Signal, 1)
	o := e.opts("echo started > " + filepath.Join(e.root, "started") + "; sleep 30 & wait")
	o.Sig = sig
	go func() {
		for i := 0; i < 200; i++ {
			if _, err := os.Stat(filepath.Join(e.root, "started")); err == nil {
				break
			}
			time.Sleep(10 * time.Millisecond)
		}
		sig <- syscall.SIGTERM
	}()
	t0 := time.Now()
	res := Run(o)
	if !res.Interrupted || res.Code != ExitGateFailed || res.GateRC != 143 {
		t.Errorf("res=%+v", res)
	}
	if time.Since(t0) > 20*time.Second {
		t.Error("the forwarded TERM must end the gate, not the 30 s sleep")
	}
	if strings.Contains(e.log(), "gate rc=") || strings.Contains(e.out.String(), "kit-gate:") {
		t.Errorf("an interrupted run prints no `gate rc=` line and no summary: log=%q out=%q", e.log(), e.out.String())
	}
}

func TestGateWithoutBash(t *testing.T) {
	e := newEnv(t)
	e.runner.Env = []string{"PATH=" + e.root}
	if res := Run(e.opts("true")); res.Code != ExitDegraded || e.out.String() != "kit-gate: degraded: missing runtime dependency: bash\n" {
		t.Errorf("res=%+v out=%q", res, e.out.String())
	}
}
