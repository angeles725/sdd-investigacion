package floss

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"strings"
	"unicode/utf8"
)

// A decoder with the messages and positions of Python 3.12's json.loads (the C scanner), because the legacy
// script copies str(JSONDecodeError) into the evidence's errors list: encoding/json words and positions its
// errors differently.
//
// Values: objects are map[string]any, arrays []any, numbers json.Number (the source text, so the encoder prints
// ints and floats exactly as Python would), strings string, NaN/Infinity/-Infinity float64.
//
// Not carried over (documented in floss-evidence.v1.md): bytes that are not UTF-8 (UTF-16 and UTF-32 payloads
// included) and lone surrogates (\ud800 not followed by a low surrogate) decode in Python but cannot be held in
// a Go string; they are refused with errUnsupportedText instead.

// jsonError is json.JSONDecodeError; Error() is its str().
type jsonError struct{ msg string }

func (e *jsonError) Error() string { return e.msg }

// errUnsupportedText is a payload Python decodes and this port does not (see the file comment).
var errUnsupportedText = errors.New("floss stdout is not UTF-8 JSON text this port can hold (invalid UTF-8, UTF-16/32 or a lone surrogate)")

type stopIteration struct{ idx int }

func (e *stopIteration) Error() string { return "stop iteration" }

// scanner holds the document as code points: Python reports positions in characters.
type scanner struct {
	doc  []rune
	lone bool // a lone surrogate was read: Python holds it, a Go string cannot
}

// decodePyJSON is json.loads(raw) for bytes: the encoding is detected, one UTF-8 BOM is skipped, then the
// document must be exactly one value surrounded by JSON whitespace.
func decodePyJSON(raw []byte) (any, error) {
	body, err := detectUTF8(raw)
	if err != nil {
		return nil, err
	}
	if !utf8.Valid(body) {
		return nil, errUnsupportedText
	}
	sc := &scanner{doc: []rune(string(body))}
	idx := sc.skipWS(0)
	v, end, err := sc.value(idx)
	if err != nil {
		var stop *stopIteration
		if errors.As(err, &stop) {
			return nil, sc.errorAt("Expecting value", stop.idx)
		}
		return nil, err
	}
	end = sc.skipWS(end)
	if end != len(sc.doc) {
		return nil, sc.errorAt("Extra data", end)
	}
	if sc.lone {
		return nil, errUnsupportedText // only now: a syntax error further on is reported first, as Python does
	}
	return v, nil
}

// detectUTF8 is json.detect_encoding followed by the decode: only UTF-8 (with or without a BOM) is supported.
func detectUTF8(b []byte) ([]byte, error) {
	switch {
	case bytes.HasPrefix(b, []byte{0xff, 0xfe, 0, 0}), bytes.HasPrefix(b, []byte{0, 0, 0xfe, 0xff}),
		bytes.HasPrefix(b, []byte{0xff, 0xfe}), bytes.HasPrefix(b, []byte{0xfe, 0xff}):
		return nil, errUnsupportedText
	case bytes.HasPrefix(b, []byte{0xef, 0xbb, 0xbf}):
		return b[3:], nil
	}
	if len(b) >= 4 && (b[0] == 0 || b[1] == 0) {
		return nil, errUnsupportedText
	}
	if len(b) == 2 && (b[0] == 0 || b[1] == 0) {
		return nil, errUnsupportedText
	}
	return b, nil
}

// errorAt is JSONDecodeError(msg, doc, pos): "msg: line L column C (char P)".
func (sc *scanner) errorAt(msg string, pos int) error {
	line, col := 1, pos+1
	for i := 0; i < pos && i < len(sc.doc); i++ {
		if sc.doc[i] == '\n' {
			line++
			col = pos - i
		}
	}
	return &jsonError{msg: fmt.Sprintf("%s: line %d column %d (char %d)", msg, line, col, pos)}
}

func isWS(r rune) bool { return r == ' ' || r == '\t' || r == '\n' || r == '\r' }

