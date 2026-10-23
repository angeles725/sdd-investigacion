//go:build linux

package fsx

import (
	"os"
	"path/filepath"
	"strconv"
	"syscall"
)

func sysOpenRO(path string) (int, error) {
	return retryOpen(path, syscall.O_RDONLY|syscall.O_CLOEXEC|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0)
}

func sysOpenWONew(path string) (int, error) {
	return retryOpen(path, syscall.O_WRONLY|syscall.O_CREAT|syscall.O_EXCL|syscall.O_NOFOLLOW|syscall.O_CLOEXEC, 0o600)
}

func retryOpen(path string, flags int, mode uint32) (int, error) {
	for {
		fd, err := syscall.Open(path, flags, mode)
		if err != syscall.EINTR {
			return fd, err
		}
	}
}

func sysFstat(fd int) (Stat, error) {
	var s syscall.Stat_t
	if err := syscall.Fstat(fd, &s); err != nil {
		return Stat{}, err
	}
	return Stat{
		Dev: uint64(s.Dev), Ino: uint64(s.Ino), Mode: uint32(s.Mode), Size: s.Size,
		MtimeNs: s.Mtim.Nano(), CtimeNs: s.Ctim.Nano(),
	}, nil
}

func sysRead(fd int, p []byte) (int, error) {
	for {
		n, err := syscall.Read(fd, p)
		if err != syscall.EINTR {
			return n, err
		}
	}
}

func sysClose(fd int) error { return syscall.Close(fd) }

func sysSeekStart(fd int) error {
	_, err := syscall.Seek(fd, 0, 0)
	return err
}

// sysResolveFD returns the kernel's canonical path of the open fd (the
// /proc/self/fd link), falling back to the cleaned absolute path when /proc is
// unavailable.
func sysResolveFD(fd int, path string) string {
	if p, err := os.Readlink("/proc/self/fd/" + strconv.Itoa(fd)); err == nil {
		return p
	}
	if abs, err := filepath.Abs(path); err == nil {
		if r, err := filepath.EvalSymlinks(abs); err == nil {
			return r
		}
		return abs
	}
	return path
}
