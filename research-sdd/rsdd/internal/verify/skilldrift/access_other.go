//go:build !unix

package skilldrift

import "os"

// canAccess without access(2): existence only.
func canAccess(path string, _ uint32) bool { _, err := os.Stat(path); return err == nil }
