package decompile

import (
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// fatal aborts the run with exit 1, as `set -e` aborted the script on a failed mkdir or cp.
type fatal struct{ err error }

// must aborts the run on err.
func (j *job) must(err error) {
	if err != nil {
		panic(fatal{err})
	}
}

func isFile(p string) bool {
	fi, err := os.Stat(p)
	return err == nil && fi.Mode().IsRegular()
}

func isDir(p string) bool {
	fi, err := os.Stat(p)
	return err == nil && fi.IsDir()
}

// walk calls fn for every entry below root (root itself excluded), in lexical order, skipping what cannot be read.
func walk(root string, fn func(rel string, d fs.DirEntry)) {
	_ = filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
		if err != nil || p == root {
			return nil
		}
		rel, _ := filepath.Rel(root, p)
		fn(rel, d)
		return nil
	})
}

// find lists, sorted, the entries below root (of any type) accepted by keep.
func find(root string, keep func(rel string, d fs.DirEntry) bool) []string {
	var out []string
	walk(root, func(rel string, d fs.DirEntry) {
		if keep(rel, d) {
			out = append(out, rel)
		}
	})
	sort.Strings(out)
	return out
}

// hasJava: at least one .java regular file exists below dir.
func hasJava(dir string) bool {
	return len(find(dir, func(rel string, d fs.DirEntry) bool {
		return d.Type().IsRegular() && strings.HasSuffix(rel, ".java")
	})) > 0
}

func isClassName(rel string, _ fs.DirEntry) bool { return strings.HasSuffix(rel, ".class") }

// copyFile copies a regular file keeping its mode and mtime (cp -p).
func copyFile(src, dst string) error {
	fi, err := os.Stat(src)
	if err != nil {
		return err
	}
	b, err := os.ReadFile(src)
	if err != nil {
		return err
	}
	for _, step := range []func() error{
		func() error { return os.WriteFile(dst, b, fi.Mode().Perm()) },
		func() error { return os.Chmod(dst, fi.Mode().Perm()) }, // WriteFile applies the umask; cp -p does not
		func() error { return os.Chtimes(dst, fi.ModTime(), fi.ModTime()) },
	} {
		if err := step(); err != nil {
			return err
		}
	}
	return nil
}

// copyTree merges the directory src into dst the way `cp -a src/. dst/` does: every file AND every directory,
// src itself and the ones dst already has included, takes the source's permissions and mtime. A directory's
// attributes are set once everything is copied, since entering a file into it moves its mtime.
func copyTree(src, dst string) error {
	dirs := map[string]os.FileInfo{}
	var failed error
	attrs := func(rel string) {
		if fi, err := os.Stat(filepath.Join(src, rel)); err == nil {
			dirs[rel] = fi
		} else {
			failed = err
		}
	}
	attrs(".")
	walk(src, func(rel string, d fs.DirEntry) {
		switch {
		case failed != nil:
		case d.IsDir():
			failed = os.MkdirAll(filepath.Join(dst, rel), 0o755)
			attrs(rel)
		case d.Type().IsRegular():
			failed = copyFile(filepath.Join(src, rel), filepath.Join(dst, rel))
		}
	})
	for rel, fi := range dirs {
		if failed == nil {
			failed = os.Chmod(filepath.Join(dst, rel), fi.Mode().Perm())
		}
		if failed == nil {
			failed = os.Chtimes(filepath.Join(dst, rel), fi.ModTime(), fi.ModTime())
		}
	}
	return failed
}

// discardRunOutput drops what THIS run wrote: its files, then the directories that became empty. A
// pre-existing file that merely falls inside the stamp's backdate window is NOT this run's and is kept.
func (j *job) discardRunOutput() {
	var dirs []string
	walk(j.outDir(), func(rel string, d fs.DirEntry) {
		p := filepath.Join(j.outDir(), rel)
		switch {
		case d.IsDir():
			dirs = append(dirs, p)
		case d.Type().IsRegular() && j.isFresh(p):
			_ = os.Remove(p)
		}
	})
	sort.Sort(sort.Reverse(sort.StringSlice(dirs))) // a directory sorts before its children, so this is deepest first
	for _, p := range dirs {
		if fi, err := os.Stat(p); err == nil && fi.ModTime().After(j.stamp) {
			_ = os.Remove(p) // fails, harmlessly, on a directory that still holds something
		}
	}
}

// isFresh: this run wrote (or rewrote) the file: newer than the backdated stamp AND not an untouched file that
// was already inside the backdate window when the run started. The failure direction is deliberately
// conservative: a failed stat reads as stale, which surfaces as a loud reason=missing, never a silent pass.
func (j *job) isFresh(p string) bool {
	fi, err := os.Stat(p)
	if err != nil || !fi.ModTime().After(j.stamp) {
		return false
	}
	pre, ok := j.pre[p]
	return !ok || !fi.ModTime().Equal(pre)
}
