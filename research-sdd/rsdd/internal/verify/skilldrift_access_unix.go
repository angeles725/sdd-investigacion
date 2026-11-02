//go:build unix

package verify

import "syscall"

// readableOS is `[ -r p ]`: access(2) with the process's real ids, as test(1) asks it.
func readableOS(p string) bool { return syscall.Access(p, 4) == nil }

// executableOS is `[ -x p ]`: access(2) with X_OK (a directory with search permission counts, as in test(1)).
func executableOS(p string) bool { return syscall.Access(p, 1) == nil }
