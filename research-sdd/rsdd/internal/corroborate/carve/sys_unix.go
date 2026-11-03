//go:build linux || darwin

package carve

import (
	"os"
	"syscall"
)

// statTuple is the identity the script compares before and after a read: (dev, ino, mode, size, mtime_ns,
// ctime_ns).
type statTuple struct {
	dev, ino         uint64
	mode             uint32
	size             int64
	mtimeNs, ctimeNs int64
}

// tupleOf is the identity tuple of fi; the zero tuple when the platform gives no stat record.
func tupleOf(fi os.FileInfo) statTuple {
	if st, ok := fi.Sys().(*syscall.Stat_t); ok {
		return statOf(st)
	}
	return statTuple{}
}

// owner is the uid and link count of fi; ok is false when the platform gives no stat record.
func owner(fi os.FileInfo) (uid, nlink uint64, ok bool) {
	st, ok := fi.Sys().(*syscall.Stat_t)
	if !ok {
		return 0, 0, false
	}
	return uint64(st.Uid), uint64(st.Nlink), true
}

// openNoFollow opens path read-only without following a final symlink. O_NONBLOCK keeps a writerless FIFO from
// blocking the open; a regular file is unaffected.
func openNoFollow(path string) (*os.File, error) {
	for {
		fd, err := syscall.Open(path, syscall.O_RDONLY|syscall.O_CLOEXEC|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0)
		if err == syscall.EINTR {
			continue
		}
		if err != nil {
			return nil, &os.PathError{Op: "open", Path: path, Err: err}
		}
		return os.NewFile(uintptr(fd), path), nil
	}
}
