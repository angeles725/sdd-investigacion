//go:build unix

package proc

import (
	"errors"
	"os/exec"
	"syscall"
	"testing"
	"time"
)

// The refusal cases exercise the pure check only: a mutant that drops a
// guard clause must fail here without any real signal being sent. The ids
// are fixed, not read from the system: inside a PID namespace Getpgrp
// returns 0 when our group leader lives outside it.
func TestCheckGroupRefusesGroupsTheCallerDoesNotOwn(t *testing.T) {
	const own, child = 4242, 5000
	cases := []struct {
		name               string
		pgid, childPgid, o int
	}{
		{"zero (our own group)", 0, 0, own},
		{"one (every process)", 1, 1, own},
		{"negative", -child, -child, own},
		{"minus one", -1, -1, own},
		{"our own group", own, own, own},
		{"not the child's group", child, child + 1, own},
		{"child group unrecorded", child, 0, own},
	}
	for _, c := range cases {
		err := CheckGroup(c.pgid, c.childPgid, c.o)
		var re *GroupRefusedError
		if !errors.As(err, &re) || errors.Is(err, ErrGroupGone) {
			t.Errorf("%s: CheckGroup(%d, %d, %d) = %v, want a refusal that is not ErrGroupGone", c.name, c.pgid, c.childPgid, c.o, err)
		}
	}
}

func TestCheckGroupAcceptsTheChildsOwnGroup(t *testing.T) {
	for _, pgid := range []int{2, 4242} {
		if err := CheckGroup(pgid, pgid, 7); err != nil {
			t.Errorf("CheckGroup(%d, %d, 7) = %v, want accepted", pgid, pgid, err)
		}
	}
}

// startGroup starts script as the leader of its own process group and
// waits for the leader to exit; it returns the recorded group id.
func startGroup(t *testing.T, script string) int {
	t.Helper()
	dir := t.TempDir()
	cmd := exec.Command("/bin/sh", "-c", script)
	cmd.Dir = dir
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	pgid, err := syscall.Getpgid(cmd.Process.Pid)
	if err != nil || pgid != cmd.Process.Pid {
		t.Fatalf("child group = %d, %v; want its own pid %d", pgid, err, cmd.Process.Pid)
	}
	_ = cmd.Wait()
	return pgid
}

func TestKillGroupRefusesAGroupThatNoLongerExists(t *testing.T) {
	pgid := startGroup(t, `exit 0`)
	err := KillGroup(pgid, pgid)
	var re *GroupRefusedError
	if !errors.As(err, &re) || !errors.Is(err, ErrGroupGone) {
		t.Fatalf("KillGroup on reaped group %d = %v, want an ErrGroupGone refusal", pgid, err)
	}
}

// The leader is already reaped while its background sleeper keeps the
// group alive: the kill must still reach the whole group.
func TestKillGroupKillsALiveChildGroup(t *testing.T) {
	pgid := startGroup(t, `sleep 30 & echo $! > pid; exit 0`)
	if !GroupAlive(pgid) {
		t.Fatalf("group %d already gone: the sleeper should keep it alive", pgid)
	}
	t.Cleanup(func() { _ = KillGroup(pgid, pgid) })
	if err := KillGroup(pgid, pgid); err != nil {
		t.Fatalf("KillGroup(%d) = %v, want nil", pgid, err)
	}
	waitGone(t, pgid)
}

// waitGone fails the test unless group pgid has no member within 5s.
func waitGone(t *testing.T, pgid int) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for GroupAlive(pgid) {
		if time.Now().After(deadline) {
			t.Fatalf("group %d is still alive", pgid)
		}
		time.Sleep(20 * time.Millisecond)
	}
}

// startLiveGroup starts a sleeper as the leader of its own group and returns
// the command; cleanup kills that group through the guard and reaps it.
func startLiveGroup(t *testing.T) (*exec.Cmd, *Group) {
	t.Helper()
	cmd := exec.Command("/bin/sh", "-c", "sleep 30")
	SetNewGroup(cmd)
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	g := &Group{}
	g.Record(cmd.Process.Pid)
	t.Cleanup(func() {
		_ = g.Signal(cmd.Process.Pid, syscall.SIGKILL)
		_ = cmd.Wait()
	})
	return cmd, g
}

func TestGroupSignalsTheRecordedGroup(t *testing.T) {
	cmd, g := startLiveGroup(t)
	if g.Pgid() != cmd.Process.Pid {
		t.Fatalf("recorded group %d, want the leader pid %d", g.Pgid(), cmd.Process.Pid)
	}
	if err := g.Signal(cmd.Process.Pid, syscall.SIGTERM); err != nil {
		t.Fatalf("Signal = %v, want nil", err)
	}
	if err := cmd.Wait(); err == nil || cmd.ProcessState.Sys().(syscall.WaitStatus).Signal() != syscall.SIGTERM {
		t.Fatalf("leader ended with %v, want SIGTERM", err)
	}
}

// A child that does not lead its own group is never recorded, and an
// unrecorded Group refuses every signal.
func TestGroupRefusesAnUnrecordedGroup(t *testing.T) {
	cmd := exec.Command("/bin/sh", "-c", "sleep 30")
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = cmd.Process.Kill(); _ = cmd.Wait() })
	var g Group
	g.Record(cmd.Process.Pid)
	if g.Pgid() != 0 {
		t.Fatalf("recorded group %d for a child in our own group, want none", g.Pgid())
	}
	var re *GroupRefusedError
	if err := g.Signal(cmd.Process.Pid, syscall.SIGKILL); !errors.As(err, &re) {
		t.Fatalf("Signal on an unrecorded group = %v, want a refusal", err)
	}
}
