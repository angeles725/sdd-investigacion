//go:build unix

package bacnet

import "syscall"

// reuseAddr sets SO_REUSEADDR before bind, as the legacy tool does (a failure is ignored there too).
func reuseAddr(_, _ string, c syscall.RawConn) error {
	return c.Control(func(fd uintptr) {
		_ = syscall.SetsockoptInt(int(fd), syscall.SOL_SOCKET, syscall.SO_REUSEADDR, 1)
	})
}
