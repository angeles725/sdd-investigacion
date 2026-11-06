//go:build unix

package cleancheck

import (
	"io/fs"
	"syscall"
)

// ownerSupported says the platform reports the owner of a file.
const ownerSupported = true

// ownerOf is the uid that owns the entry.
func ownerOf(info fs.FileInfo) (uint64, bool) {
	st, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return 0, false
	}
	return uint64(st.Uid), true
}
