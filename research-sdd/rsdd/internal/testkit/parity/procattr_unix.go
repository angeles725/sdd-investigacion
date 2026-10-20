//go:build unix

package parity

import (
	"os/exec"
	"syscall"
)

// setProcAttrs puts the child in its own process group and makes a timeout
// kill the whole group, so a script's grandchildren (a sleeping subshell, a
// background job) cannot keep the output pipes open and hang the runner.
func setProcAttrs(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error { return syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL) }
}
