//go:build unix

package skilldrift

import "syscall"

// canAccess is access(2): bash's [ -r ] and [ -x ].
func canAccess(path string, mode uint32) bool { return syscall.Access(path, mode) == nil }
