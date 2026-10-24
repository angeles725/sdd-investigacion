//go:build unix

package proc

import (
	"errors"
	"fmt"
	"os/exec"
	"sync/atomic"
	"syscall"
)

// GroupRefusedError is returned instead of signalling a process group the
// caller does not provably own. It unwraps to ErrGroupGone when the refusal
// is only that the group has no member left.
type GroupRefusedError struct {
	Pgid   int
	Reason string
	gone   bool
}

func (e *GroupRefusedError) Error() string {
	return fmt.Sprintf("proc: refusing to signal process group %d: %s", e.Pgid, e.Reason)
}

func (e *GroupRefusedError) Unwrap() error {
	if e.gone {
		return ErrGroupGone
	}
	return nil
}

// CheckGroup is the pure guard in front of every group signal. A group may
// be signalled only when it is a real group (> 1, so never kill(0) = our
// group nor kill(-1) = every process we may signal), it is the child's own
// group as recorded right after Start, and it is not our own group.
func CheckGroup(pgid, childPgid, ownPgid int) error {
	if pgid <= 1 {
		return &GroupRefusedError{Pgid: pgid, Reason: "not a child process group"}
	}
	if pgid != childPgid {
		return &GroupRefusedError{Pgid: pgid, Reason: fmt.Sprintf("not the child's recorded group %d", childPgid)}
	}
	if pgid == ownPgid {
		return &GroupRefusedError{Pgid: pgid, Reason: "the caller's own group"}
	}
	return nil
}

// SignalGroup sends sig to process group pgid only if CheckGroup accepts it
// and the group still exists; refused input never reaches a real signal. A
// group id cannot be reused while any member is alive, so the existence probe
// keeps a vanished group's id from being signalled. A group that empties
// between the probe and the signal reports the same ErrGroupGone refusal.
func SignalGroup(pgid, childPgid int, sig syscall.Signal) error {
	if err := CheckGroup(pgid, childPgid, syscall.Getpgrp()); err != nil {
		return err
	}
	gone := &GroupRefusedError{Pgid: pgid, Reason: "group no longer exists", gone: true}
	if !GroupAlive(pgid) {
		return gone
	}
	err := syscall.Kill(-pgid, sig)
	if errors.Is(err, syscall.ESRCH) {
		return gone
	}
	return err
}

// KillGroup is SignalGroup with SIGKILL.
func KillGroup(pgid, childPgid int) error { return SignalGroup(pgid, childPgid, syscall.SIGKILL) }

// GroupAlive reports whether process group pgid still has a member. It sends
// signal 0 (an existence probe, never a delivery) and is only meaningful for
// pgid > 1.
func GroupAlive(pgid int) bool {
	return !errors.Is(syscall.Kill(-pgid, 0), syscall.ESRCH)
}

// Group is the process group of one started child, recorded right after
// Start so a later signal never derives it from a possibly-reaped pid.
type Group struct{ recorded atomic.Int64 }

// SetNewGroup makes cmd start as the leader of a new process group, so a
// signal to the group also reaches its grandchildren.
func SetNewGroup(cmd *exec.Cmd) {
	if cmd.SysProcAttr == nil {
		cmd.SysProcAttr = &syscall.SysProcAttr{}
	}
	cmd.SysProcAttr.Setpgid = true
}

// Record stores pid's group when pid leads its own group; call it right
// after Start. Otherwise nothing is recorded and Signal refuses.
func (g *Group) Record(pid int) {
	if pgid, err := syscall.Getpgid(pid); err == nil && pgid == pid {
		g.recorded.Store(int64(pgid))
	}
}

// Pgid returns the recorded group, or 0 when none was recorded.
func (g *Group) Pgid() int { return int(g.recorded.Load()) }

// Signal sends sig to the group led by pid through SignalGroup, against the
// recorded group.
func (g *Group) Signal(pid int, sig syscall.Signal) error { return SignalGroup(pid, g.Pgid(), sig) }
