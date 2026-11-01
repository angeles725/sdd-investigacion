package adapter

import (
	"errors"
	"os"
	"path"
	"strings"
	"syscall"
)

var errNeedCwd = errors.New("adapter: a relative path needs an injected working directory")

type rpItem struct {
	s      string
	marker bool // CPython's None: the symlink below it has been resolved
}

// realpath is posixpath.realpath(p, strict=strict) with the working directory
// injected (cwd must be absolute and symlink-free, as os.getcwd() is). Loops
// and unreadable links are left in place when not strict.
func realpath(p string, strict bool, cwd string) (string, error) {
	rest := []rpItem{}
	for _, c := range strings.Split(strings.TrimRight(p, "/"), "/") {
		rest = append([]rpItem{{s: c}}, rest...)
	}
	partCount := len(rest)
	cur := "/"
	if !strings.HasPrefix(p, "/") {
		if cwd == "" {
			return "", errNeedCwd
		}
		cur = cwd
	}
	trailing := strings.HasSuffix(p, "/")
	seen := map[string]*string{}
	for partCount > 0 {
		it := rest[len(rest)-1]
		rest = rest[:len(rest)-1]
		if it.marker {
			link := rest[len(rest)-1].s
			rest = rest[:len(rest)-1]
			c := cur
			seen[link] = &c
			continue
		}
		name := it.s
		partCount--
		if name == "" || name == "." {
			continue
		}
		if name == ".." {
			if i := strings.LastIndex(cur, "/"); i > 0 {
				cur = cur[:i]
			} else {
				cur = "/"
			}
			continue
		}
		newpath := cur + "/" + name
		if cur == "/" {
			newpath = "/" + name
		}
		fi, err := os.Lstat(newpath)
		if err == nil {
			if fi.Mode()&os.ModeSymlink == 0 {
				if strict && (partCount > 0 || trailing) && !fi.IsDir() {
					return "", &os.PathError{Op: "realpath", Path: newpath, Err: syscall.ENOTDIR}
				}
				cur = newpath
				continue
			}
			if r, ok := seen[newpath]; ok {
				if r != nil {
					cur = *r
					continue
				}
				if strict {
					return "", &os.PathError{Op: "realpath", Path: newpath, Err: syscall.ELOOP}
				}
				cur = newpath
				continue
			}
			target, rerr := os.Readlink(newpath)
			if rerr == nil {
				if strings.HasPrefix(target, "/") {
					cur = "/"
				}
				seen[newpath] = nil
				rest = append(rest, rpItem{s: newpath}, rpItem{marker: true})
				parts := strings.Split(target, "/")
				for i := len(parts) - 1; i >= 0; i-- {
					rest = append(rest, rpItem{s: parts[i]})
				}
				partCount += len(parts)
				continue
			}
			err = rerr
		}
		if strict {
			return "", err
		}
		cur = newpath
	}
	return cur, nil
}

// resolveStrict is str(pathlib.Path(p).resolve(strict=True)).
func resolveStrict(p, cwd string) (string, error) { return realpath(pyNorm(p), true, cwd) }

// which is shutil.which(cmd, path=search) for POSIX with mode F_OK|X_OK. cwd
// anchors a relative candidate for the access checks only; the returned name is
// spelled as Python spells it.
func which(cmd, search, cwd string) (string, bool) {
	dirname, base := path.Split(cmd)
	var dirs []string
	if dirname != "" {
		d := dirname
		if t := strings.TrimRight(d, "/"); t != "" {
			d = t
		}
		dirs = []string{d}
	} else {
		if search == "" {
			return "", false
		}
		dirs = strings.Split(search, ":")
	}
	seen := map[string]bool{}
	for _, d := range dirs {
		if seen[d] {
			continue
		}
		seen[d] = true
		name := base
		if d != "" {
			name = d + "/" + base
			if strings.HasSuffix(d, "/") {
				name = d + base
			}
		}
		if accessExec(name, cwd) {
			return name, true
		}
	}
	return "", false
}

// accessExec is shutil._access_check: exists, X_OK for the real uid, not a directory.
func accessExec(name, cwd string) bool {
	abs := name
	if !strings.HasPrefix(name, "/") && cwd != "" {
		abs = cwd + "/" + name
	}
	fi, err := os.Stat(abs)
	return err == nil && syscall.Access(abs, 0x1) == nil && !fi.IsDir()
}
