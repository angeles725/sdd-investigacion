//go:build linux && !amd64 && !arm64

package fsx

// sysNumRenameat2 is unknown for this architecture; renameat2 reports ENOSYS
// (ErrUnavailable) rather than guessing a syscall number.
const sysNumRenameat2 = 0
