//go:build unix

package capa

import (
	"os"
	"syscall"
)

// openNoFollow opens path read-only and refuses a symlink at open time (O_NOFOLLOW), closing the window
// between the caller's lstat and the open.
func openNoFollow(path string) (*os.File, error) {
	fd, err := syscall.Open(path, syscall.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_CLOEXEC, 0)
	if err != nil {
		return nil, err
	}
	return os.NewFile(uintptr(fd), path), nil
}
