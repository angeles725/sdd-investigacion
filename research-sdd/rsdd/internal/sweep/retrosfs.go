package sweep

import (
	"io/fs"
	"os"
	"strings"
)

// The directory walks of sweep-retros.sh, which are `find` calls. find lists a directory in readdir order (it
// sorts nothing), so a Go walk that sorted would print the WARN lines of one pass in another order than the
// script did: os.File.ReadDir(-1) returns the entries in that same directory order.

// walkRaw visits root and everything under it, pre-order, as `find root` does with the default -P: a symbolic
// link is listed, never entered (root included: `find /link` lists /link alone). maxDepth < 0 means no limit;
// an entry at maxDepth is listed but not entered. An unreadable directory is skipped silently (`2>/dev/null`).
func walkRaw(root string, maxDepth int, visit func(path string, mode fs.FileMode)) {
	st, err := os.Lstat(root)
	if err != nil {
		return
	}
	visit(root, st.Mode().Type())
	if st.IsDir() {
		walkDir(root, 0, maxDepth, visit)
	}
}

func walkDir(dir string, depth, maxDepth int, visit func(string, fs.FileMode)) {
	if maxDepth >= 0 && depth >= maxDepth {
		return
	}
	f, err := os.Open(dir)
	if err != nil {
		return
	}
	entries, _ := f.ReadDir(-1) // partial entries are still listed, as find does before it reports the error
	_ = f.Close()
	for _, e := range entries {
		p := childPath(dir, e.Name())
		mode := e.Type()
		visit(p, mode)
		if mode.IsDir() {
			walkDir(p, depth+1, maxDepth, visit)
		}
	}
}

// childPath joins a directory and an entry the way find prints it: no doubled slash after a trailing one.
func childPath(dir, name string) string {
	if strings.HasSuffix(dir, "/") {
		return dir + name
	}
	return dir + "/" + name
}

// lowerASCII folds ASCII letters only (find -iname and grep -i under the C locale).
func lowerASCII(s string) string {
	b := []byte(s)
	for i, c := range b {
		if c >= 'A' && c <= 'Z' {
			b[i] = c + 32
		}
	}
	return string(b)
}

// inRetrosPath is `-path '*/retros/*.md'`: fnmatch without FNM_PATHNAME, so each `*` also crosses slashes and
// the whole path (the target prefix included) is matched. The FIRST "/retros/" leaves the longest remainder, so
// it decides. The ".md" of the pattern fits in the remainder by itself: the suffix cannot overlap the "/" that
// ends "/retros/".
func inRetrosPath(path string) bool {
	i := strings.Index(path, "/retros/")
	return i >= 0 && strings.HasSuffix(path, ".md")
}

// notGitPath is `-not -path '*/.git/*'`.
func notGitPath(path string) bool { return !strings.Contains(path, "/.git/") }

// isIndexName is `-iname '*index*.md'` on the basename: an index or manifest file, not a retro.
func isIndexName(path string) bool {
	l := lowerASCII(path[strings.LastIndexByte(path, '/')+1:])
	return strings.HasSuffix(l, ".md") && strings.Contains(l[:len(l)-len(".md")], "index")
}

// findRetros is `find P -maxdepth 4 -path '*/retros/*.md' -not -path '*/.git/*' [-not -iname '*index*.md']`.
func findRetros(p string, skipIndex bool) []string {
	var out []string
	walkRaw(p, 4, func(path string, _ fs.FileMode) {
		if inRetrosPath(path) && notGitPath(path) && !(skipIndex && isIndexName(path)) {
			out = append(out, path)
		}
	})
	return out
}

// findMarkdownFiles is `find P -type f -name '*.md'`: regular files only, at any depth.
func findMarkdownFiles(p string) []string {
	var out []string
	walkRaw(p, -1, func(path string, mode fs.FileMode) {
		if mode.IsRegular() && strings.HasSuffix(path, ".md") {
			out = append(out, path)
		}
	})
	return out
}
