//go:build unix

package java

import (
	"os"
	"syscall"
)

// canExec is access(2) X_OK, the check behind os.access(path, os.X_OK).
func canExec(p string) bool { return syscall.Access(p, 0x1) == nil }

// ownerUID is the owning uid of a stat result.
func ownerUID(fi os.FileInfo) (int, bool) {
	st, ok := fi.Sys().(*syscall.Stat_t)
	if !ok {
		return 0, false
	}
	return int(st.Uid), true
}

// lockParent is lock_publication_parent: an exclusive non-blocking flock on the output parent directory, held
// until the returned file is closed. A second publication in the same parent is refused.
func lockParent(parent string) (*os.File, error) {
	f, err := os.Open(parent)
	if err != nil {
		return nil, osFailure(err, parent)
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		_ = f.Close()
		return nil, fail("another publication is active in the output parent")
	}
	return f, nil
}

// truncateRegular is the ftruncate of output_inventory on a descriptor opened O_NOFOLLOW: only a regular file is
// cut, and the cut is made durable.
func truncateRegular(path string, size int64) error {
	f, err := os.OpenFile(path, os.O_RDWR|syscall.O_NOFOLLOW|syscall.O_CLOEXEC, 0)
	if err != nil {
		return osFailure(err, path)
	}
	defer f.Close()
	if fi, err := f.Stat(); err != nil || !fi.Mode().IsRegular() {
		return fail("adapter output is not a regular file")
	}
	if err := f.Truncate(size); err != nil {
		return osFailure(err, path)
	}
	if err := f.Sync(); err != nil {
		return osFailure(err, path)
	}
	return nil
}
