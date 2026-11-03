// Package fsview is the read-only view of the filesystem the verify-* ports need. Relative paths resolve against
// Cwd (the cli.Stdio working directory), like the shell resolves them against its own; every path printed in a
// report is the one the caller wrote, never the resolved form.
package fsview

import (
	"io/fs"
	"os"
	"path/filepath"
	"strings"
)

// View resolves relative paths against Cwd.
type View struct{ Cwd string }

// At is the path p made absolute against Cwd; an empty or absolute p is returned as written.
func (v View) At(p string) string {
	if p == "" || strings.HasPrefix(p, "/") || filepath.IsAbs(p) {
		return p
	}
	return v.Cwd + "/" + p
}

// Stat is os.Stat of At(p): symlinks followed.
func (v View) Stat(p string) (fs.FileInfo, error) { return os.Stat(v.At(p)) }

// IsDir is `[ -d p ]`, IsFile is `[ -f p ]`: symlinks followed.
func (v View) IsDir(p string) bool {
	st, err := v.Stat(p)
	return err == nil && st.IsDir()
}

// IsFile is `[ -f p ]`.
func (v View) IsFile(p string) bool {
	st, err := v.Stat(p)
	return err == nil && st.Mode().IsRegular()
}

// IsSymlink is `[ -L p ]`.
func (v View) IsSymlink(p string) bool {
	st, err := os.Lstat(v.At(p))
	return err == nil && st.Mode()&fs.ModeSymlink != 0
}

// Read is os.ReadFile of At(p).
func (v View) Read(p string) ([]byte, error) { return os.ReadFile(v.At(p)) }

// Readable is `[ -r p ]` for a directory or file: it can be opened for reading.
func (v View) Readable(p string) bool {
	f, err := os.Open(v.At(p))
	if err != nil {
		return false
	}
	f.Close()
	return true
}
