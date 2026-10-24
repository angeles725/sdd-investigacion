//go:build unix

package probe

import "syscall"

// accessExec is access(2) X_OK, the check behind `[ -x ]`.
func accessExec(path string) bool { return syscall.Access(path, 0x1) == nil }
