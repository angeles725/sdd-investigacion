//go:build !linux

package parity

// reapLeaked is a no-op off Linux: there is no /proc to scan, so a process
// that left its group (setsid) is neither detected nor killed there. The
// process-group kill of procattr_unix.go remains the only containment.
func reapLeaked(side, nonce string) []Problem { return nil }
