//go:build !unix

package java

import "os"

// canExec has no execute bit to read here: a regular file counts.
func canExec(string) bool { return true }

// ownerUID has no owner to read here.
func ownerUID(os.FileInfo) (int, bool) { return 0, false }

// lockParent cannot lock a directory here; publication needs renameat2, which is Linux-only anyway.
func lockParent(string) (*os.File, error) {
	return nil, fail("atomic publication is unavailable on this platform")
}

// truncateRegular cuts a regular file to size.
func truncateRegular(path string, size int64) error {
	f, err := os.OpenFile(path, os.O_RDWR, 0)
	if err != nil {
		return osFailure(err, path)
	}
	defer f.Close()
	if fi, err := f.Stat(); err != nil || !fi.Mode().IsRegular() {
		return fail("adapter output is not a regular file")
	}
	if err := f.Truncate(size); err != nil {
		return osFailure(err, path)
	}
	return f.Sync()
}
