//go:build unix

package parity

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
func TestCheckGroupRefusesGroupsTheRunnerDoesNotOwn(t *testing.T) {
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
		err := checkGroup(c.pgid, c.childPgid, c.o)
		var re *groupRefusedError
		if !errors.As(err, &re) {
			t.Errorf("%s: checkGroup(%d, %d, %d) = %v, want a refusal", c.name, c.pgid, c.childPgid, c.o, err)
		}
	}
}

func TestCheckGroupAcceptsTheChildsOwnGroup(t *testing.T) {
	for _, pgid := range []int{2, 4242} {
		if err := checkGroup(pgid, pgid, 7); err != nil {
			t.Errorf("checkGroup(%d, %d, 7) = %v, want accepted", pgid, pgid, err)
		}
	}
}

// startGroup starts script as the leader of its own process group and
// waits for the leader to exit; it returns the recorded group id.
func startGroup(t *testing.T, script string) int {
	t.Helper()
	needSh(t)
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

func groupAlive(pgid int) bool {
	return !errors.Is(syscall.Kill(-pgid, 0), syscall.ESRCH)
}

func TestKillGroupRefusesAGroupThatNoLongerExists(t *testing.T) {
	pgid := startGroup(t, `exit 0`)
	err := killGroup(pgid, pgid)
	var re *groupRefusedError
	if !errors.As(err, &re) {
		t.Fatalf("killGroup on reaped group %d = %v, want a refusal", pgid, err)
	}
}

// The leader is already reaped while its background sleeper keeps the
// group alive: the kill must still reach the whole group.
func TestKillGroupKillsALiveChildGroup(t *testing.T) {
	pgid := startGroup(t, `sleep 30 & echo $! > pid; exit 0`)
	if !groupAlive(pgid) {
		t.Fatalf("group %d already gone: the sleeper should keep it alive", pgid)
	}
	if err := killGroup(pgid, pgid); err != nil {
		t.Fatalf("killGroup(%d) = %v, want nil", pgid, err)
	}
	deadline := time.Now().Add(5 * time.Second)
	for groupAlive(pgid) {
		if time.Now().After(deadline) {
			t.Fatalf("group %d survived killGroup", pgid)
		}
		time.Sleep(20 * time.Millisecond)
	}
}
