//go:build !unix

package native

import "os"

// ownerUID has no owner information off Unix: the trust and mount-point checks fail closed.
func ownerUID(os.FileInfo) (int, bool) { return 0, false }
