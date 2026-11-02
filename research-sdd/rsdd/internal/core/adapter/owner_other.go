//go:build !unix

package adapter

import "os"

// No owner information off Unix: the mount-point check fails closed.
func ownerUID(os.FileInfo) (int, bool) { return 0, false }
