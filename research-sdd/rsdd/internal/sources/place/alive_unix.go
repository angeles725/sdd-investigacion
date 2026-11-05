//go:build unix

package place

import (
	"math"
	"strconv"
	"syscall"
)

// Alive is positive liveness: the pid answers signal 0 (EPERM, another user's process, still means alive).
// A pid that does not name one process (unparsable, 0, or above the 32-bit pid range) is assumed alive: debris is
// only removed on proof, and kill(0, 0) or a truncated pid would answer for a different process.
func Alive(pid string) bool {
	n, err := strconv.ParseInt(pid, 10, 64)
	if err != nil || n <= 0 || n > math.MaxInt32 {
		return true
	}
	err = syscall.Kill(int(n), 0)
	return err == nil || err == syscall.EPERM
}