func (sc *scanner) skipWS(i int) int {
	for i < len(sc.doc) && isWS(sc.doc[i]) {
		i++
	}
	return i
}

func (sc *scanner) at(i int, r rune) bool { return i < len(sc.doc) && sc.doc[i] == r }

func (sc *scanner) hasPrefix(i int, lit string) bool {
	rs := []rune(lit)
	if i+len(rs) > len(sc.doc) {
		return false
	}
	for k, r := range rs {
		if sc.doc[i+k] != r {
			return false
		}
	}
	return true
}

// value is scan_once: it returns the value and the index after it, or a *stopIteration at the start of a
// value that cannot be read.
func (sc *scanner) value(i int) (any, int, error) {
	if i >= len(sc.doc) {
		return nil, 0, &stopIteration{i}
	}
	switch c := sc.doc[i]; {
	case c == '"':
		return sc.str(i + 1)
	case c == '{':
		return sc.object(i + 1)
	case c == '[':
		return sc.array(i + 1)
	case c == 'n' && sc.hasPrefix(i, "null"):
		return nil, i + 4, nil
	case c == 't' && sc.hasPrefix(i, "true"):
		return true, i + 4, nil
	case c == 'f' && sc.hasPrefix(i, "false"):
		return false, i + 5, nil
	case c == 'N' && sc.hasPrefix(i, "NaN"):
		return math.NaN(), i + 3, nil
	case c == 'I' && sc.hasPrefix(i, "Infinity"):
		return math.Inf(1), i + 8, nil
	case c == '-' && sc.hasPrefix(i, "-Infinity"):
		return math.Inf(-1), i + 9, nil
	}
	return sc.number(i)
}

// number is _match_number_unicode: -?(0|[1-9]\d*)(\.\d+)?([eE][-+]?\d+)?, with the fraction and the exponent
// left out of the match (not an error) when they are incomplete.
func (sc *scanner) number(start int) (any, int, error) {
	i := start
	if sc.at(i, '-') {
		i++
	}
	switch {
	case i < len(sc.doc) && sc.doc[i] >= '1' && sc.doc[i] <= '9':
		for i < len(sc.doc) && isDigit(sc.doc[i]) {
			i++
		}
	case sc.at(i, '0'):
		i++
	default:
		return nil, 0, &stopIteration{start}
	}
	if sc.at(i, '.') && i+1 < len(sc.doc) && isDigit(sc.doc[i+1]) {
		i += 2
		for i < len(sc.doc) && isDigit(sc.doc[i]) {
			i++
		}
	}
	if sc.at(i, 'e') || sc.at(i, 'E') {
		j := i + 1
		if sc.at(j, '+') || sc.at(j, '-') {
			j++
		}
		if j < len(sc.doc) && isDigit(sc.doc[j]) {
			for j < len(sc.doc) && isDigit(sc.doc[j]) {
				j++
			}
			i = j
		}
	}
	return json.Number(string(sc.doc[start:i])), i, nil
}

func isDigit(r rune) bool { return r >= '0' && r <= '9' }

func hexVal(r rune) (int, bool) {
	switch {
	case r >= '0' && r <= '9':
		return int(r - '0'), true
	case r >= 'a' && r <= 'f':
		return int(r-'a') + 10, true
	case r >= 'A' && r <= 'F':
		return int(r-'A') + 10, true
	}
	return 0, false
}

