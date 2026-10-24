//go:build !unix

package parity

import "os/exec"

// setProcAttrs is a no-op off unix: exec's default Cancel kills the child and
// WaitDelay bounds the wait for its pipes.
func setProcAttrs(*exec.Cmd) (started func()) { return func() {} }
