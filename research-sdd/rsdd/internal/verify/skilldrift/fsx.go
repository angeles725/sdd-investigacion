package skilldrift

import (
	"bytes"
	"os"
)

// The file tests of the scripts, `[ -L ]`, `[ -e ]`, `[ -f ]`, `[ -d ]`, `[ -r ]`, `[ -x ]` and `cmp -s`, with the same
// symlink semantics: -e/-f/-d follow links, -L does not, and an empty path names nothing.

func isLink(p string) bool {
	st, err := os.Lstat(p)
	return err == nil && st.Mode()&os.ModeSymlink != 0
}

func exists(p string) bool { _, err := os.Stat(p); return p != "" && err == nil }

func isFile(p string) bool {
	st, err := os.Stat(p)
	return p != "" && err == nil && st.Mode().IsRegular()
}

func isDir(p string) bool {
	st, err := os.Stat(p)
	return p != "" && err == nil && st.IsDir()
}

func isReadable(p string) bool { return p != "" && canAccess(p, 0x4) }

func isExec(p string) bool { return p != "" && canAccess(p, 0x1) }

// sameBytes is `cmp -s a b` succeeding: both readable and byte-identical. An unreadable side is a difference, as cmp's exit 2
// is not 0.
func sameBytes(a, b string) bool {
	x, err := os.ReadFile(a)
	if err != nil {
		return false
	}
	y, err := os.ReadFile(b)
	return err == nil && bytes.Equal(x, y)
}
