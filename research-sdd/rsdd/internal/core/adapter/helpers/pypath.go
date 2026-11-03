package helpers

import (
	"errors"
	"os"
	"path"
	"strconv"
	"strings"
	"unicode"
)

// Local copies of the CPython path/repr semantics that adapter keeps
// unexported (adapter/pypath.go, adapter/realpath.go), trimmed to what the
// helpers use. Delete this file once adapter exports PyParts, PyNorm, PyRepr
// and Realpath.

// pyParts is pathlib.PurePosixPath(p).parts: a leading root ("/" or, for
// exactly two slashes, "//"), then the components with "" and "." dropped.
func pyParts(p string) []string {
	var parts []string
	if strings.HasPrefix(p, "/") {
		n := len(p) - len(strings.TrimLeft(p, "/"))
		root := "/"
		if n == 2 {
			root = "//"
		}
		parts = append(parts, root)
	}
	for _, c := range strings.Split(p, "/") {
		if c != "" && c != "." {
			parts = append(parts, c)
		}
	}
	return parts
}

// pyNorm is str(pathlib.Path(p)).
func pyNorm(p string) string {
	parts := pyParts(p)
	if len(parts) == 0 {
		return "."
	}
	if strings.HasPrefix(parts[0], "/") {
		return parts[0] + strings.Join(parts[1:], "/")
	}
	return strings.Join(parts, "/")
}

// pyNormpath is os.path.normpath (a str function, unlike Path: it keeps
// exactly two leading slashes and collapses ".." lexically).
func pyNormpath(p string) string {
	c := path.Clean(p)
	if strings.HasPrefix(p, "//") && !strings.HasPrefix(p, "///") {
		return "/" + c
	}
	return c
}

// pyRepr is repr(str).
func pyRepr(s string) string {
	quote := byte('\'')
	if strings.Contains(s, "'") && !strings.Contains(s, "\"") {
		quote = '"'
	}
	var b strings.Builder
	b.WriteByte(quote)
	for _, r := range s {
		switch {
		case r == rune(quote) || r == '\\':
			b.WriteByte('\\')
			b.WriteRune(r)
		case r == '\t':
			b.WriteString(`\t`)
		case r == '\n':
			b.WriteString(`\n`)
		case r == '\r':
			b.WriteString(`\r`)
		case unicode.IsPrint(r):
			b.WriteRune(r)
		case r>>16 != 0:
			b.WriteString(`\U` + hex(r, 8))
		case r>>8 != 0:
			b.WriteString(`\u` + hex(r, 4))
		default:
			b.WriteString(`\x` + hex(r, 2))
		}
	}
	b.WriteByte(quote)
	return b.String()
}

func hex(r rune, width int) string {
	s := strconv.FormatInt(int64(r), 16)
	return strings.Repeat("0", width-len(s)) + s
}

var errNeedCwd = errors.New("helpers: a relative path needs an injected working directory")

type rpItem struct {
	s      string
	marker bool // CPython's None: the symlink below it has been resolved
}

// realpath is posixpath.realpath(p) (non-strict) with the working directory
// injected (cwd must be absolute and symlink-free, as os.getcwd() is). Loops
// and unreadable links are left in place.
func realpath(p, cwd string) (string, error) {
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
			cur = path.Dir(cur)
			continue
		}
		newpath := cur + "/" + name
		if cur == "/" {
			newpath = "/" + name
		}
		if r, ok := seen[newpath]; ok { // only symlinks are ever recorded
			cur = newpath
			if r != nil {
				cur = *r
			}
			continue
		}
		target, err := os.Readlink(newpath)
		if err != nil { // not a symlink, missing or unreadable: kept in place
			cur = newpath
			continue
		}
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
	}
	return cur, nil
}
