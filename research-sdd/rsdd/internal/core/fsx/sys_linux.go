//go:build linux

package fsx

import (
	"syscall"
)

func sysOpenRO(path string) (int, error) {
	return retryOpen(path, syscall.O_RDONLY|syscall.O_CLOEXEC|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0)
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

func sysClose(fd int) error { return syscall.Close(fd) }
