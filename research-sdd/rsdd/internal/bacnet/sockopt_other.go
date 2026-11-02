//go:build !unix

package bacnet

import "syscall"

// reuseAddr is a no-op where SO_REUSEADDR has other semantics (Windows lets a second socket take the port).
func reuseAddr(_, _ string, _ syscall.RawConn) error { return nil }
