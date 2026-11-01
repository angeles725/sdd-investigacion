package bog

import (
	"strings"
	"unicode"
	"unicode/utf8"
)

// The helpers in this file reproduce the Python str behaviours the legacy bog readers lean on: UTF-8 decoding
// with errors='replace', str.splitlines(), str.isspace() and the \w class of the re module. Go's stdlib
// differs on each (per-byte replacement, a shorter line-break set, no 0x1c-0x1f whitespace, ASCII-only \w), and
// the difference shows up in the emitted evidence, so they are ported rather than approximated.

const replacement = "�"

// DecodeReplace decodes b as UTF-8 the way bytes.decode('utf-8', errors='replace') does: every maximal invalid
// prefix of a sequence becomes ONE U+FFFD (Go's []rune conversion would emit one per byte). A byte order mark
// is kept as U+FEFF.
func DecodeReplace(b []byte) string {
	if utf8.Valid(b) {
		return string(b)
	}
	var sb strings.Builder
	sb.Grow(len(b))
	for i := 0; i < len(b); {
		c := b[i]
		if c < utf8.RuneSelf {
			sb.WriteByte(c)
			i++
			continue
		}
		n := validPrefix(b[i:])
		if n < 0 { // a complete sequence of -n bytes
			sb.Write(b[i : i-n])
			i -= n
			continue
		}
		sb.WriteString(replacement)
		i += n
	}
	return sb.String()
}

// validPrefix classifies the sequence starting at b[0] (a non-ASCII byte). It returns -k for a complete valid
// k-byte sequence, or k >= 1 for the length of the maximal invalid prefix to replace.
func validPrefix(b []byte) int {
	var need int
	lo, hi := byte(0x80), byte(0xBF)
	switch c := b[0]; {
	case c >= 0xC2 && c <= 0xDF:
		need = 1
	case c == 0xE0:
		need, lo = 2, 0xA0
	case c >= 0xE1 && c <= 0xEC, c == 0xEE, c == 0xEF:
		need = 2
	case c == 0xED:
		need, hi = 2, 0x9F
	case c == 0xF0:
		need, lo = 3, 0x90
	case c >= 0xF1 && c <= 0xF3:
		need = 3
	case c == 0xF4:
		need, hi = 3, 0x8F
	default: // continuation byte, C0, C1, F5..FF
		return 1
	}
	for k := 1; k <= need; k++ {
		if k >= len(b) {
			return k
		}
		if k == 1 {
			if b[1] < lo || b[1] > hi {
				return 1
			}
			continue
		}
		if b[k] < 0x80 || b[k] > 0xBF {
			return k
		}
	}
	return -(need + 1)
}

// IsSpace reports str.isspace() for one rune: the Unicode White_Space set plus the ASCII separators
// 0x1c-0x1f that Python also treats as whitespace.
func IsSpace(r rune) bool { return unicode.IsSpace(r) || (r >= 0x1c && r <= 0x1f) }

// IsWord reports whether r is in Python's re \w class for str patterns: letters, numbers and underscore.
func IsWord(r rune) bool { return r == '_' || unicode.IsLetter(r) || unicode.IsNumber(r) }

// TrimRightSpace is str.rstrip().
func TrimRightSpace(s string) string { return strings.TrimRightFunc(s, IsSpace) }

// TrimSpace is str.strip().
func TrimSpace(s string) string { return strings.TrimFunc(s, IsSpace) }

// Fields is str.split() with no argument.
func Fields(s string) []string { return strings.FieldsFunc(s, IsSpace) }

// SplitLines is str.splitlines(): it breaks on \n, \r, \r\n, \v, \f, 0x1c-0x1e, U+0085, U+2028 and U+2029, and
// leaves no empty tail after a final break.
func SplitLines(s string) []string {
	lines := []string{}
	start := 0
	for i := 0; i < len(s); {
		r, size := utf8.DecodeRuneInString(s[i:])
		switch r {
		case '\n', '\v', '\f', 0x1c, 0x1d, 0x1e, 0x85, 0x2028, 0x2029:
			lines = append(lines, s[start:i])
			i += size
			start = i
		case '\r':
			lines = append(lines, s[start:i])
			i += size
			if i < len(s) && s[i] == '\n' {
				i++
			}
			start = i
		default:
			i += size
		}
	}
	if start < len(s) {
		lines = append(lines, s[start:])
	}
	return lines
}
