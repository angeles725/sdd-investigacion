//go:build linux

package ghidra

import "syscall"

// prSetChildSubreaper is PR_SET_CHILD_SUBREAPER: orphaned descendants of the sandbox reparent to this process
// instead of init, so reap() can collect them.
const prSetChildSubreaper = 36

func setSubreaper() { _, _, _ = syscall.RawSyscall(syscall.SYS_PRCTL, prSetChildSubreaper, 1, 0) }
