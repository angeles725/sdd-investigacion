//go:build !unix

package cleancheck

import "io/fs"

// ownerOf has no answer where files carry no uid: nothing is then reported as owned (the instrument must not
// suggest deleting what the operator may not be able to delete).
func ownerOf(fs.FileInfo) (uint64, bool) { return 0, false }
