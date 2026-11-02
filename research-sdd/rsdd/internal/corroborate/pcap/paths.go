package pcap

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"unicode"
	"unicode/utf8"
)

// Path semantics of pathlib.PurePosixPath, which decide how a path is printed in a message and where the
// output tree is published, plus Python's OSError texts.

// parts is PurePosixPath(p).parts: a leading root ("/" or, for exactly two slashes, "//"), then the
// components with "" and "." dropped.
func parts(p string) []string {
	var out []string
	rest := p
	if strings.HasPrefix(p, "/") {
		n := len(p) - len(strings.TrimLeft(p, "/"))
		root := "/"
		if n == 2 {
			root = "//"
		}
		out = append(out, root)
		rest = p[n:]
	}
	for _, c := range strings.Split(rest, "/") {
		if c != "" && c != "." {
			out = append(out, c)
		}
	}
	return out
}

// norm is str(Path(p)).
func norm(p string) string {
	ps := parts(p)
	switch {
	case len(ps) == 0:
		return "."
	case strings.HasPrefix(ps[0], "/"):
		return ps[0] + strings.Join(ps[1:], "/")
	}
	return strings.Join(ps, "/")
}

// parentAndName is (Path(p).parent, Path(p).name).
func parentAndName(p string) (parent, name string) {
	ps := parts(p)
	switch {
	case len(ps) == 0:
		return ".", ""
	case len(ps) == 1 && strings.HasPrefix(ps[0], "/"):
		return ps[0], ""
	case len(ps) == 1:
		return ".", ps[0]
	}
	return joinParts(ps[:len(ps)-1]), ps[len(ps)-1]
}

func joinParts(ps []string) string {
	if strings.HasPrefix(ps[0], "/") {
		return ps[0] + strings.Join(ps[1:], "/")
	}
	return strings.Join(ps, "/")
}

// join is str(Path(base) / name) for a name without a slash.
func join(base, name string) string {
	if name == "" {
		return norm(base)
	}
	b := norm(base)
	if b == "." {
		return name
	}
	if strings.HasSuffix(b, "/") {
		return b + name
	}
	return b + "/" + name
}

// absolute resolves p against cwd the way the operating system does for a relative name, without cleaning it.
func absolute(cwd, p string) string {
	if strings.HasPrefix(p, "/") || cwd == "" {
		return p
	}
	return strings.TrimRight(cwd, "/") + "/" + p
}

// resolveStrict is Path.resolve(strict=True) (os.path.realpath, CPython 3.12): symlinks followed component by
// component, a missing one an OSError that names the path built so far (relative while the input is).
func resolveStrict(cwd, p string) (string, error) {
	path, err := joinRealpath(cwd, "", p, map[string]string{})
	if err != nil {
		return "", err
	}
	return filepath.Clean(absolute(cwd, path)), nil
}

// joinRealpath is posixpath._joinrealpath for strict mode. seen maps a link path to its resolved target, or ""
// while it is being resolved (a loop).
func joinRealpath(cwd, path, rest string, seen map[string]string) (string, error) {
	if strings.HasPrefix(rest, "/") {
		rest, path = rest[1:], "/"
	}
	for rest != "" {
		var name string
		name, rest, _ = strings.Cut(rest, "/")
		switch name {
		case "", ".":
			continue
		case "..":
			if path != "" {
				head, tail := pySplit(path)
				path = head
				if tail == ".." {
					path = pyJoin(pyJoin(head, ".."), "..")
				}
			} else {
				path = ".."
			}
			continue
		}
		newpath := pyJoin(path, name)
		fi, err := os.Lstat(absolute(cwd, newpath))
		if err != nil {
			return "", &os.PathError{Op: "lstat", Path: newpath, Err: pathErrno(err)}
		}
		if fi.Mode()&os.ModeSymlink == 0 {
			path = newpath
			continue
		}
		if resolved, ok := seen[newpath]; ok {
			if resolved != "" {
				path = resolved
				continue
			}
			return "", &os.PathError{Op: "stat", Path: newpath, Err: syscall.ELOOP}
		}
		seen[newpath] = ""
		target, err := os.Readlink(absolute(cwd, newpath))
		if err != nil {
			return "", &os.PathError{Op: "readlink", Path: newpath, Err: pathErrno(err)}
		}
		if path, err = joinRealpath(cwd, path, target, seen); err != nil {
			return "", err
		}
		seen[newpath] = path
	}
	return path, nil
}

// pathErrno unwraps the errno of a failed system call.
func pathErrno(err error) error {
	if en, ok := errnoOf(err); ok {
		return en
	}
	return err
}

// pySplit is os.path.split for a POSIX path: the head loses its trailing slashes unless it is all slashes.
func pySplit(p string) (head, tail string) {
	i := strings.LastIndex(p, "/") + 1
	head, tail = p[:i], p[i:]
	if head != "" && strings.Trim(head, "/") != "" {
		head = strings.TrimRight(head, "/")
	}
	return head, tail
}

// pyJoin is os.path.join(dir, name) for a relative name.
func pyJoin(dir, name string) string {
	switch {
	case dir == "":
		return name
	case strings.HasSuffix(dir, "/"):
		return dir + name
	}
	return dir + "/" + name
}

// errnoOf returns the errno inside err, if any.
func errnoOf(err error) (syscall.Errno, bool) {
	var en syscall.Errno
	if errors.As(err, &en) {
		return en, true
	}
	return 0, false
}

// strerror is C's strerror text as Python's OSError.strerror shows it: Go's message with an upper-case first
// letter (the Linux strings are glibc's, lower-cased).
func strerror(en syscall.Errno) string {
	m := en.Error()
	if m == "" {
		return m
	}
	r, w := utf8.DecodeRuneInString(m)
	return string(unicode.ToUpper(r)) + m[w:]
}

// osErrorText is str(OSError(errno, strerror[, filename])): "[Errno N] text", with ": 'filename'" when named.
func osErrorText(en syscall.Errno, filename string) string {
	if filename == "" {
		return fmt.Sprintf("[Errno %d] %s", int(en), strerror(en))
	}
	return fmt.Sprintf("[Errno %d] %s: %s", int(en), strerror(en), pyRepr(filename))
}

// pathError renders an *os.PathError, *os.LinkError or bare errno the way the legacy handlers printed an OSError.
func pathError(err error) (string, bool) {
	var pe *os.PathError
	if errors.As(err, &pe) {
		if en, ok := errnoOf(pe.Err); ok {
			return osErrorText(en, pe.Path), true
		}
	}
	var le *os.LinkError
	if errors.As(err, &le) {
		if en, ok := errnoOf(le.Err); ok {
			return osErrorText(en, le.New), true
		}
	}
	if en, ok := errnoOf(err); ok {
		return osErrorText(en, ""), true
	}
	return "", false
}
