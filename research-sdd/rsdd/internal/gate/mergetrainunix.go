//go:build unix

package gate

import (
	"os"
	"os/exec"
	"syscall"
	"time"
)

// mtFlock is `flock -w SECONDS fd`: an exclusive lock on f, polled every 50 ms for at most SECONDS seconds
// (0 tries once). It reports whether the lock was taken.
func mtFlock(f *os.File, seconds int, sleep func(time.Duration)) bool {
	const step = 50 * time.Millisecond
	for waited := time.Duration(0); ; waited += step {
		err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
		if err == nil {
			return true
		}
		if err != syscall.EWOULDBLOCK && err != syscall.EINTR {
			return false
		}
		if waited >= time.Duration(seconds)*time.Second {
			return false
		}
		sleep(step)
	}
}

// mtProcAttr puts the gate command in its own process group so a signal reaches whatever it started.
func mtProcAttr(c *exec.Cmd) { c.SysProcAttr = &syscall.SysProcAttr{Setpgid: true} }

// mtSignalGroup sends TERM (KILL when kill) to the gate command's process group.
func mtSignalGroup(c *exec.Cmd, kill bool) {
	sig := syscall.SIGTERM
	if kill {
		sig = syscall.SIGKILL
	}
	if c.Process != nil {
		_ = syscall.Kill(-c.Process.Pid, sig)
	}
}

// mtExitCode is the shell's code for a finished child: the status, or 128+N for signal N.
func mtExitCode(ps *os.ProcessState) int {
	if ps == nil {
		return 127
	}
	if ws, ok := ps.Sys().(syscall.WaitStatus); ok && ws.Signaled() {
		return 128 + int(ws.Signal())
	}
	return ps.ExitCode()
}