// str is scanstring_unicode(end, strict=True): i is the index after the opening quote.
func (sc *scanner) str(end int) (any, int, error) {
	begin := end - 1
	n := len(sc.doc)
	var b strings.Builder
	for {
		next := end
		var c rune
		for ; next < n; next++ {
			d := sc.doc[next]
			if d == '"' || d == '\\' {
				c = d
				break
			}
			if d <= 0x1f {
				return nil, 0, sc.errorAt("Invalid control character at", next)
			}
		}
		if next >= n {
			return nil, 0, sc.errorAt("Unterminated string starting at", begin)
		}
		b.WriteString(string(sc.doc[end:next]))
		next++
		if c == '"' {
			return b.String(), next, nil
		}
		if next == n {
			return nil, 0, sc.errorAt("Unterminated string starting at", begin)
		}
		esc := sc.doc[next]
		if esc != 'u' {
			end = next + 1
			var out rune
			switch esc {
			case '"', '\\', '/':
				out = esc
			case 'b':
				out = '\b'
			case 'f':
				out = '\f'
			case 'n':
				out = '\n'
			case 'r':
				out = '\r'
			case 't':
				out = '\t'
			default:
				return nil, 0, sc.errorAt("Invalid \\escape", end-2)
			}
			b.WriteRune(out)
			continue
		}
		next++
		end = next + 4
		if end >= n {
			return nil, 0, sc.errorAt("Invalid \\uXXXX escape", next-1)
		}
		c32, err := sc.hex4(next, end-5)
		if err != nil {
			return nil, 0, err
		}
		next = end
		if c32 >= 0xd800 && c32 <= 0xdbff && end+6 < n && sc.doc[next] == '\\' && sc.doc[next+1] == 'u' {
			next += 2
			end += 6
			c2, err := sc.hex4(next, end-5)
			if err != nil {
				return nil, 0, err
			}
			if c2 >= 0xdc00 && c2 <= 0xdfff {
				c32 = 0x10000 + (c32-0xd800)<<10 + (c2 - 0xdc00)
			} else {
				end -= 6
			}
		}
		if c32 >= 0xd800 && c32 <= 0xdfff {
			sc.lone, c32 = true, 0xfffd
		}
		b.WriteRune(rune(c32))
	}
}

// hex4 reads four hex digits at i; a bad digit is an "Invalid \uXXXX escape" at errPos.
func (sc *scanner) hex4(i, errPos int) (int, error) {
	v := 0
	for k := 0; k < 4; k++ {
		d, ok := hexVal(sc.doc[i+k])
		if !ok {
			return 0, sc.errorAt("Invalid \\uXXXX escape", errPos)
		}
		v = v<<4 | d
	}
	return v, nil
}

// object is _parse_object_unicode; i is the index after "{".
func (sc *scanner) object(i int) (any, int, error) {
	out := map[string]any{}
	i = sc.skipWS(i)
	if !sc.at(i, '}') {
		for {
			if !sc.at(i, '"') {
				return nil, 0, sc.errorAt("Expecting property name enclosed in double quotes", i)
			}
			k, next, err := sc.str(i + 1)
			if err != nil {
				return nil, 0, err
			}
			i = sc.skipWS(next)
			if !sc.at(i, ':') {
				return nil, 0, sc.errorAt("Expecting ':' delimiter", i)
			}
			i = sc.skipWS(i + 1)
			v, next, err := sc.value(i)
			if err != nil {
				return nil, 0, err
			}
			out[k.(string)] = v
			i = sc.skipWS(next)
			if sc.at(i, '}') {
				break
			}
			if !sc.at(i, ',') {
				return nil, 0, sc.errorAt("Expecting ',' delimiter", i)
			}
			i = sc.skipWS(i + 1)
		}
	}
	return out, i + 1, nil
}

// array is _parse_array_unicode; i is the index after "[".
func (sc *scanner) array(i int) (any, int, error) {
	out := []any{}
	i = sc.skipWS(i)
	if !sc.at(i, ']') {
		for {
			v, next, err := sc.value(i)
			if err != nil {
				return nil, 0, err
			}
			out = append(out, v)
			i = sc.skipWS(next)
			if sc.at(i, ']') {
				break
			}
			if !sc.at(i, ',') {
				return nil, 0, sc.errorAt("Expecting ',' delimiter", i)
			}
			i = sc.skipWS(i + 1)
		}
	}
	return out, i + 1, nil
}
