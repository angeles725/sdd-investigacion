//go:build !unix

package kitmaint

import (
	"os"
	"os/exec"
	"time"
)

// Off unix there is no flock or process group: the lock is always taken and a signal is not forwarded.
func Flock(*os.File, int, func(time.Duration)) bool { return true }
func ProcAttr(*exec.Cmd)                            {}
func SignalGroup(*exec.Cmd, bool)                   {}

// ExitCode is the shell's code for a finished child.
func ExitCode(ps *os.ProcessState) int {
	if ps == nil {
		return 127
	}
	return ps.ExitCode()
}
