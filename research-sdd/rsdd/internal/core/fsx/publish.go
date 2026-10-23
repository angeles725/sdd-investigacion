package fsx

import (
	"os"
	"path/filepath"
)

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
