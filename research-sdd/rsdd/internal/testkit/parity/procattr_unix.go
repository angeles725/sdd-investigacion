//go:build unix

package parity

import (
	"errors"
	"fmt"
	"os/exec"
	"sync/atomic"
	"syscall"
)

// groupRefusedError is returned instead of signalling a process group the
// runner does not provably own.
type groupRefusedError struct {
	pgid   int
	reason string
}

func (e *groupRefusedError) Error() string {
	return fmt.Sprintf("parity: refusing to signal process group %d: %s", e.pgid, e.reason)
}

// checkGroup is the pure guard in front of every group signal. A group may
// be signalled only when it is a real group (> 1, so never kill(0) = our
// group nor kill(-1) = every process we may signal), it is the child's own
// group as recorded right after Start, and it is not our own group.
func checkGroup(pgid, childPgid, ownPgid int) error {
	if pgid <= 1 {
		return &groupRefusedError{pgid, "not a child process group"}
	}
	if pgid != childPgid {
		return &groupRefusedError{pgid, fmt.Sprintf("not the child's recorded group %d", childPgid)}
	}
	if pgid == ownPgid {
		return &groupRefusedError{pgid, "the runner's own group"}
	}
	return nil
}

// killGroup SIGKILLs process group pgid only if checkGroup accepts it and the
// group still exists; refused input never reaches a real signal. A group id
// cannot be reused while any member is alive, so the existence probe keeps a
// vanished group's id from being signalled.
func killGroup(pgid, childPgid int) error {
	if err := checkGroup(pgid, childPgid, syscall.Getpgrp()); err != nil {
		return err
	}
	if err := syscall.Kill(-pgid, 0); errors.Is(err, syscall.ESRCH) {
		return &groupRefusedError{pgid, "group no longer exists"}
	}
	return syscall.Kill(-pgid, syscall.SIGKILL)
}

// setProcAttrs puts the child in its own process group and makes a timeout
// kill the whole group, so a script's grandchildren (a sleeping subshell, a
// background job) cannot keep the output pipes open and hang the runner.
// The returned func must run right after Start: it records the child's group
// so Cancel never derives it later from a possibly-reaped pid. Until it is
// recorded, Cancel kills only the child, through its pidfd-backed handle.
func setProcAttrs(cmd *exec.Cmd) (started func()) {
	var recorded atomic.Int64
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error {
		childPgid := int(recorded.Load())
		if childPgid == 0 {
			return cmd.Process.Kill()
		}
		return killGroup(cmd.Process.Pid, childPgid)
	}
	return func() {
		pid := cmd.Process.Pid
		if pgid, err := syscall.Getpgid(pid); err == nil && pgid == pid {
			recorded.Store(int64(pgid))
		}
	}
}
