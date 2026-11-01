//go:build unix

package hook

import "syscall"

// The access(2) modes bash's `[ -r ]` and `[ -x ]` ask for.
const (
	accR = 4
	accX = 1
)

// accessOK is access(2) with the real ids, which is what the shell tests use: for root a file is executable when
// any execute bit is set, and every file is readable.
func accessOK(path string, mode uint32) bool { return syscall.Access(path, mode) == nil }
