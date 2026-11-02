package floss

import (
	"errors"
	"fmt"
	"strings"
	"syscall"
	"unicode"
	"unicode/utf8"
)

// Python text helpers: the spellings the legacy script prints (repr, str.strip, str.splitlines, OSError).

// pyRepr is repr() of a str: single quotes unless the text holds a single quote and no double quote,
// backslash and the quote escaped, \n \r \t and other control characters as escapes, printable text kept.
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

// pySpace is str.isspace for one character: Unicode white space plus the ASCII separators U+001C..U+001F.
func pySpace(r rune) bool { return unicode.IsSpace(r) || (r >= 0x1c && r <= 0x1f) }

// pyStrip is str.strip().
func pyStrip(s string) string { return strings.TrimFunc(s, pySpace) }

// pyFirstLine is s.splitlines()[0] for a non-empty s: the text up to the first line boundary
// (\n \r \v \f U+001C-U+001E U+0085 U+2028 U+2029).
func pyFirstLine(s string) string {
	for i, r := range s {
		switch r {
		case '\n', '\r', '\v', '\f', 0x1c, 0x1d, 0x1e, 0x85, 0x2028, 0x2029:
			return s[:i]
		}
	}
	return s
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

// errnoOf returns the errno inside err, if any.
func errnoOf(err error) (syscall.Errno, bool) {
	var en syscall.Errno
	if errors.As(err, &en) {
		return en, true
	}
	return 0, false
}
