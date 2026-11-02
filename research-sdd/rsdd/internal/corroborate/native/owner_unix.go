//go:build unix

package native

import (
	"os"
	"syscall"
)

// ownerUID is the owning user id of fi.
func ownerUID(fi os.FileInfo) (int, bool) {
	st, ok := fi.Sys().(*syscall.Stat_t)
	if !ok {
		return 0, false
	}
	return int(st.Uid), true
}
