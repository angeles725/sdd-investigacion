//go:build !unix

package adapter

import "os"

// canExec has no access(2) here; the adapters only run on Linux, so any
// existing path counts as executable and the port still builds.
func canExec(path string) bool { _, err := os.Stat(path); return err == nil }
