package niagara

import (
	"os"
	"strings"
)

// This file holds the posixpath behaviours the legacy Niagara tools lean on and that Go's path/filepath cannot
// give: filepath.Join and filepath.Clean collapse ".." lexically, which changes what a path means when a
// component is a symlink, and filepath.EvalSymlinks fails on a path that does not exist where
// os.path.realpath does not.

// pjoin is os.path.join(a, b) for a relative b: the two with exactly one separator, nothing cleaned.
func pjoin(a, b string) string {
	switch {
	case a == "":
		return b
	case strings.HasSuffix(a, "/"):
		return a + b
	}
	return a + "/" + b
}

// psplit is os.path.split.
func psplit(p string) (head, tail string) {
	i := strings.LastIndex(p, "/") + 1
	head, tail = p[:i], p[i:]
	if head != "" && head != strings.Repeat("/", len(head)) {
		head = strings.TrimRight(head, "/")
	}
	return head, tail
}

// pdirname is os.path.dirname.
func pdirname(p string) string {
	head, _ := psplit(p)
	return head
}

// pyRealpath is os.path.realpath(path) in its default non-strict mode: symlinks are resolved as far as the
// path exists, a component that does not exist is kept as written, and a symlink loop returns the path joined
// with what was left. It never fails.
func pyRealpath(cwd, path string) string {
	if !strings.HasPrefix(path, "/") && cwd != "" {
		path = pjoin(cwd, path) // the working directory is already a real path
	}
	res, _ := joinRealpath("", path, map[string]*string{})
	return normpath(res)
}

// joinRealpath is posixpath._joinrealpath.
func joinRealpath(path, rest string, seen map[string]*string) (string, bool) {
	if strings.HasPrefix(rest, "/") {
		rest = strings.TrimPrefix(rest, "/")
		path = "/"
	}
	for rest != "" {
		var name string
		name, rest, _ = strings.Cut(rest, "/")
		if name == "" || name == "." {
			continue
		}
		if name == ".." {
			if path != "" {
				var tail string
				path, tail = psplit(path)
				if tail == ".." {
					path = pjoin(pjoin(path, ".."), "..")
				}
			} else {
				path = ".."
			}
			continue
		}
		newpath := pjoin(path, name)
		fi, err := os.Lstat(newpath)
		if err != nil || fi.Mode()&os.ModeSymlink == 0 {
			path = newpath
			continue
		}
		if cached, ok := seen[newpath]; ok {
			if cached != nil {
				path = *cached
				continue
			}
			return pjoin(newpath, rest), false // a symlink loop
		}
		seen[newpath] = nil
		target, err := os.Readlink(newpath)
		if err != nil {
			path = newpath
			continue
		}
		var ok bool
		path, ok = joinRealpath(path, target, seen)
		if !ok {
			return pjoin(path, rest), false
		}
		resolved := path
		seen[newpath] = &resolved
	}
	return path, true
}

// normpath is posixpath.normpath.
func normpath(p string) string {
	if p == "" {
		return "."
	}
	initial := 0
	if strings.HasPrefix(p, "/") {
		initial = 1
		if strings.HasPrefix(p, "//") && !strings.HasPrefix(p, "///") {
			initial = 2
		}
	}
	var out []string
	for _, c := range strings.Split(p, "/") {
		if c == "" || c == "." {
			continue
		}
		if c != ".." || (initial == 0 && len(out) == 0) || (len(out) > 0 && out[len(out)-1] == "..") {
			out = append(out, c)
		} else if len(out) > 0 {
			out = out[:len(out)-1]
		}
	}
	res := strings.Join(out, "/")
	if initial > 0 {
		res = strings.Repeat("/", initial) + res
	}
	if res == "" {
		return "."
	}
	return res
}

// insideRoot is _inside_root: whether sub resolves (through every symlink) to home or below it. A path that
// does not exist yet resolves lexically, so it counts as inside when its existing prefix is.
func insideRoot(cwd, home, sub string) bool {
	realHome := pyRealpath(cwd, home)
	realSub := pyRealpath(cwd, sub)
	return realSub == realHome || strings.HasPrefix(realSub, realHome+"/")
}
