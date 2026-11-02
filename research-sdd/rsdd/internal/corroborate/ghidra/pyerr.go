package ghidra

import (
	"errors"
	"fmt"
	"io/fs"
	"strings"
	"syscall"
)

// strerror is the C library text Python prints after "[Errno N]".
var strerror = map[syscall.Errno]string{
	syscall.EPERM: "Operation not permitted", syscall.ENOENT: "No such file or directory",
	syscall.EACCES: "Permission denied", syscall.EEXIST: "File exists", syscall.ENOTDIR: "Not a directory",
	syscall.EISDIR: "Is a directory", syscall.EINVAL: "Invalid argument", syscall.ENOSPC: "No space left on device",
	syscall.EROFS: "Read-only file system", syscall.ELOOP: "Too many levels of symbolic links",
	syscall.ENAMETOOLONG: "File name too long", syscall.EMFILE: "Too many open files",
}

// osError renders err as str(OSError(errno, strerror, filename)): "[Errno 2] No such file or directory: 'x'".
// An error with no errno keeps its own text.
func osError(err error, filename string) error {
	var errno syscall.Errno
	if !errors.As(err, &errno) {
		if !errors.Is(err, fs.ErrNotExist) {
			return err
		}
		errno = syscall.ENOENT
	}
	text, ok := strerror[errno]
	if !ok {
		text = errno.Error()
	}
	msg := fmt.Sprintf("[Errno %d] %s", int(errno), text)
	if filename != "" {
		msg += ": " + reprPath(filename)
	}
	return errors.New(msg)
}

// reprPath is repr(str) for the path shapes that occur: single-quoted unless the text holds a quote.
func reprPath(s string) string {
	q := "'"
	if strings.Contains(s, "'") && !strings.Contains(s, `"`) {
		q = `"`
	}
	return q + strings.NewReplacer(`\`, `\\`, "\n", `\n`, "\t", `\t`, "\r", `\r`).Replace(s) + q
}

// errno is the syscall error behind err, if any.
func errno(err error) (syscall.Errno, bool) {
	var e syscall.Errno
	ok := errors.As(err, &e)
	return e, ok
}
