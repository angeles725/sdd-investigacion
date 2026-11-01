//go:build !unix

package parity

import (
	"os"
	"os/exec"
)

// setProcAttrs is a no-op off unix: exec's default Cancel kills the child and
// WaitDelay bounds the wait for its pipes.
func setProcAttrs(*exec.Cmd) (started func()) { return func() {} }

// endedBySigkill cannot read a signal from the wait status off unix, so a
// Cancel that fired is taken as the kill (the pre-unix-check behaviour).
func endedBySigkill(*os.ProcessState) bool { return true }
