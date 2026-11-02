package capa

// A json.loads-compatible reader. capa's JSON is read with Python's decoder, and a malformed document is
// reported to the operator with the decoder's own message ("Expecting value: line 1 column 1 (char 0)"),
// so the port reproduces the scanner's grammar, its error texts and its character positions rather than
// using encoding/json.

import (
	"bytes"
	"encoding/json"
	"fmt"
	"math"
	"math/big"
	"strconv"
	"strings"
	"unicode/utf8"
)

// jsonError is a json.JSONDecodeError: the legacy main() catches it and publishes status=failed.
type jsonError struct{ msg string }

func (e *jsonError) Error() string { return e.msg }

// maxJSONDepth stands in for CPython's recursion limit while decoding nested containers.
const maxJSONDepth = 990

// maxIntDigits is CPython's int/str conversion limit.
const maxIntDigits = 4300

// decodeJSON is json.loads(bytes). Objects decode to map[string]any (a later duplicate key wins), arrays to
// []any, integers to json.Number (normalized), other numbers to float64.
func decodeJSON(raw []byte) (any, error) {
	if len(raw) >= 2 && (raw[0] == 0xff && raw[1] == 0xfe || raw[0] == 0xfe && raw[1] == 0xff) || len(raw) >= 4 && (raw[0] == 0 || raw[1] == 0) {
		return nil, &crash{"json.loads: UTF-16/UTF-32 documents are not supported by the port"}
	}
	raw = bytes.TrimPrefix(raw, []byte{0xef, 0xbb, 0xbf})
	if !utf8.Valid(raw) {
		return nil, &crash{"UnicodeDecodeError: 'utf-8' codec can't decode the capa output"}
	}
	d := &jsonDecoder{s: []rune(string(raw))}
	d.skipWS()
	v, err := d.value(0)
	if err != nil {
		return nil, err
	}
	d.skipWS()
	if d.i != len(d.s) {
		return nil, d.errAt("Extra data", d.i)
	}
	return v, nil
}

type jsonDecoder struct {
	s []rune
	i int
}

// errAt is JSONDecodeError(msg, doc, pos).
func (d *jsonDecoder) errAt(msg string, pos int) error {
	line, col := 1, pos+1
	last := -1
	for k := 0; k < pos && k < len(d.s); k++ {
		if d.s[k] == '\n' {
			line++
			last = k
		}
	}
	if last >= 0 {
		col = pos - last
	}
	return &jsonError{fmt.Sprintf("%s: line %d column %d (char %d)", msg, line, col, pos)}
}

func (d *jsonDecoder) skipWS() {
	for d.i < len(d.s) && (d.s[d.i] == ' ' || d.s[d.i] == '\t' || d.s[d.i] == '\n' || d.s[d.i] == '\r') {
		d.i++
	}
}

func (d *jsonDecoder) hasPrefix(lit string) bool {
	rs := []rune(lit)
	if d.i+len(rs) > len(d.s) {
		return false
	}
	for k, r := range rs {
		if d.s[d.i+k] != r {
			return false
		}
	}
	return true
}

func (d *jsonDecoder) peek() (rune, bool) {
	if d.i < len(d.s) {
		return d.s[d.i], true
	}
	return 0, false
}

// value is scan_once: the value starting at d.i (StopIteration is "Expecting value").
func (d *jsonDecoder) value(depth int) (any, error) {
	c, ok := d.peek()
	if !ok {
		return nil, d.errAt("Expecting value", d.i)
	}
	switch {
	case c == '"':
		return d.str()
	case c == '{':
		return d.object(depth)
	case c == '[':
		return d.array(depth)
	case c == 'n' && d.hasPrefix("null"):
		d.i += 4
		return nil, nil
	case c == 't' && d.hasPrefix("true"):
		d.i += 4
		return true, nil
	case c == 'f' && d.hasPrefix("false"):
		d.i += 5
		return false, nil
	case c == 'N' && d.hasPrefix("NaN"):
		d.i += 3
		return math.NaN(), nil
	case c == 'I' && d.hasPrefix("Infinity"):
		d.i += 8
		return math.Inf(1), nil
	case c == '-' && d.hasPrefix("-Infinity"):
		d.i += 9
		return math.Inf(-1), nil
	}
	return d.number()
}

func isDigit(r rune) bool { return r >= '0' && r <= '9' }

// number matches (-?(?:0|[1-9]\d*))(\.\d+)?([eE][-+]?\d+)? at d.i.
func (d *jsonDecoder) number() (any, error) {
	start, j := d.i, d.i
	if j < len(d.s) && d.s[j] == '-' {
		j++
	}
	switch {
	case j < len(d.s) && d.s[j] == '0':
		j++
	case j < len(d.s) && d.s[j] >= '1' && d.s[j] <= '9':
		for j < len(d.s) && isDigit(d.s[j]) {
			j++
		}
	default:
		return nil, d.errAt("Expecting value", start)
	}
	intEnd := j
	isFloat := false
	if j+1 < len(d.s) && d.s[j] == '.' && isDigit(d.s[j+1]) {
		j++
		for j < len(d.s) && isDigit(d.s[j]) {
			j++
		}
		isFloat = true
	}
	if j < len(d.s) && (d.s[j] == 'e' || d.s[j] == 'E') {
		k := j + 1
		if k < len(d.s) && (d.s[k] == '+' || d.s[k] == '-') {
			k++
		}
		if k < len(d.s) && isDigit(d.s[k]) {
			for k < len(d.s) && isDigit(d.s[k]) {
				k++
			}
			j, isFloat = k, true
		}
	}
	d.i = j
	text := string(d.s[start:j])
	if !isFloat {
		digits := string(d.s[start:intEnd])
		if n := len(strings.TrimPrefix(digits, "-")); n > maxIntDigits {
			return nil, &crash{fmt.Sprintf("ValueError: Exceeds the limit (%d digits) for integer string conversion: value has %d digits", maxIntDigits, n)}
		}
		n, _ := new(big.Int).SetString(text, 10)
		return json.Number(n.String()), nil
	}
	f, err := strconv.ParseFloat(text, 64)
	if err != nil && !isRange(err) {
		return nil, &crash{err.Error()}
	}
	return f, nil
}

