//go:build unix

package skilldrift

import (
	"bytes"
	"errors"
	"os"
	"os/exec"
	"syscall"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/proc"
)

// Bounded run of `research-sdd-install.sh --verify` (the script's `timeout "$vt" "$vcmd" --verify </dev/null >"$vf" 2>&1`).
//
// The command runs as the leader of its own process group with stdin on /dev/null and stdout and stderr on one temp FILE (never
// a pipe: a stalled grandchild such as `git rev-list` or a hashing pipe on a slow filesystem would keep a pipe open and defeat
// the bound). When the bound expires the whole group is stopped, TERM first and KILL after a short grace, through core/proc's
// guarded signalling (it refuses any group that is not the child's own); the run is then reported as timed out (rc 124, as
// timeout(1) does). A real exit 124, 137 or 143 of the command is a plain exit code, never a timeout.

// verifyGrace is how long the group gets between TERM and KILL.
const verifyGrace = 500 * time.Millisecond

type verifyOutcome struct {
	out      string // combined stdout+stderr, trailing newlines removed
	rc       int    // the exit code (124 when the bound expired)
	timedOut bool
	noTemp   bool // the temp file could not be made: the run is bounded, but a stalled grandchild is not
}

// runVerify runs vcmd --verify for at most vt seconds.
func runVerify(e envView, vcmd, dir string, vt int) verifyOutcome {
	var res verifyOutcome
	var buf bytes.Buffer
	f, err := os.CreateTemp(e.tmpDir(), "tmp.")
	c := exec.Command(vcmd, "--verify")
	c.Env, c.Dir = e.environ(), dir
	if err != nil {
		res.noTemp = true
		c.Stdout, c.Stderr = &buf, &buf
		c.WaitDelay = verifyGrace
	} else {
		defer os.Remove(f.Name())
		defer f.Close()
		c.Stdout, c.Stderr = f, f
	}
	proc.SetNewGroup(c)
	if err := c.Start(); err != nil {
		res.rc = 126
		if errors.Is(err, os.ErrNotExist) {
			res.rc = 127
		}
		return res
	}
	var g proc.Group
	g.Record(c.Process.Pid)
	done := make(chan error, 1)
	go func() { done <- c.Wait() }()
	timer := time.NewTimer(time.Duration(vt) * time.Second)
	defer timer.Stop()
	var werr error
	select {
	case werr = <-done:
	case <-timer.C:
		res.timedOut = true
		_ = g.Signal(c.Process.Pid, syscall.SIGTERM)
		select {
		case werr = <-done:
		case <-time.After(verifyGrace):
			_ = g.Signal(c.Process.Pid, syscall.SIGKILL)
			werr = <-done
		}
	}
	res.rc = exitCode(c, werr)
	if res.timedOut {
		res.rc = 124
	}
	if res.noTemp {
		res.out = trimNL(buf.String())
	} else if b, rerr := os.ReadFile(f.Name()); rerr == nil {
		res.out = trimNL(string(b))
	}
	return res
}

// exitCode is the shell's view of a finished command: its status, or 128+N for signal N.
func exitCode(c *exec.Cmd, err error) int {
	if c.ProcessState == nil {
		return 127
	}
	if ws, ok := c.ProcessState.Sys().(syscall.WaitStatus); ok && ws.Signaled() {
		return 128 + int(ws.Signal())
	}
	if err != nil {
		var ee *exec.ExitError
		if errors.As(err, &ee) {
			return ee.ExitCode()
		}
	}
	return c.ProcessState.ExitCode()
}
