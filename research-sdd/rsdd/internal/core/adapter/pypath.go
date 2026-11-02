package adapter

import (
	"strconv"
	"strings"
	"unicode"
	"unicode/utf8"
)

// This file holds the few CPython string/path semantics the port must match
// byte for byte, because they decide mount-point selection and show up in
// error messages (repr of a mountinfo line).

// pyParts is pathlib.PurePosixPath(p).parts: a leading root ("/" or, for
// exactly two slashes, "//"), then the components with "" and "." dropped.
// An empty path has no parts.
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
		case r == ' ' || (r >= 0x20 && r < 0x7f):
			b.WriteRune(r)
		case r < 0x7f || !unicode.IsPrint(r):
			switch {
			case r <= 0xff:
				b.WriteString(`\x` + hex(r, 2))
			case r <= 0xffff:
				b.WriteString(`\u` + hex(r, 4))
			default:
				b.WriteString(`\U` + hex(r, 8))
			}
		default:
			b.WriteRune(r)
		}
	}
	b.WriteByte(quote)
	return b.String()
}

func hex(r rune, width int) string {
	s := strconv.FormatInt(int64(r), 16)
	return strings.Repeat("0", width-len(s)) + s
}

// pySplitlines is str.splitlines() (no keepends).
func pySplitlines(s string) []string {
	var lines []string
	start := 0
	for i := 0; i < len(s); {
		r, n := utf8.DecodeRuneInString(s[i:])
		switch r {
		case '\n', '\v', '\f', 0x1c, 0x1d, 0x1e, 0x85, 0x2028, 0x2029:
			lines = append(lines, s[start:i])
			i += n
			start = i
		case '\r':
			lines = append(lines, s[start:i])
			i += n
			if i < len(s) && s[i] == '\n' {
				i++
			}
			start = i
		default:
			i += n
		}
	}
	if start < len(s) {
		lines = append(lines, s[start:])
	}
	return lines
}

func pySpace(r rune) bool { return unicode.IsSpace(r) || (r >= 0x1c && r <= 0x1f) }

// pyFields is str.split() with no argument.
func pyFields(s string) []string { return strings.FieldsFunc(s, pySpace) }
