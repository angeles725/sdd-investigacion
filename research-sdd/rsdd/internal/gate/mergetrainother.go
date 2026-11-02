//go:build !unix

package gate

import (
	"os"
	"os/exec"
	"time"
)

// Off unix the train has no flock or process groups: the lock is always taken and a signal is not forwarded.
func mtFlock(*os.File, int, func(time.Duration)) bool { return true }
func mtProcAttr(*exec.Cmd)                            {}
func mtSignalGroup(*exec.Cmd, bool)                   {}
func mtExitCode(ps *os.ProcessState) int {
	if ps == nil {
		return 127
	}
	return ps.ExitCode()
}