func isRange(err error) bool {
	ne, ok := err.(*strconv.NumError)
	return ok && ne.Err == strconv.ErrRange
}

var jsonEscapes = map[rune]rune{'"': '"', '\\': '\\', '/': '/', 'b': '\b', 'f': '\f', 'n': '\n', 'r': '\r', 't': '\t'}

// str is scanstring(strict=True) at the opening quote d.i.
func (d *jsonDecoder) str() (any, error) {
	begin := d.i
	d.i++
	var b strings.Builder
	for {
		if d.i >= len(d.s) {
			return nil, d.errAt("Unterminated string starting at", begin)
		}
		c := d.s[d.i]
		switch {
		case c == '"':
			d.i++
			return b.String(), nil
		case c < 0x20:
			return nil, d.errAt("Invalid control character at", d.i)
		case c != '\\':
			b.WriteRune(c)
			d.i++
			continue
		}
		// c is a backslash
		if d.i+1 >= len(d.s) {
			return nil, d.errAt("Unterminated string starting at", begin)
		}
		esc := d.s[d.i+1]
		if esc != 'u' {
			r, ok := jsonEscapes[esc]
			if !ok {
				return nil, d.errAt("Invalid \\escape", d.i)
			}
			b.WriteRune(r)
			d.i += 2
			continue
		}
		u, ok := d.hex4(d.i + 2)
		if !ok {
			return nil, d.errAt("Invalid \\uXXXX escape", d.i+1)
		}
		d.i += 6
		if u >= 0xd800 && u <= 0xdbff && d.i+1 < len(d.s) && d.s[d.i] == '\\' && d.s[d.i+1] == 'u' {
			if u2, ok := d.hex4(d.i + 2); ok && u2 >= 0xdc00 && u2 <= 0xdfff {
				u = 0x10000 + ((u-0xd800)<<10 | (u2 - 0xdc00))
				d.i += 6
			}
		}
		if u >= 0xd800 && u <= 0xdfff {
			return nil, &crash{"a JSON string holds a lone surrogate, which the port cannot represent"}
		}
		b.WriteRune(rune(u))
	}
}

// hex4 reads four hex digits at pos.
func (d *jsonDecoder) hex4(pos int) (int, bool) {
	if pos+4 > len(d.s) {
		return 0, false
	}
	n := 0
	for _, r := range d.s[pos : pos+4] {
		var v int
		switch {
		case r >= '0' && r <= '9':
			v = int(r - '0')
		case r >= 'a' && r <= 'f':
			v = int(r-'a') + 10
		case r >= 'A' && r <= 'F':
			v = int(r-'A') + 10
		default:
			return 0, false
		}
		n = n*16 + v
	}
	return n, true
}

func (d *jsonDecoder) nest(depth int) (int, error) {
	if depth+1 > maxJSONDepth {
		return 0, &crash{"RecursionError: maximum recursion depth exceeded while decoding a JSON document"}
	}
	return depth + 1, nil
}

func (d *jsonDecoder) object(depth int) (any, error) {
	depth, err := d.nest(depth)
	if err != nil {
		return nil, err
	}
	d.i++ // {
	obj := map[string]any{}
	d.skipWS()
	if c, ok := d.peek(); ok && c == '}' {
		d.i++
		return obj, nil
	}
	for {
		if c, ok := d.peek(); !ok || c != '"' {
			return nil, d.errAt("Expecting property name enclosed in double quotes", d.i)
		}
		k, err := d.str()
		if err != nil {
			return nil, err
		}
		d.skipWS()
		if c, ok := d.peek(); !ok || c != ':' {
			return nil, d.errAt("Expecting ':' delimiter", d.i)
		}
		d.i++
		d.skipWS()
		v, err := d.value(depth)
		if err != nil {
			return nil, err
		}
		obj[k.(string)] = v
		d.skipWS()
		c, ok := d.peek()
		switch {
		case ok && c == '}':
			d.i++
			return obj, nil
		case ok && c == ',':
			d.i++
			d.skipWS()
		default:
			return nil, d.errAt("Expecting ',' delimiter", d.i)
		}
	}
}

func (d *jsonDecoder) array(depth int) (any, error) {
	depth, err := d.nest(depth)
	if err != nil {
		return nil, err
	}
	d.i++ // [
	arr := []any{}
	d.skipWS()
	if c, ok := d.peek(); ok && c == ']' {
		d.i++
		return arr, nil
	}
	for {
		v, err := d.value(depth)
		if err != nil {
			return nil, err
		}
		arr = append(arr, v)
		d.skipWS()
		c, ok := d.peek()
		switch {
		case ok && c == ']':
			d.i++
			return arr, nil
		case ok && c == ',':
			d.i++
			d.skipWS()
		default:
			return nil, d.errAt("Expecting ',' delimiter", d.i)
		}
	}
}
