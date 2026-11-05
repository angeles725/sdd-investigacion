//go:build unix

package kitmaint

import (
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"
)

func TestFlock(t *testing.T) {
	p := filepath.Join(scratch(t), "lock")
	a, err := os.OpenFile(p, os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	defer a.Close()
	b, err := os.OpenFile(p, os.O_WRONLY, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer b.Close()
	sleeps := 0
	if !Flock(a, 0, func(time.Duration) { sleeps++ }) || sleeps != 0 {
		t.Fatal("a free lock is taken at once")
	}
	// held: 0 seconds tries once and gives up; 1 second polls in 50 ms steps
	if Flock(b, 0, func(time.Duration) { sleeps++ }) || sleeps != 0 {
		t.Errorf("-w 0 must try once (sleeps=%d)", sleeps)
	}
	if Flock(b, 1, func(time.Duration) { sleeps++ }) || sleeps != 20 {
		t.Errorf("-w 1 must poll 20 times at 50 ms (sleeps=%d)", sleeps)
	}
	// released while waiting: the waiter gets it
	released := false
	if !Flock(b, 5, func(time.Duration) {
		if !released {
			released = true
			a.Close()
		}
	}) {
		t.Error("the lock freed during the wait must be taken")
	}
	if Flock(os.NewFile(^uintptr(0), "bad"), 0, func(time.Duration) {}) {
		t.Error("a bad fd is not a lock")
	}
}

func TestExitCodeAndSignals(t *testing.T) {
	if got := ExitCode(nil); got != 127 {
		t.Errorf("nil state = %d", got)
	}
	run := func(body string) *exec.Cmd {
		c := exec.Command("sh", "-c", body)
		ProcAttr(c)
		_ = c.Run()
		return c
	}
	if got := ExitCode(run("exit 3").ProcessState); got != 3 {
		t.Errorf("exit 3 = %d", got)
	}
	if got := ExitCode(run("kill -9 $$").ProcessState); got != 137 {
		t.Errorf("SIGKILL = %d, want 128+9", got)
	}
	// TERM reaches the whole group; KILL reaches it too
	for _, kill := range []bool{false, true} {
		c := exec.Command("sh", "-c", "sleep 30 & wait")
		ProcAttr(c)
		if err := c.Start(); err != nil {
			t.Fatal(err)
		}
		SignalGroup(c, kill)
		_ = c.Wait()
		want := 143
		if kill {
			want = 137
		}
		if got := ExitCode(c.ProcessState); got != want {
			t.Errorf("kill=%v: rc %d, want %d", kill, got, want)
		}
	}
	SignalGroup(exec.Command("true"), false) // not started: nothing to signal, no panic
}
