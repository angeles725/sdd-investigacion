package parity

import (
	"fmt"
	"io/fs"
	"path/filepath"
	"sort"
)

// Tree is a fingerprint of a directory tree: relative path -> "mode|size|mtime".
type Tree map[string]string

const maxDiffLines = 10

// Fingerprint records path, type/mode, size and mtime of every entry under
// root (symlinks are not followed), skipping .git. An unreadable or absent
// root is an error, never an empty tree.
func Fingerprint(root string) (Tree, error) {
	t := Tree{}
	err := filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, err := filepath.Rel(root, p)
		if err != nil {
			return err
		}
		if d.Name() == ".git" && rel != "." {
			if d.IsDir() {
				return filepath.SkipDir
			}
			return nil
		}
		info, err := d.Info()
		if err != nil {
			return err
		}
		t[filepath.ToSlash(rel)] = fmt.Sprintf("%o|%d|%d", uint32(info.Mode()), info.Size(), info.ModTime().UnixNano())
		return nil
	})
	if err != nil {
		return nil, fmt.Errorf("fingerprint %s: %w", root, err)
	}
	return t, nil
}

// Diff lists added, removed and modified entries of o relative to t, capped at
// maxDiffLines with a final "... and N more" line when cut.
func (t Tree) Diff(o Tree) []string {
	keys := map[string]bool{}
	for k := range t {
		keys[k] = true
	}
	for k := range o {
		keys[k] = true
	}
	sorted := make([]string, 0, len(keys))
	for k := range keys {
		sorted = append(sorted, k)
	}
	sort.Strings(sorted)
	var out []string
	for _, k := range sorted {
		a, inA := t[k]
		b, inB := o[k]
		switch {
		case inA && !inB:
			out = append(out, "removed: "+k)
		case !inA && inB:
			out = append(out, "added: "+k)
		case a != b:
			out = append(out, fmt.Sprintf("modified: %s (%s -> %s)", k, a, b))
		}
	}
	if len(out) > maxDiffLines {
		out = append(out[:maxDiffLines:maxDiffLines], fmt.Sprintf("... and %d more", len(out)-maxDiffLines))
	}
	return out
}
