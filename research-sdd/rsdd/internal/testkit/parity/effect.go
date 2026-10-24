package parity

import (
	"crypto/sha256"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// inlineContentMax is the largest file whose bytes appear verbatim in an
// effect; larger files are represented by size and sha256, which compares just
// as strictly without flooding the report.
const inlineContentMax = 4096

type snapEntry struct {
	typ     string // file | dir | symlink | other
	mode    fs.FileMode
	link    string
	content string
}

func snapshot(root string) (map[string]snapEntry, error) {
	if st, err := os.Lstat(root); err != nil {
		return nil, err
	} else if !st.IsDir() {
		return nil, fmt.Errorf("%s is not a directory", root)
	}
	snap := map[string]snapEntry{}
	err := filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, err := filepath.Rel(root, p)
		if err != nil {
			return err
		}
		if rel == "." {
			return nil
		}
		info, err := d.Info()
		if err != nil {
			return err
		}
		e := snapEntry{mode: info.Mode() & keepBits}
		switch {
		case info.Mode()&fs.ModeSymlink != 0:
			e.typ, e.mode = "symlink", 0 // symlink permission bits are not portable
			if e.link, err = os.Readlink(p); err != nil {
				return err
			}
		case info.IsDir():
			e.typ = "dir"
		case info.Mode().IsRegular():
			e.typ = "file"
			b, rerr := os.ReadFile(p)
			switch {
			case rerr != nil:
				e.content = "<unreadable>"
			case len(b) <= inlineContentMax:
				e.content = fmt.Sprintf("%q", b)
			default:
				e.content = fmt.Sprintf("sha256=%x size=%d", sha256.Sum256(b), len(b))
			}
		default:
			e.typ = "other"
		}
		snap[filepath.ToSlash(rel)] = e
		return nil
	})
	return snap, err
}

// treeEffect is a deterministic description of what happened to a scratch tree:
// added, removed and modified paths in path order, with mode changes, symlink
// target changes and the content of added or modified files. Modification times
// are deliberately not part of it.
func treeEffect(pristine, after string) ([]byte, error) {
	a, err := snapshot(pristine)
	if err != nil {
		return nil, fmt.Errorf("pristine tree: %w", err)
	}
	b, err := snapshot(after)
	if err != nil {
		return nil, fmt.Errorf("scratch tree: %w", err)
	}
	keys := make([]string, 0, len(a)+len(b))
	for k := range a {
		keys = append(keys, k)
	}
	for k := range b {
		if _, ok := a[k]; !ok {
			keys = append(keys, k)
		}
	}
	sort.Strings(keys)
	var sb strings.Builder
	for _, k := range keys {
		x, inA := a[k]
		y, inB := b[k]
		switch {
		case inA && !inB:
			fmt.Fprintf(&sb, "removed %s %s\n", x.typ, k)
		case !inA && inB:
			fmt.Fprintf(&sb, "added %s %s mode %04o", y.typ, k, y.mode)
			if y.typ == "symlink" {
				fmt.Fprintf(&sb, " link %q", y.link)
			}
			if y.typ == "file" {
				fmt.Fprintf(&sb, " content %s", y.content)
			}
			sb.WriteString("\n")
		case x != y:
			fmt.Fprintf(&sb, "modified %s:", k)
			if x.typ != y.typ {
				fmt.Fprintf(&sb, " type %s->%s", x.typ, y.typ)
			}
			if x.mode != y.mode {
				fmt.Fprintf(&sb, " mode %04o->%04o", x.mode, y.mode)
			}
			if x.link != y.link {
				fmt.Fprintf(&sb, " link %q->%q", x.link, y.link)
			}
			if x.content != y.content && y.typ == "file" {
				fmt.Fprintf(&sb, " content %s", y.content)
			}
			sb.WriteString("\n")
		}
	}
	return []byte(sb.String()), nil
}
