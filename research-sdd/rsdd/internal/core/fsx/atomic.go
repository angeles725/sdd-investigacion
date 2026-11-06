package fsx

import (
	"os"
	"path/filepath"
)

// WriteAtomic writes data to path through the sibling ".<name>.tmp": write,
// fsync, rename over path. A stale temp is truncated and reused; the temp is
// removed if any step fails. The file mode is 0666 &^ umask, as Python's
// Path.write_bytes creates it.
func WriteAtomic(path string, data []byte) error { return writeAtomic(path, data, 0o666, false) }

// WriteAtomicMode is WriteAtomic with an explicit file mode: the result has exactly mode (the umask does not
// narrow it, and a stale temp's mode does not leak), set before the rename so no reader ever sees another mode.
func WriteAtomicMode(path string, data []byte, mode os.FileMode) error {
	return writeAtomic(path, data, mode, true)
}

// writeAtomic is the shared body: exactMode chmods the temp to mode before the rename; otherwise the creation
// mode is subject to the umask.
func writeAtomic(path string, data []byte, mode os.FileMode, exactMode bool) (err error) {
	tmp := filepath.Join(filepath.Dir(path), "."+filepath.Base(path)+".tmp")
	f, err := os.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, mode)
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
	if exactMode {
		if err = f.Chmod(mode); err != nil {
			_ = f.Close()
			return err
		}
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
