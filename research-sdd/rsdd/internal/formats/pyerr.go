package formats

import (
	"errors"
	"fmt"
	"strings"
	"syscall"
	"unicode"
	"unicode/utf8"
)

// pyRepr is Python's repr() of a str, which is how an OSError message names its file:
// single quotes unless the text holds a single quote and no double quote, backslash and the quote escaped,
// \n \r \t and other control characters as escapes, printable text kept.
func pyRepr(s string) string {
	quote := byte('\'')
	if strings.ContainsRune(s, '\'') && !strings.ContainsRune(s, '"') {
		quote = '"'
	}
	var b strings.Builder
	b.WriteByte(quote)
	for i := 0; i < len(s); {
		r, w := utf8.DecodeRuneInString(s[i:])
		switch {
		case r == utf8.RuneError && w == 1:
			fmt.Fprintf(&b, "\\udc%02x", s[i]) // surrogateescape, as a Python path with an undecodable byte
		case r == rune(quote) || r == '\\':
			b.WriteByte('\\')
			b.WriteRune(r)
		case r == '\n':
			b.WriteString(`\n`)
		case r == '\r':
			b.WriteString(`\r`)
		case r == '\t':
			b.WriteString(`\t`)
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

// osErrorText is str(OSError(errno, strerror, filename)): "[Errno N] text" with ": 'filename'" when named.
func osErrorText(en syscall.Errno, filename string) string {
	if filename == "" {
		return fmt.Sprintf("[Errno %d] %s", int(en), strerror(en))
	}
	return fmt.Sprintf("[Errno %d] %s: %s", int(en), strerror(en), pyRepr(filename))
}

// pyPathJoin joins an injected working directory and a relative path without cleaning it, so a ".." stays
// visible to the guards that look for it. An absolute path is returned unchanged.
func pyPathJoin(cwd, p string) string {
	if strings.HasPrefix(p, "/") || cwd == "" {
		return p
	}
	return strings.TrimRight(cwd, "/") + "/" + p
}
