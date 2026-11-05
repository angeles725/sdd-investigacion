//go:build unix

package runner

import (
	"os/exec"
	"syscall"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/proc"
)

// isolate makes the child lead its own process group, so a cancel reaches whatever it started too.
func isolate(cmd *exec.Cmd) { proc.SetNewGroup(cmd) }

// terminator returns the function that sends SIGTERM to the started child's group (the child leads it: isolate).
func terminator(cmd *exec.Cmd) func() {
	var g proc.Group
	g.Record(cmd.Process.Pid)
	return func() { _ = g.Signal(cmd.Process.Pid, syscall.SIGTERM) }
}
