package lint

// Python text semantics the legacy lint_block.py relied on, reproduced exactly so the port is byte-identical:
// str.splitlines, str.strip / str.split, the Unicode `\s` `\w` `\d` classes of `re` (Go's are ASCII only) and the
// UTF-8 decoder's error text.

import (
	"fmt"
	"io/fs"
	"strconv"
	"strings"
	"syscall"
	"unicode"
	"unicode/utf8"
)

// wsClass is the body of a character class holding Python's str.isspace() set, which is what `\s` means in a
// Python str pattern. Go's `\s` is ASCII-only and lacks \v.
const wsClass = `\t\n\x0b\x0c\r\x1c-\x1f \x{85}\x{a0}\x{1680}\x{2000}-\x{200a}\x{2028}\x{2029}\x{202f}\x{205f}\x{3000}`

// wordClass is the body of a class holding Python's `\w` (alphanumeric or underscore).
const wordClass = `\p{L}\p{N}_`

func isPySpace(r rune) bool {
	switch r {
	case '\t', '\n', '\v', '\f', '\r', 0x1c, 0x1d, 0x1e, 0x1f, ' ', 0x85, 0xa0, 0x1680, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000:
		return true
	}
	return r >= 0x2000 && r <= 0x200a
}

func isPyWord(r rune) bool { return r == '_' || unicode.IsLetter(r) || unicode.IsNumber(r) }

func pyStrip(s string) string { return strings.TrimFunc(s, isPySpace) }

// pySplitFields is str.split() with no argument.
func pySplitFields(s string) []string { return strings.FieldsFunc(s, isPySpace) }

// pyExcerpt is excerpt(): whitespace-collapsed, cut to n code points with a three-dot tail.
func pyExcerpt(text string, n int) string {
	r := []rune(strings.Join(pySplitFields(text), " "))
	if len(r) <= n {
		return string(r)
	}
	return string(r[:n-1]) + "..."
}

// pySplitLines is str.splitlines() (keepends=False). Universal-newline translation has already run, so \r is
// translated away by the caller; the remaining separators are \n \v \f \x1c-\x1e \x85 \u2028 \u2029.
func pySplitLines(s string) []string {
	var out []string
	start := 0
	for i, r := range s {
		switch r {
		case '\n', '\v', '\f', 0x1c, 0x1d, 0x1e, 0x85, 0x2028, 0x2029:
			out = append(out, s[start:i])
			start = i + utf8.RuneLen(r)
		}
	}
	if start < len(s) {
		out = append(out, s[start:])
	}
	return out
}

// universalNewlines is what open(..., "r") does: \r\n and a lone \r become \n.
func universalNewlines(s string) string {
	if !strings.Contains(s, "\r") {
		return s
	}
	return strings.ReplaceAll(strings.ReplaceAll(s, "\r\n", "\n"), "\r", "\n")
}

// utf8Error returns "" for valid UTF-8, else CPython's UnicodeDecodeError text for the first bad sequence of data.
func utf8Error(data []byte) string {
	for i := 0; i < len(data); {
		b := data[i]
		if b < 0x80 {
			i++
			continue
		}
		lo, hi, need := byte(0x80), byte(0xbf), 0
		switch {
		case b >= 0xc2 && b <= 0xdf:
			need = 1
		case b == 0xe0:
			lo, need = 0xa0, 2
		case b == 0xed:
			hi, need = 0x9f, 2
		case b >= 0xe1 && b <= 0xef:
			need = 2
		case b == 0xf0:
			lo, need = 0x90, 3
		case b == 0xf4:
			hi, need = 0x8f, 3
		case b >= 0xf1 && b <= 0xf3:
			need = 3
		default:
			return fmt.Sprintf("'utf-8' codec can't decode byte 0x%02x in position %d: invalid start byte", b, i)
		}
		n := 1
		for ; n <= need; n++ {
			if i+n >= len(data) {
				return utf8Msg(data, i, n, "unexpected end of data")
			}
			c := data[i+n]
			l, h := byte(0x80), byte(0xbf)
			if n == 1 {
				l, h = lo, hi
			}
			if c < l || c > h {
				return utf8Msg(data, i, n, "invalid continuation byte")
			}
		}
		i += need + 1
	}
	return ""
}

func utf8Msg(data []byte, start, n int, why string) string {
	if n == 1 {
		return fmt.Sprintf("'utf-8' codec can't decode byte 0x%02x in position %d: %s", data[start], start, why)
	}
	return fmt.Sprintf("'utf-8' codec can't decode bytes in position %d-%d: %s", start, start+n-1, why)
}

// pyOSError renders an open() failure the way Python prints an OSError: `[Errno N] Strerror: 'path'`.
func pyOSError(err error, path string) string {
	var en syscall.Errno
	if pe, ok := err.(*fs.PathError); ok {
		if e, ok := pe.Err.(syscall.Errno); ok {
			en = e
		}
	}
	if en == 0 {
		return err.Error()
	}
	msg := en.Error()
	if msg != "" {
		msg = strings.ToUpper(msg[:1]) + msg[1:]
	}
	return fmt.Sprintf("[Errno %d] %s: %s", int(en), msg, pyRepr(path))
}

// pyRepr is repr() of a str.
func pyRepr(s string) string {
	q := byte('\'')
	if strings.Contains(s, "'") && !strings.Contains(s, `"`) {
		q = '"'
	}
	var b strings.Builder
	b.WriteByte(q)
	for _, r := range s {
		switch {
		case r == rune(q) || r == '\\':
			b.WriteByte('\\')
			b.WriteRune(r)
		case r == '\n':
			b.WriteString(`\n`)
		case r == '\r':
			b.WriteString(`\r`)
		case r == '\t':
			b.WriteString(`\t`)
		case r < 0x20 || r == 0x7f:
			fmt.Fprintf(&b, `\x%02x`, r)
		case r < 0x7f || strconv.IsPrint(r):
			b.WriteRune(r)
		case r < 0x100:
			fmt.Fprintf(&b, `\x%02x`, r)
		case r < 0x10000:
			fmt.Fprintf(&b, `\u%04x`, r)
		default:
			fmt.Fprintf(&b, `\U%08x`, r)
		}
	}
	b.WriteByte(q)
	return b.String()
}

// ---- boundary helpers for the rewrites of `\b`, `(?<!\w)` and `\s+` -----------------------------------------------

// skipSpace returns the index of the first byte at or after i that does not start a Python whitespace rune.
func skipSpace(s string, i int) int {
	for i < len(s) {
		r, n := utf8.DecodeRuneInString(s[i:])
		if !isPySpace(r) {
			break
		}
		i += n
	}
	return i
}

// wordBefore reports whether the rune that ends at byte i is a Python word rune (false at the start of s).
func wordBefore(s string, i int) bool {
	r, n := utf8.DecodeLastRuneInString(s[:i])
	return n > 0 && isPyWord(r)
}

// wordAfter reports whether the rune that starts at byte i is a Python word rune (false at the end of s).
func wordAfter(s string, i int) bool {
	r, n := utf8.DecodeRuneInString(s[i:])
	return n > 0 && isPyWord(r)
}
