//go:build !unix

package runner

import "os/exec"

// isolate is a no-op off unix: there are no process groups to lead.
func isolate(*exec.Cmd) {}

// terminator returns the function that ends the started child; without process groups only the child itself is
// reached (a grandchild it started may survive a cancel).
func terminator(cmd *exec.Cmd) func() {
	return func() { _ = cmd.Process.Kill() }
}
