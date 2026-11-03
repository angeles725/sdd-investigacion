package sweep

import (
	"io/fs"
	"os"
	"path/filepath"
	"strings"
)

// The tools/ walk of sweep-tools.sh: which files of <target>/tools are tools, which are library modules, and
// which are neither. The walk is the `find` of the retro pass (walkRaw): readdir order, symbolic links listed
// and never entered, so only regular files count.

// depDirs are the directory names whose contents are dependencies or caches, never tools.
var depDirs = []string{"node_modules", "__pycache__", ".venv", ".git"}

// scriptExts are the extensions that make a file a tool whatever its mode (case-sensitive, as `case` is).
var scriptExts = []string{".py", ".sh", ".mjs", ".js", ".ts", ".ps1"}

// inDepDir is the `-not -path '*/<dir>/*'` family, judged on the path below tools/ only. The script matched
// the whole path, so a target that itself lives under a .venv/ or node_modules/ directory read as having no
// tools at all (declared difference, TestToolsFilesIgnoreTargetPrefix).
func inDepDir(rel string) bool {
	for _, d := range depDirs {
		if strings.Contains("/"+rel, "/"+d+"/") {
			return true
		}
	}
	return false
}

// toolsFiles is `find tools -type f` minus the dependency directories: the regular files below tools/. A tools/
// that is itself a symbolic link to a directory is followed (the script's find listed the link and nothing
// under it, so a linked tools/ read as empty: declared difference). It returns the directory it walked, which
// the library-module predicate needs.
func toolsFiles(tdir string) (root string, files []string) {
	root = tdir
	if r, err := filepath.EvalSymlinks(tdir); err == nil {
		root = r
	}
	walkRaw(root, -1, func(path string, mode fs.FileMode) {
		if !mode.IsRegular() {
			return
		}
		if rel := strings.TrimPrefix(path, root+"/"); !inDepDir(rel) {
			files = append(files, path)
		}
	})
	return root, files
}

// isToolFile is the tool predicate: a known script extension, or the executable bit for the caller.
func isToolFile(f string) bool {
	for _, e := range scriptExts {
		if strings.HasSuffix(f, e) {
			return true
		}
	}
	return isExecutable(f)
}

// isLibModule is the library-module predicate: the file sits below a directory whose name ends in _lib, or
// directly in a Python package (a sub-directory of tools/ holding __init__.py). Library modules are disclosed
// apart from the tool count (CLAUDE.md section 7).
func isLibModule(f, tdir string) bool {
	rel := strings.TrimPrefix(f, tdir+"/")
	for dir := filepath.Dir(rel); dir != "."; dir = filepath.Dir(dir) {
		if strings.HasSuffix(filepath.Base(dir), "_lib") {
			return true
		}
	}
	parent := filepath.Dir(f)
	if parent == tdir {
		return false
	}
	st, err := os.Stat(parent + "/__init__.py")
	return err == nil && st.Mode().IsRegular()
}
