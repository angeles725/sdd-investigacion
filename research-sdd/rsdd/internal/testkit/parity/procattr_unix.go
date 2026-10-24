//go:build unix

package parity

import (
	"os/exec"
	"syscall"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/proc"
)

// setProcAttrs puts the child in its own process group and makes a timeout
// kill the whole group, so a script's grandchildren (a sleeping subshell, a
// background job) cannot keep the output pipes open and hang the runner.
// The returned func must run right after Start: it records the child's group
// so Cancel never derives it later from a possibly-reaped pid. Until it is
// recorded, Cancel kills only the child, through its pidfd-backed handle.
// Every group signal goes through the guard in core/proc.
func setProcAttrs(cmd *exec.Cmd) (started func()) {
	var g proc.Group
	proc.SetNewGroup(cmd)
	cmd.Cancel = func() error {
		if g.Pgid() == 0 {
			return cmd.Process.Kill()
		}
		return g.Signal(cmd.Process.Pid, syscall.SIGKILL)
	}
	return func() { g.Record(cmd.Process.Pid) }
}
