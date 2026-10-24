//go:build darwin

package proc

import "syscall"

// platformCeiling caps nofile at kern.maxfilesperproc: darwin's setrlimit
// refuses a NOFILE above it with EINVAL even under an unlimited hard limit
// (the runtime clamps its own raise the same way, syscall/rlimit_darwin.go).
// If the sysctl cannot be read there is no ceiling, and an EINVAL is the
// helper's typed 125 failure.
func platformCeiling(res int) (uint64, bool) {
	if res != syscall.RLIMIT_NOFILE {
		return 0, false
	}
	n, err := syscall.SysctlUint32("kern.maxfilesperproc")
	if err != nil {
		return 0, false
	}
	return uint64(n), true
}
