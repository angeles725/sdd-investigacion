//go:build unix

package kaitai

import "syscall"

// canExec is access(2) X_OK, the check behind `[ -x ]`.
func canExec(p string) bool { return syscall.Access(p, 0x1) == nil }
