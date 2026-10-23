package parity

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
)

// keepBits are the mode bits a copy preserves and the effect diff reports.
const keepBits = fs.ModePerm | fs.ModeSetuid | fs.ModeSetgid | fs.ModeSticky

// copyTree copies src to dst preserving file and directory modes. Symlinks are
// copied as symlinks with their target text unchanged and are never followed,
// so nothing outside src is read or reachable through the copy's structure.
// skipGit leaves out .git (file or directory). Other special files are an
// error rather than a silent omission.
func copyTree(src, dst string, skipGit bool) error {
	type dirMode struct {
		path string
		mode fs.FileMode
	}
	var dirs []dirMode
	err := filepath.WalkDir(src, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, err := filepath.Rel(src, p)
		if err != nil {
			return err
		}
		if skipGit && rel != "." && d.Name() == ".git" {
			if d.IsDir() {
				return filepath.SkipDir
			}
			return nil
		}
		target := filepath.Join(dst, rel)
		info, err := d.Info() // lstat: a symlink reports as a symlink
		if err != nil {
			return err
		}
		switch {
		case info.Mode()&fs.ModeSymlink != 0:
			link, err := os.Readlink(p)
			if err != nil {
				return err
			}
			return os.Symlink(link, target)
		case info.IsDir():
			// Created owner-writable so the children can be added; the real
			// mode is applied after the walk, deepest first.
			dirs = append(dirs, dirMode{target, info.Mode() & keepBits})
			return os.MkdirAll(target, 0o700)
		case info.Mode().IsRegular():
			b, err := os.ReadFile(p)
			if err != nil {
				return err
			}
			if err := os.WriteFile(target, b, 0o600); err != nil {
				return err
			}
			return os.Chmod(target, info.Mode()&keepBits) // WriteFile's perm is masked by umask
		default:
			return fmt.Errorf("%s: unsupported file type %s (not a regular file, directory or symlink)", p, info.Mode().Type())
		}
	})
	for i := len(dirs) - 1; i >= 0; i-- {
		err = errors.Join(err, os.Chmod(dirs[i].path, dirs[i].mode))
	}
	return err
}

// forceRemove deletes a tree even when it holds read-only directories, which
// a faithful mode-preserving copy can contain. A missing path is not an error.
func forceRemove(p string) error {
	_ = filepath.WalkDir(p, func(q string, d fs.DirEntry, err error) error {
		if d != nil && d.IsDir() {
			_ = os.Chmod(q, 0o700)
		}
		return nil
	})
	return os.RemoveAll(p)
}
