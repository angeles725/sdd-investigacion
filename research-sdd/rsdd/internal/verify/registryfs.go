package verify

import (
	"io/fs"
	"os"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/retrogrammar"
)

// Filesystem and text helpers of `verify registry`: each one mirrors the exact shell construct the script used
// (find without -H/-L, basename, dirname, the retro opt-out reader), so the port counts the same entries.

// findWalk is `find root -maxdepth maxdepth` with no -H or -L: it visits root (depth 0) and then every entry
// down to maxdepth. Symlinks are never followed, root included (a symlinked root is visited as a symlink and
// not descended), and an unreadable directory is skipped silently like `2>/dev/null`. The path of a child is
// root + "/" + name, with no doubled slash when root already ends in one. mode is the Lstat mode.
func findWalk(root string, maxdepth int, fn func(p string, mode fs.FileMode)) {
	st, err := os.Lstat(root)
	if err != nil {
		return
	}
	fn(root, st.Mode())
	var walk func(dir string, depth int)
	walk = func(dir string, depth int) {
		if depth > maxdepth {
			return
		}
		ents, err := os.ReadDir(dir)
		if err != nil {
			return
		}
		for _, e := range ents {
			p := dir + "/" + e.Name()
			if strings.HasSuffix(dir, "/") {
				p = dir + e.Name()
			}
			mode := e.Type()
			fn(p, mode)
			if mode.IsDir() {
				walk(p, depth+1)
			}
		}
	}
	if st.Mode().IsDir() {
		walk(root, 1)
	}
}

// listMarkdown is `find dir -maxdepth 1 -type f -name '*.md'`: regular files (not symlinks) named *.md that sit
// directly in dir. Order is the directory order; callers only count.
func listMarkdown(dir string) []string {
	var out []string
	findWalk(dir, 1, func(p string, mode fs.FileMode) {
		if mode.IsRegular() && strings.HasSuffix(bashBasename(p), ".md") {
			out = append(out, p)
		}
	})
	return out
}

// retroEntries is `find p -maxdepth 4 -path '*/retros/*.md' -not -path '*/.git/*'` (plus `-not -iname
// '*index*.md'` when skipIndex): any entry type, as find without -type prints them.
func retroEntries(p string, skipIndex bool) []string {
	var out []string
	findWalk(p, 4, func(e string, _ fs.FileMode) {
		if !globRetros(e) || strings.Contains(e, "/.git/") {
			return
		}
		if skipIndex && globIndexMD(bashBasename(e)) {
			return
		}
		out = append(out, e)
	})
	return out
}

// globRetros is fnmatch of '*/retros/*.md' as find -path applies it: `*` crosses slashes, so a "/retros/"
// anywhere in a path that ends in ".md" matches (the suffix cannot overlap the slash-terminated "/retros/").
func globRetros(p string) bool {
	return strings.Contains(p, "/retros/") && strings.HasSuffix(p, ".md")
}

// globIndexMD is -iname '*index*.md': "index" (ASCII case-insensitive) in a name that ends in ".md" (the two
// cannot overlap, "index" holds no '.').
func globIndexMD(name string) bool {
	l := strings.ToLower(name)
	return strings.Contains(l, "index") && strings.HasSuffix(l, ".md")
}

// bashBasename is `basename p`: trailing slashes dropped, the text after the last slash, "/" for an all-slash
// path and "" for an empty one.
func bashBasename(p string) string {
	t := strings.TrimRight(p, "/")
	if t == "" {
		if p == "" {
			return ""
		}
		return "/"
	}
	return t[strings.LastIndex(t, "/")+1:]
}

// bashDirname is `dirname p`: trailing slashes dropped, then the last component and the slashes before it,
// "." when no directory part is left and "/" when only the root remains. Unlike path.Dir it never cleans.
func bashDirname(p string) string {
	if p == "" {
		return "."
	}
	t := strings.TrimRight(p, "/")
	if t == "" {
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

// isDirOS is `[ -d p ]` (follows symlinks) and isFileOS is `[ -f p ]`.
func isDirOS(p string) bool {
	st, err := os.Stat(p)
	return err == nil && st.IsDir()
}

func isFileOS(p string) bool {
	st, err := os.Stat(p)
	return err == nil && st.Mode().IsRegular()
}

// retroIsExcluded is retro_is_excluded (lib/retro-status.sh), shared with the retro tools through
// internal/core/retrogrammar: an unusable path (not a regular file, or unreadable) is not excluded.
func retroIsExcluded(file string) bool {
	d, err := retrogrammar.Read(file)
	return err == nil && retrogrammar.IsExcluded(d)
}
