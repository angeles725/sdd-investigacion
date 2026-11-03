//go:build unix

package sweep

import "syscall"

// isExecutable is `[ -x f ]`: access(2) with X_OK for the real caller, so the answer is the shell's.
func isExecutable(f string) bool { return syscall.Access(f, 1) == nil }
