//go:build unix

package verify

import "syscall"

// accessRX is `[ -r p ] && [ -x p ]`: access(2) with the process's real ids, as test(1) asks it.
func accessRX(p string) bool {
	return syscall.Access(p, 4) == nil && syscall.Access(p, 1) == nil
}
