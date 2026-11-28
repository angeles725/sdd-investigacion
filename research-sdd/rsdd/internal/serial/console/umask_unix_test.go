//go:build unix

package console

import "syscall"

// umaskSet sets the process umask and returns the previous one.
func umaskSet(m int) int { return syscall.Umask(m) }
