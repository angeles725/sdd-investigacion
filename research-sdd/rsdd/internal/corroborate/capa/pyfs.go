package capa

// CPython path and error-text semantics the legacy tool's messages depend on. core/adapter keeps its
// equivalents unexported, so they live here (reported in the PR: candidates for a core/pyos export).

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"strings"
	"syscall"
	"unicode"
	"unicode/utf8"
)

// pyParts is pathlib.PurePosixPath(p).parts: a root ("/" or "//" for exactly two slashes) then the
// components with "" and "." dropped.
func pyParts(p string) []string {
	var parts []string
	rest := p
	if strings.HasPrefix(p, "/") {
		n := len(p) - len(strings.TrimLeft(p, "/"))
		root := "/"
		if n == 2 {
			root = "//"
		}
		parts = append(parts, root)
		rest = p[n:]
	}
	for _, c := range strings.Split(rest, "/") {
		if c != "" && c != "." {
			parts = append(parts, c)
		}
	}
	return parts
}

// joinParts is the inverse of pyParts.
func joinParts(parts []string) string {
	switch {
	case len(parts) == 0:
		return "."
	case strings.HasPrefix(parts[0], "/"):
		return parts[0] + strings.Join(parts[1:], "/")
	}
	return strings.Join(parts, "/")
}

// pyNorm is str(pathlib.Path(p)).
func pyNorm(p string) string { return joinParts(pyParts(p)) }

// pyName is Path(p).name.
func pyName(p string) string {
	parts := pyParts(p)
	if len(parts) == 0 || strings.HasPrefix(parts[len(parts)-1], "/") {
		return ""
	}
	return parts[len(parts)-1]
}

// pyParent is str(Path(p).parent).
func pyParent(p string) string {
	parts := pyParts(p)
	if len(parts) <= 1 {
		if len(parts) == 1 && strings.HasPrefix(parts[0], "/") {
			return parts[0]
		}
		return "."
	}
	return joinParts(parts[:len(parts)-1])
}

// pyRepr is repr(str).
func pyRepr(s string) string {
	quote := byte('\'')
	if strings.Contains(s, "'") && !strings.Contains(s, "\"") {
		quote = '"'
	}
	var b strings.Builder
	b.WriteByte(quote)
	for i := 0; i < len(s); {
		r, w := utf8.DecodeRuneInString(s[i:])
		switch {
		case r == utf8.RuneError && w == 1:
			fmt.Fprintf(&b, "\\udc%02x", s[i]) // surrogateescape
		case r == rune(quote) || r == '\\':
			b.WriteByte('\\')
			b.WriteRune(r)
		case r == '\t':
			b.WriteString(`\t`)
		case r == '\n':
			b.WriteString(`\n`)
		case r == '\r':
			b.WriteString(`\r`)
		case r < 0x20 || r == 0x7f:
			fmt.Fprintf(&b, "\\x%02x", r)
		case !unicode.IsPrint(r):
			switch {
			case r < 0x100:
				fmt.Fprintf(&b, "\\x%02x", r)
			case r < 0x10000:
				fmt.Fprintf(&b, "\\u%04x", r)
			default:
				fmt.Fprintf(&b, "\\U%08x", r)
			}
		default:
			b.WriteRune(r)
		}
		i += w
	}
	b.WriteByte(quote)
	return b.String()
}

// strerror is the C library text Python puts after "[Errno N]".
var strerror = map[syscall.Errno]string{
	syscall.EPERM: "Operation not permitted", syscall.ENOENT: "No such file or directory", syscall.EIO: "Input/output error",
	syscall.EACCES: "Permission denied", syscall.EEXIST: "File exists", syscall.ENOTDIR: "Not a directory",
	syscall.EISDIR: "Is a directory", syscall.EINVAL: "Invalid argument", syscall.ENOSPC: "No space left on device",
	syscall.EROFS: "Read-only file system", syscall.ELOOP: "Too many levels of symbolic links",
	syscall.ENAMETOOLONG: "File name too long", syscall.EMFILE: "Too many open files",
	syscall.ENOTEMPTY: "Directory not empty", syscall.EXDEV: "Invalid cross-device link",
	syscall.EBUSY: "Device or resource busy", syscall.ENXIO: "No such device or address",
}

// osErrorText is str(OSError(errno, strerror, filename)): "[Errno 2] No such file or directory: 'x'".
func osErrorText(err error, filename string) string {
	var errno syscall.Errno
	if !errors.As(err, &errno) {
		if !errors.Is(err, fs.ErrNotExist) {
			return err.Error()
		}
		errno = syscall.ENOENT
	}
	text, ok := strerror[errno]
	if !ok {
		text = errno.Error()
	}
	msg := fmt.Sprintf("[Errno %d] %s", int(errno), text)
	if filename != "" {
		msg += ": " + pyRepr(filename)
	}
	return msg
}

// osErr is the legacy tool's one-line message for an OSError about name.
func osErr(err error, name string) error {
	var pe *os.PathError
	if errors.As(err, &pe) {
		err = pe.Err
	}
	return errors.New(osErrorText(err, name))
}

type rpItem struct {
	s      string
	marker bool // CPython's None: the symlink below it has been resolved
}

// realpath is posixpath.realpath(p, strict=strict) with the working directory injected (cwd must be
// absolute and symlink-free, as os.getcwd() is). Loops and unreadable links are left in place when not strict.
func realpath(p string, strict bool, cwd string) (string, error) {
	rest := []rpItem{}
	for _, c := range strings.Split(strings.TrimRight(p, "/"), "/") {
		rest = append([]rpItem{{s: c}}, rest...)
	}
	partCount := len(rest)
	cur := "/"
	if !strings.HasPrefix(p, "/") {
		if cwd == "" {
			return "", errors.New("a relative path needs an injected working directory")
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

// resolve is str(pathlib.Path(p).resolve(strict=strict)); a failure is the OSError text about the
// component that failed.
func resolve(p string, strict bool, cwd string) (string, error) {
	r, err := realpath(pyNorm(p), strict, cwd)
	if err != nil {
		var pe *os.PathError
		if errors.As(err, &pe) {
			return "", errors.New(osErrorText(pe.Err, pe.Path))
		}
		return "", osErr(err, "")
	}
	return r, nil
}
