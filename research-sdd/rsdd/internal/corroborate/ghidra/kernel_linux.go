//go:build linux

package ghidra

import (
	"os"
	"strings"
)

// kernelRelease is platform.release() (uname -r).
func kernelRelease() string {
	b, err := os.ReadFile("/proc/sys/kernel/osrelease")
	if err != nil {
		return "unknown"
	}
	return strings.TrimSpace(string(b))
}
