package fsx

import (
	"errors"
	"os"
	"path/filepath"
	"syscall"
)

// renameat2 flags and the AT_FDCWD directory descriptor.
const (
	AtFDCWD       = -100
	FlagNoReplace = 1
	FlagExchange  = 2
)

// Test seam: the raw renameat2 call.
var (
	renameat2Fn = sysRenameat2
)

// Renameat2 calls renameat2(2). ENOSYS and EINVAL (no kernel support, or a
// filesystem that does not take the flag) are ErrUnavailable; there is never a
// fallback to a plain rename. Every other failure is an *os.LinkError carrying
// the errno, so EEXIST satisfies errors.Is(err, fs.ErrExist).
func Renameat2(oldDirFD int, oldPath string, newDirFD int, newPath string, flags uint) error {
	if containsNUL(oldPath) || containsNUL(newPath) {
		return &os.LinkError{Op: "renameat2", Old: oldPath, New: newPath, Err: syscall.EINVAL}
	}
	err := renameat2Fn(oldDirFD, oldPath, newDirFD, newPath, flags)
	switch {
	case err == nil:
		return nil
	case errors.Is(err, ErrUnavailable):
		return err
	case errors.Is(err, syscall.ENOSYS), errors.Is(err, syscall.EINVAL):
		return &Error{Kind: ErrUnavailable, Path: newPath, Err: err}
	}
	return &os.LinkError{Op: "renameat2", Old: oldPath, New: newPath, Err: err}
}

func containsNUL(s string) bool {
	for i := 0; i < len(s); i++ {
		if s[i] == 0 {
			return true
		}
	}
	return false
}

// RenameNoReplace renames oldPath to newPath, failing with EEXIST if newPath
// exists (RENAME_NOREPLACE).
func RenameNoReplace(oldPath, newPath string) error {
	return Renameat2(AtFDCWD, oldPath, AtFDCWD, newPath, FlagNoReplace)
}

// Publish moves stage to dest without ever replacing dest: an existing dest is
// an EEXIST error, an unsupported kernel is ErrUnavailable. It does not sync
// the parent directory; call SyncDir for durability.
func Publish(stage, dest string) error { return RenameNoReplace(stage, dest) }

// SyncDir fsyncs a directory so a rename into it is durable.
func SyncDir(path string) error {
	fd, err := sysOpenDir(path)
	if err != nil {
		return &os.PathError{Op: "open", Path: path, Err: err}
	}
	defer func() { _ = sysClose(fd) }()
	if err := sysFsync(fd); err != nil {
		return &os.PathError{Op: "fsync", Path: path, Err: err}
	}
	return nil
}

// WriteAtomic writes data to path through the sibling ".<name>.tmp": write,
// fsync, rename over path. A stale temp is truncated and reused; the temp is
// removed if any step fails. The file mode is 0666 &^ umask, as Python's
// Path.write_bytes creates it.
func WriteAtomic(path string, data []byte) (err error) {
	tmp := filepath.Join(filepath.Dir(path), "."+filepath.Base(path)+".tmp")
	f, err := os.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o666)
	if err != nil {
		return err
	}
	defer func() {
		if err != nil {
			_ = os.Remove(tmp)
		}
	}()
	if _, err = f.Write(data); err != nil {
		_ = f.Close()
		return err
	}
	if err = f.Sync(); err != nil {
		_ = f.Close()
		return err
	}
	if err = f.Close(); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}
