//go:build !unix

package capa

import "os"

// openNoFollow has no O_NOFOLLOW here: the caller's lstat already refused a symlink, and the sandboxed
// capa run this reader serves only exists on Linux.
func openNoFollow(path string) (*os.File, error) { return os.Open(path) }
