package adapter

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"syscall"
)

// PyError is a failure with the Python exception class it corresponds to (Msg is str(exc)).
type PyError struct{ Class, Msg string }

func (e *PyError) Error() string { return e.Msg }

func mfail(msg string) error { return &PyError{Class: "ManifestError", Msg: msg} }

func valueError(msg string) error { return &PyError{Class: "ValueError", Msg: msg} }

// strerror is the C library text Python puts after "[Errno N]".
var strerror = map[syscall.Errno]string{
	syscall.EPERM: "Operation not permitted", syscall.ENOENT: "No such file or directory", syscall.EIO: "Input/output error",
	syscall.EACCES: "Permission denied", syscall.EEXIST: "File exists", syscall.ENOTDIR: "Not a directory", syscall.EISDIR: "Is a directory",
	syscall.EINVAL: "Invalid argument", syscall.ENOSPC: "No space left on device", syscall.EROFS: "Read-only file system",
	syscall.ELOOP: "Too many levels of symbolic links", syscall.ENAMETOOLONG: "File name too long", syscall.EMFILE: "Too many open files",
	syscall.ENOTEMPTY: "Directory not empty", syscall.EXDEV: "Invalid cross-device link", syscall.EBUSY: "Device or resource busy", syscall.ENXIO: "No such device or address",
}

// osError renders err as str(OSError(errno, strerror, filename)): "[Errno 2] No such file or directory: 'x'".
// An error without an errno is reported by its own text.
func osError(err error, filename string) error {
	var errno syscall.Errno
	if !errors.As(err, &errno) {
		if errors.Is(err, fs.ErrNotExist) {
			errno = syscall.ENOENT
		} else {
			return &PyError{Class: "OSError", Msg: err.Error()}
		}
	}
	text, ok := strerror[errno]
	if !ok {
		text = errno.Error()
	}
	msg := fmt.Sprintf("[Errno %d] %s", int(errno), text)
	if filename != "" {
		msg += ": " + pyRepr(filename)
	}
	return &PyError{Class: osClass(errno), Msg: msg}
}

func osClass(errno syscall.Errno) string {
	switch errno {
	case syscall.ENOENT:
		return "FileNotFoundError"
	case syscall.EEXIST:
		return "FileExistsError"
	case syscall.EACCES, syscall.EPERM:
		return "PermissionError"
	case syscall.EISDIR:
		return "IsADirectoryError"
	case syscall.ENOTDIR:
		return "NotADirectoryError"
	}
	return "OSError"
}

func pathErr(err error, name string) error {
	var pe *os.PathError
	if errors.As(err, &pe) {
		return osError(pe.Err, name)
	}
	return osError(err, name)
}
