package secretscan

import (
	"cmp"
	"io/fs"
	"os"
	"path/filepath"
	"slices"
	"strings"
)

// scanFile is one file to scan: Display is the path the report prints, Abs the path that is read.
type scanFile struct{ Display, Abs string }

// fileSet is the file set of a working-tree scan.
type fileSet struct {
	Files     []scanFile
	CorpusRel string // default mode: the narrowed corpus root, relative to the target ("" = not narrowed)
	// --files-from counters: entries listed, entries in scope, entries skipped for not being a regular file.
	Listed, InScope, NonReg int
	// Unreadable: a directory of the walk could not be read (grep -r exits 2 on it, so the scan is DEGRADED).
	Unreadable bool
}

// displayJoin joins the target as the caller wrote it (trailing slashes dropped) and a relative path, the shape
// `grep -r` prints.
func displayJoin(target, rel string) string {
	if rel == "" {
		return strings.TrimRight(target, "/")
	}
	return strings.TrimRight(target, "/") + "/" + rel
}

func asciiLower(s string) string {
	const upper, lower = "ABCDEFGHIJKLMNOPQRSTUVWXYZ", "abcdefghijklmnopqrstuvwxyz"
	b := []byte(s)
	for i, c := range b {
		if k := strings.IndexByte(upper, c); k >= 0 {
			b[i] = lower[k]
		}
	}
	return string(b)
}

// isBlockFile is `-iname '*block*.md' -o -iname '*bloque*.md'` without `*.template.md` (case-sensitive).
func isBlockFile(name string) bool {
	l := asciiLower(name)
	if !strings.HasSuffix(l, ".md") || strings.HasSuffix(name, ".template.md") {
		return false
	}
	stem := l[:len(l)-3]
	return strings.Contains(stem, "block") || strings.Contains(stem, "bloque")
}

// narrowRoot mirrors verify-sources.sh: the target itself when it directly holds block files, else the shallowest
// subdirectory (down to depth 3) that does, ties broken by path. It returns the directory relative to the target
// ("" = no narrowing). A symlinked target is not descended, as `find` does not. This narrowing is the legacy
// documented behaviour (pinned by the suite); --files-from and --committed never narrow.
func narrowRoot(target, abs string) string {
	if fi, err := os.Lstat(abs); err != nil || fi.Mode()&fs.ModeSymlink != 0 {
		return ""
	}
	var found []string // relative paths of block files, depth 1..3
	var visit func(dir, rel string, depth int)
	visit = func(dir, rel string, depth int) {
		ents, err := os.ReadDir(dir)
		if err != nil {
			return
		}
		for _, e := range ents {
			r := e.Name()
			if rel != "" {
				r = rel + "/" + e.Name()
			}
			switch {
			case e.Type().IsRegular() && isBlockFile(e.Name()):
				if !strings.Contains(displayJoin(target, r), "/.git/") {
					found = append(found, r)
				}
			case e.IsDir() && depth < 3:
				visit(filepath.Join(dir, e.Name()), r, depth+1)
			}
		}
	}
	visit(abs, "", 1)
	if len(found) == 0 {
		return ""
	}
	slices.SortFunc(found, func(a, b string) int { // shallowest first, then bytewise
		return cmp.Or(cmp.Compare(strings.Count(a, "/"), strings.Count(b, "/")), strings.Compare(a, b))
	})
	if !strings.Contains(found[0], "/") {
		return "" // the target itself holds a block file
	}
	return found[0][:strings.LastIndexByte(found[0], '/')]
}

// walkSet is the default-mode file set: every in-scope regular file under the (narrowed) corpus root, in path
// order. Symlinks are not followed and excluded directories are pruned, but the root itself is never excluded:
// grep --exclude-dir also matched the command-line directory, so a target named cfr or venv scanned nothing.
func walkSet(target, abs string) fileSet {
	set := fileSet{CorpusRel: narrowRoot(target, abs)}
	root, rel := abs, set.CorpusRel
	if rel != "" {
		root = filepath.Join(abs, filepath.FromSlash(rel))
	}
	var walk func(dir, rel string)
	walk = func(dir, rel string) {
		ents, err := os.ReadDir(dir)
		if err != nil {
			set.Unreadable = true
			return
		}
		for _, e := range ents {
			r := e.Name()
			if rel != "" {
				r = rel + "/" + e.Name()
			}
			switch t := e.Type(); {
			case t&fs.ModeSymlink != 0:
			case t.IsDir():
				if !excludedDirs[e.Name()] {
					walk(filepath.Join(dir, e.Name()), r)
				}
			case t.IsRegular() && nameInScope(e.Name()):
				set.Files = append(set.Files, scanFile{Display: displayJoin(target, r), Abs: filepath.Join(dir, e.Name())})
			}
		}
	}
	start := set.CorpusRel
	walk(root, start)
	return set
}
