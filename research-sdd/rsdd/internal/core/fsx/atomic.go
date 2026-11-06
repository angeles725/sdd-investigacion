package fsx

import (
	"os"
	"path/filepath"
)

// WriteAtomic writes data to path through the sibling ".<name>.tmp": write,
// fsync, rename over path. A stale temp is truncated and reused; the temp is
// removed if any step fails. The file mode is 0666 &^ umask, as Python's
// Path.write_bytes creates it. The fixed temp name means two concurrent
// writers of one path share it: use WriteAtomicMode where that can happen.
func WriteAtomic(path string, data []byte) error {
	tmp := filepath.Join(filepath.Dir(path), "."+filepath.Base(path)+".tmp")
	f, err := os.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o666)
	if err != nil {
		return err
	}
	return finishAtomic(f, path, data, nil)
}

// WriteAtomicMode is WriteAtomic with an explicit file mode and a temp of its own: the result has exactly mode
// (the umask does not narrow it), set before the rename so no reader ever sees another mode, and the temp is a
// fresh ".<name>.<random>.tmp", so concurrent writers of one path never write through the same file.
func WriteAtomicMode(path string, data []byte, mode os.FileMode) error {
	f, err := os.CreateTemp(filepath.Dir(path), "."+filepath.Base(path)+".*.tmp")
	if err != nil {
		return err
	}
	return finishAtomic(f, path, data, &mode)
}

// finishAtomic writes data to the open temp, applies mode when one is given, syncs, closes and renames the temp
// over path. The temp is closed and removed if any step fails.
func finishAtomic(f *os.File, path string, data []byte, mode *os.FileMode) (err error) {
	defer func() {
		if err != nil {
			_ = f.Close()
			_ = os.Remove(f.Name())
		}
	}()
	if _, err = f.Write(data); err != nil {
		return err
	}
	if mode != nil {
		if err = f.Chmod(*mode); err != nil {
			return err
		}
	}
	if err = f.Sync(); err != nil {
		return err
	}
	if err = f.Close(); err != nil {
		return err
	}
	return os.Rename(f.Name(), path)
}
