//go:build unix

package adapter

import "syscall"

// canExec reports whether the caller may execute path, as os.access(X_OK).
func canExec(path string) bool { return syscall.Access(path, 0x1) == nil }
