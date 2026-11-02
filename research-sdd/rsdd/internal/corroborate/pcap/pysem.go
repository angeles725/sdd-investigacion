package pcap

import (
	"encoding/json"
	"fmt"
	"math"
	"math/big"
	"regexp"
	"strconv"
	"strings"
	"unicode"
	"unicode/utf8"
)

// This file holds the few CPython string semantics the legacy tools relied on and the output depends on:
// str.splitlines / split / strip, repr, int() and float() parsing, errors="replace" decoding and bytes.fromhex.
// Digits are ASCII only here; the legacy tools also took other Unicode decimal digits (and crashed on the
// ones int() refuses). The Go tools are stricter and crash-free: such a token is simply not a number.

// isSpace is str.isspace for one code point: Unicode White_Space plus the ASCII separators U+001C..U+001F.
func isSpace(r rune) bool { return unicode.IsSpace(r) || (r >= 0x1c && r <= 0x1f) }

// pyStrip is str.strip().
func pyStrip(s string) string { return strings.TrimFunc(s, isSpace) }

// pyFields is str.split() with no separator.
func pyFields(s string) []string { return strings.FieldsFunc(s, isSpace) }

// pyLstrip is str.lstrip().
func pyLstrip(s string) string { return strings.TrimLeftFunc(s, isSpace) }

// pySplitlines is str.splitlines(): it breaks at \n \r \r\n \v \f \x1c \x1d \x1e \x85 U+2028 U+2029, and a
// trailing break does not yield a final empty line.
func pySplitlines(s string) []string {
	var lines []string
	start := 0
	for i := 0; i < len(s); {
		r, w := utf8.DecodeRuneInString(s[i:])
		switch r {
		case '\n', '\v', '\f', 0x1c, 0x1d, 0x1e, 0x85, 0x2028, 0x2029:
			lines = append(lines, s[start:i])
			i += w
			start = i
		case '\r':
			lines = append(lines, s[start:i])
			i += w
			if i < len(s) && s[i] == '\n' {
				i++
			}
			start = i
		default:
			i += w
		}
	}
	if start < len(s) {
		lines = append(lines, s[start:])
	}
	return lines
}

// pyRepr is repr(str).
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
			fmt.Fprintf(&b, "\\udc%02x", s[i]) // surrogateescape, as a Python str with an undecodable byte
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

// pyListRepr is repr(list[str]), which is how subprocess.TimeoutExpired names its command.
func pyListRepr(items []string) string {
	parts := make([]string, len(items))
	for i, it := range items {
		parts[i] = pyRepr(it)
	}
	return "[" + strings.Join(parts, ", ") + "]"
}

// decodeReplace is bytes.decode("utf-8", errors="replace"): every maximal ill-formed subpart becomes one U+FFFD.
func decodeReplace(b []byte) string {
	if utf8.Valid(b) {
		return string(b)
	}
	var out strings.Builder
	for i := 0; i < len(b); {
		r, w := utf8.DecodeRune(b[i:])
		if r != utf8.RuneError || w != 1 {
			out.WriteRune(r)
			i += w
			continue
		}
		out.WriteRune(utf8.RuneError)
		i += illFormedLen(b[i:])
	}
	return out.String()
}

// illFormedLen is the length of the maximal subpart of an ill-formed sequence starting at b[0]: the lead byte
// plus the continuation bytes that were still acceptable. It is at least 1.
func illFormedLen(b []byte) int {
	lo, hi, need := byte(0x80), byte(0xbf), 0
	switch c := b[0]; {
	case c >= 0xc2 && c <= 0xdf:
		need = 1
	case c == 0xe0:
		lo, need = 0xa0, 2
	case c >= 0xe1 && c <= 0xec, c == 0xee, c == 0xef:
		need = 2
	case c == 0xed:
		hi, need = 0x9f, 2
	case c == 0xf0:
		lo, need = 0x90, 3
	case c >= 0xf1 && c <= 0xf3:
		need = 3
	case c == 0xf4:
		hi, need = 0x8f, 3
	default:
		return 1
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

var (
	intRe   = regexp.MustCompile(`^[+-]?[0-9](?:_?[0-9])*$`)
	floatRe = regexp.MustCompile(`^[+-]?(?:(?:[0-9](?:_?[0-9])*)(?:\.(?:[0-9](?:_?[0-9])*)?)?|\.[0-9](?:_?[0-9])*)(?:[eE][+-]?[0-9](?:_?[0-9])*)?$`)
	specRe  = regexp.MustCompile(`^[+-]?(?:inf|infinity|nan)$`)
)

// parseInt is int(str) in base 10 for a token without whitespace: a sign, digits with single underscores
// between them, any magnitude.
func parseInt(tok string) (*big.Int, bool) {
	if !intRe.MatchString(tok) {
		return nil, false
	}
	return new(big.Int).SetString(strings.ReplaceAll(tok, "_", ""), 10)
}

// parseFloat is float(str) for a token without whitespace; a magnitude beyond float64 is an infinity.
func parseFloat(tok string) (float64, bool) {
	lower := strings.ToLower(tok)
	switch {
	case specRe.MatchString(lower):
		if strings.TrimLeft(lower, "+-") == "nan" {
			return math.NaN(), true
		}
		if strings.HasPrefix(lower, "-") {
			return math.Inf(-1), true
		}
		return math.Inf(1), true
	case floatRe.MatchString(tok):
		f, err := strconv.ParseFloat(strings.ReplaceAll(tok, "_", ""), 64)
		if err != nil && !isRange(err) {
			return 0, false
		}
		return f, true
	}
	return 0, false
}

func isRange(err error) bool {
	ne, ok := err.(*strconv.NumError)
	return ok && ne.Err == strconv.ErrRange
}

// asciiDigits reports whether s is one or more ASCII digits.
func asciiDigits(s string) bool {
	if s == "" {
		return false
	}
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return false
		}
	}
	return true
}

// number turns a digit string into the JSON integer int(digits) would give: leading zeros dropped.
func number(digits string) json.Number {
	n, _ := new(big.Int).SetString(digits, 10)
	return json.Number(n.String())
}

// fromHex is bytes.fromhex(s): pairs of hex digits, ASCII whitespace allowed between pairs, anything else
// (an odd digit, a non-hex byte, a non-ASCII character) refused.
func fromHex(s string) ([]byte, bool) {
	out := make([]byte, 0, len(s)/2)
	for i := 0; i < len(s); {
		switch s[i] {
		case ' ', '\t', '\n', '\r', '\v', '\f':
			i++
			continue
		}
		if i+1 >= len(s) {
			return nil, false
		}
		hi, ok1 := hexVal(s[i])
		lo, ok2 := hexVal(s[i+1])
		if !ok1 || !ok2 {
			return nil, false
		}
		out = append(out, hi<<4|lo)
		i += 2
	}
	return out, true
}

func hexVal(c byte) (byte, bool) {
	switch {
	case c >= '0' && c <= '9':
		return c - '0', true
	case c >= 'a' && c <= 'f':
		return c - 'a' + 10, true
	case c >= 'A' && c <= 'F':
		return c - 'A' + 10, true
	}
	return 0, false
}

// isHexDigits is re.match(r"^[0-9a-fA-F]+$", s) for a stripped line.
func isHexDigits(s string) bool {
	if s == "" {
		return false
	}
	for i := 0; i < len(s); i++ {
		if _, ok := hexVal(s[i]); !ok {
			return false
		}
	}
	return true
}
