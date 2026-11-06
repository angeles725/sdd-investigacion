//go:build unix

package place

import (
	"strconv"
	"syscall"
)

// Alive is positive liveness: the pid answers signal 0 (EPERM, another user's process, still means alive).
// A pid that does not name one process (unparsable, signed, 0, or above the 31-bit pid range) is assumed alive:
// debris is only removed on proof, and kill(0, 0) or a truncated pid would answer for a different process.
func Alive(pid string) bool {
	n, err := strconv.ParseUint(pid, 10, 31)
	if err != nil || n == 0 {
		return true
	}
	err = syscall.Kill(int(n), 0)
	return err == nil || err == syscall.EPERM
}
