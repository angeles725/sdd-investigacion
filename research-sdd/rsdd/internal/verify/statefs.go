package verify

import (
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// fsView is the read-only view of the filesystem verify-state needs. Relative paths resolve against cwd (the
// cli.Stdio working directory), like the shell resolves them against its own; every path printed in a report is
// the one the caller wrote, never the resolved form.
type fsView struct{ cwd string }

func (v fsView) at(p string) string {
	if p == "" || strings.HasPrefix(p, "/") || filepath.IsAbs(p) {
		return p
	}
	return v.cwd + "/" + p
}

func (v fsView) stat(p string) (fs.FileInfo, error) { return os.Stat(v.at(p)) }

// isDir is `[ -d p ]`, isFile is `[ -f p ]`: symlinks followed.
func (v fsView) isDir(p string) bool {
	st, err := v.stat(p)
	return err == nil && st.IsDir()
}

func (v fsView) isFile(p string) bool {
	st, err := v.stat(p)
	return err == nil && st.Mode().IsRegular()
}

// isSymlink is `[ -L p ]`.
func (v fsView) isSymlink(p string) bool {
	st, err := os.Lstat(v.at(p))
	return err == nil && st.Mode()&fs.ModeSymlink != 0
}

func (v fsView) read(p string) ([]byte, error) { return os.ReadFile(v.at(p)) }

// readable is `[ -r p ]` for a directory or file: it can be opened for reading.
func (v fsView) readable(p string) bool {
	f, err := os.Open(v.at(p))
	if err != nil {
		return false
	}
	f.Close()
	return true
}

const maxLinks = 40

// realpath is `realpath -- p` of GNU coreutils in its default mode: every component but the last must exist,
// symbolic links are resolved, "." and ".." removed. ok is false where realpath fails (a missing intermediate
// component, a link loop, a non-directory in the middle).
func (v fsView) realpath(p string) (string, bool) {
	var resolved []string
	rest := splitPath(v.at(p))
	links := 0
	for len(rest) > 0 {
		c := rest[0]
		rest = rest[1:]
		switch c {
		case "", ".":
			continue
		case "..":
			if len(resolved) > 0 {
				resolved = resolved[:len(resolved)-1]
			}
			continue
		}
		cur := "/" + strings.Join(append(append([]string{}, resolved...), c), "/")
		st, err := os.Lstat(cur)
		if err != nil {
			if errors.Is(err, fs.ErrNotExist) && onlyEmpty(rest) {
				resolved = append(resolved, c)
				continue
			}
			return "", false
		}
		if st.Mode()&fs.ModeSymlink != 0 {
			links++
			if links > maxLinks {
				return "", false
			}
			t, err := os.Readlink(cur)
			if err != nil {
				return "", false
			}
			if strings.HasPrefix(t, "/") {
				resolved = nil
			}
			rest = append(splitPath(t), rest...)
			continue
		}
		if !onlyEmpty(rest) && !st.IsDir() {
			return "", false
		}
		resolved = append(resolved, c)
	}
	res := "/" + strings.Join(resolved, "/")
	if strings.HasSuffix(p, "/") { // a trailing slash rejects an existing non-directory (a missing leaf is accepted)
		if st, err := os.Stat(res); err == nil && !st.IsDir() {
			return "", false
		}
	}
	return res, true
}

func splitPath(p string) []string { return strings.Split(p, "/") }

func onlyEmpty(xs []string) bool {
	for _, x := range xs {
		if x != "" {
			return false
		}
	}
	return true
}

// canonDir is `CDPATH= cd -P -- p && pwd -P`: the physical path of an existing, searchable directory. A path
// with a newline counts as a failure, like the script's check.
func (v fsView) canonDir(p string) (string, bool) {
	real, ok := v.realpath(p)
	if !ok || strings.Contains(real, "\n") {
		return "", false
	}
	if st, err := os.Stat(real + "/."); err != nil || !st.IsDir() {
		return "", false
	}
	return real, true
}

// listHooks is `find DIR -maxdepth 1 \( -type f -o -type l \) | sort`: the regular files and symbolic links
// directly under dir, bytewise sorted. A symlinked DIR is not followed (no -H): find reports the link itself.
func (v fsView) listHooks(dir string) []string {
	if v.isSymlink(dir) {
		return []string{dir}
	}
	ents, err := os.ReadDir(v.at(dir))
	if err != nil {
		return nil
	}
	var out []string
	for _, e := range ents {
		st, err := os.Lstat(v.at(dir + "/" + e.Name()))
		if err == nil && (st.Mode().IsRegular() || st.Mode()&fs.ModeSymlink != 0) {
			out = append(out, dir+"/"+e.Name())
		}
	}
	sort.Strings(out)
	return out
}

// dirname is dirname(1): trailing slashes dropped, the last component cut.
func dirname(p string) string {
	t := strings.TrimRight(p, "/")
	if t == "" {
		if p == "" {
			return "."
		}
		return "/"
	}
	i := strings.LastIndex(t, "/")
	if i < 0 {
		return "."
	}
	d := strings.TrimRight(t[:i], "/")
	if d == "" {
		return "/"
	}
	return d
}

// basename is basename(1): trailing slashes dropped, the last component kept.
func basename(p string) string {
	t := strings.TrimRight(p, "/")
	if t == "" {
		if p == "" {
			return ""
		}
		return "/"
	}
	return t[strings.LastIndex(t, "/")+1:]
}

// findStates is `find -H TARGET -maxdepth 3 -name 'RESEARCH-STATE*.md' -not -name '*.template.md'
// -not -path '*/.git/*'` in the order find prints, a directory before the next entry. Entries within a directory are
// visited in byte order, not readdir order: find's own order depends on the filesystem (ext4 hashes names with a
// per-filesystem seed), so the report order differed between machines (#2477); byte order is one of the orders find
// can print, and it is the same everywhere. Symlinks below the start are not followed, unreadable directories are skipped, and nothing is filtered by type.
func (v fsView) findStates(target string) []string {
	var out []string
	visit := func(p, name string) {
		if isStateName(name) && !strings.Contains(p, "/.git/") {
			out = append(out, p)
		}
	}
	trimmed := strings.TrimRight(target, "/")
	visit(target, trimmed[strings.LastIndex(trimmed, "/")+1:])
	if !v.isDir(target) { // -H: the start point is followed
		return out
	}
	var walk func(p string, depth int)
	walk = func(p string, depth int) {
		f, err := os.Open(v.at(p))
		if err != nil {
			return
		}
		names, _ := f.Readdirnames(-1)
		f.Close()
		sort.Strings(names)
		for _, n := range names {
			ep := p + "/" + n
			if strings.HasSuffix(p, "/") {
				ep = p + n
			}
			visit(ep, n)
			if st, err := os.Lstat(v.at(ep)); err == nil && st.IsDir() && depth < 3 {
				walk(ep, depth+1)
			}
		}
	}
	walk(target, 1)
	return out
}

func isStateName(name string) bool {
	return strings.HasPrefix(name, "RESEARCH-STATE") && strings.HasSuffix(name, ".md") && !strings.HasSuffix(name, ".template.md")
}

// regularMarkdown lists the regular (non-symlink) *.md files directly under dir as find prints them
// (`find DIR -maxdepth 1 -type f -name '*.md'`), in directory order.
func (v fsView) regularMarkdown(dir string) []string {
	f, err := os.Open(v.at(dir))
	if err != nil {
		return nil
	}
	names, _ := f.Readdirnames(-1)
	f.Close()
	var out []string
	for _, n := range names {
		if !strings.HasSuffix(n, ".md") {
			continue
		}
		if st, err := os.Lstat(v.at(dir + "/" + n)); err == nil && st.Mode().IsRegular() {
			if strings.HasSuffix(dir, "/") {
				out = append(out, dir+n)
			} else {
				out = append(out, dir+"/"+n)
			}
		}
	}
	return out
}

// grepError is the message grep prints for a file it cannot read.
func grepError(path string, err error) string {
	why := "Input/output error"
	switch {
	case errors.Is(err, fs.ErrPermission):
		why = "Permission denied"
	case errors.Is(err, fs.ErrNotExist):
		why = "No such file or directory"
	case strings.Contains(err.Error(), "is a directory"):
		why = "Is a directory"
	case strings.Contains(err.Error(), "too many levels"):
		why = "Too many levels of symbolic links"
	}
	return "grep: " + path + ": " + why
}
