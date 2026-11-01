package serial

import (
	"errors"
	"fmt"
	"math"
	"math/big"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"unicode"
	"unicode/utf8"
)

// Helpers that reproduce the Python behaviours the legacy serial-frame scripts relied on: str.splitlines,
// str.strip, bytes.decode("utf-8", "replace"), repr(str), int(), float() and OSError texts.

// pyRepr is Python's repr() of a str: single quotes unless the text holds a single quote and no double quote,
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

// isPySpace is str.isspace() for one character: Go's unicode.IsSpace plus the four ASCII separators
// U+001C..U+001F that Python also counts as whitespace.
func isPySpace(r rune) bool { return unicode.IsSpace(r) || (r >= 0x1c && r <= 0x1f) }

func pyStrip(s string) string { return strings.TrimFunc(s, isPySpace) }

// pySplitLines is str.splitlines(): it breaks at \n \r \r\n \v \f U+001C..U+001E U+0085 U+2028 U+2029 and
// drops the terminator and a final empty piece.
func pySplitLines(s string) []string {
	var lines []string
	start := 0
	for i := 0; i < len(s); {
		r, w := utf8.DecodeRuneInString(s[i:])
		isBreak := false
		switch r {
		case '\n', '\v', '\f', 0x1c, 0x1d, 0x1e, 0x85, 0x2028, 0x2029:
			isBreak = true
		case '\r':
			isBreak = true
			if i+1 < len(s) && s[i+1] == '\n' {
				w++
			}
		}
		if isBreak {
			lines = append(lines, s[start:i])
			start = i + w
		}
		i += w
	}
	if start < len(s) {
		lines = append(lines, s[start:])
	}
	return lines
}

// invalidPrefixLen is the length of the maximal invalid subpart at the head of b (b[0] does not start a valid
// UTF-8 sequence): the lead byte plus the continuation bytes that still fit a valid sequence.
func invalidPrefixLen(b []byte) int {
	lo, hi := byte(0x80), byte(0xbf)
	need := 0
	switch lead := b[0]; {
	case lead >= 0xe0 && lead <= 0xef:
		need = 2
		if lead == 0xe0 {
			lo = 0xa0
		}
		if lead == 0xed {
			hi = 0x9f
		}
	case lead >= 0xf0 && lead <= 0xf4:
		need = 3
		if lead == 0xf0 {
			lo = 0x90
		}
		if lead == 0xf4 {
			hi = 0x8f
		}
	}
	n := 1
	for ; n <= need && n < len(b); n++ {
		if b[n] < lo || b[n] > hi {
			break
		}
		lo, hi = 0x80, 0xbf
	}
	return n
}

// pyDecodeReplace is bytes.decode("utf-8", errors="replace"): every maximal invalid subpart becomes one
// U+FFFD (Go's own conversion would emit one per byte).
func pyDecodeReplace(b []byte) string {
	var sb strings.Builder
	for i := 0; i < len(b); {
		r, w := utf8.DecodeRune(b[i:])
		if r == utf8.RuneError && w == 1 {
			sb.WriteRune(utf8.RuneError)
			i += invalidPrefixLen(b[i:])
			continue
		}
		sb.WriteRune(r)
		i += w
	}
	return sb.String()
}

// digitValue is the decimal value of a Unicode Nd character (int() accepts them all).
func digitValue(r rune) int {
	for _, rg := range unicode.Nd.R16 {
		if r >= rune(rg.Lo) && r <= rune(rg.Hi) {
			return int(r-rune(rg.Lo)) % 10
		}
	}
	for _, rg := range unicode.Nd.R32 {
		if r >= rune(rg.Lo) && r <= rune(rg.Hi) {
			return int(r-rune(rg.Lo)) % 10
		}
	}
	return 0
}

// decimalString renders a run of Unicode decimal digits as the canonical ASCII integer text int() would print.
func decimalString(digits string) string {
	var b strings.Builder
	for _, r := range digits {
		b.WriteByte(byte('0' + digitValue(r)))
	}
	s := strings.TrimLeft(b.String(), "0")
	if s == "" {
		return "0"
	}
	return s
}

var (
	pyIntSyntax   = regexp.MustCompile(`^[+-]?[0-9]+(_[0-9]+)*$`)
	pyFloatSyntax = regexp.MustCompile(`^[+-]?([0-9]+(_[0-9]+)*(\.([0-9]+(_[0-9]+)*)?)?|\.[0-9]+(_[0-9]+)*)([eE][+-]?[0-9]+(_[0-9]+)*)?$`)
)

// pyParseInt is int(text) for a decimal text: surrounding whitespace, a sign and single underscores between
// digits are accepted. The value is arbitrary precision, as in Python.
func pyParseInt(text string) (*big.Int, bool) {
	t := pyStrip(text)
	if !pyIntSyntax.MatchString(t) {
		return nil, false
	}
	return new(big.Int).SetString(strings.ReplaceAll(t, "_", ""), 10)
}

// pyParseFloat is float(text) for a finite decimal text. inf and nan are refused (ok=false) because the
// evidence documents would carry the non-JSON tokens Infinity and NaN.
func pyParseFloat(text string) (float64, bool) {
	t := pyStrip(text)
	if !pyFloatSyntax.MatchString(t) {
		return 0, false
	}
	f, err := strconv.ParseFloat(strings.ReplaceAll(t, "_", ""), 64)
	if err != nil || math.IsInf(f, 0) {
		return 0, false
	}
	return f, true
}

// roundDigits is Python's round(x, nd): the correctly rounded decimal of the exact binary value.
func roundDigits(x float64, nd int) float64 {
	f, _ := strconv.ParseFloat(strconv.FormatFloat(x, 'f', nd, 64), 64)
	return f
}
