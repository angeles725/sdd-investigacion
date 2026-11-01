//go:build unix

package adapter

import "syscall"

// The descriptor-level primitives of the manifest code. The adapters only run on Linux, so the
// other platforms get stubs (sys_other.go) that fail with ENOSYS and keep the module building.

func statFD(fd int) (statTuple, error) {
	var st syscall.Stat_t
	if err := syscall.Fstat(fd, &st); err != nil {
		return statTuple{}, err
	}
	return statOf(&st), nil
}

func statSys(path string) (statTuple, error) {
	var st syscall.Stat_t
	if err := syscall.Stat(path, &st); err != nil {
		return statTuple{}, err
	}
	return statOf(&st), nil
}

// openNoFollow opens path read-only without following a final symlink. O_NONBLOCK keeps a
// writerless FIFO from blocking the open; a regular file is unaffected.
func openNoFollow(path string) (int, error) {
	for {
		fd, err := syscall.Open(path, syscall.O_RDONLY|syscall.O_CLOEXEC|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0)
		if err != syscall.EINTR {
			return fd, err
		}
	}
}

func readFD(fd int, buf []byte) (int, error) {
	for {
		n, err := syscall.Read(fd, buf)
		if err != syscall.EINTR {
			return n, err
		}
	}
}

func closeFD(fd int) error { return syscall.Close(fd) }

// createExcl creates path (mode 0600) and fails if it exists, like mkstemp's open.
func createExcl(path string) (int, error) {
	return syscall.Open(path, syscall.O_RDWR|syscall.O_CREAT|syscall.O_EXCL|syscall.O_CLOEXEC, 0o600)
}

func writeAll(fd int, b []byte) error {
	for len(b) > 0 {
		n, err := syscall.Write(fd, b)
		if err == syscall.EINTR {
			continue
		}
		if err != nil {
			return err
		}
		b = b[n:]
	}
	return nil
}

func syncFD(fd int) error { return syscall.Fsync(fd) }

// renameFile is rename(2); os.Rename would report EEXIST for a directory target where the kernel
// (and Python's os.replace) say EISDIR.
func renameFile(oldPath, newPath string) error { return syscall.Rename(oldPath, newPath) }
