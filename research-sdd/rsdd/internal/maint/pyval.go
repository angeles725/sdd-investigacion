package maint

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"strconv"
	"strings"
	"unicode"
	"unicode/utf8"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/jsonout"
)

// The RDD drivers (rdd-start, rdd-drive) print provider JSON back to the maintainer in Python's own
// forms: json.dumps keeps insertion order and uses ", " and ": ", and "%s" of a None or True prints
// None and True. This file is the small value model that keeps those lines byte-identical to the
// legacy kit-rdd-*.py output, while every scalar is still encoded by core/jsonout.

// obj is a JSON object that remembers key order, as a Python dict does. A repeated key keeps its
// first position and takes the last value.
type obj struct {
	keys []string
	m    map[string]any
}

func (o *obj) get(k string) any { return o.m[k] }

func (o *obj) has(k string) bool { _, ok := o.m[k]; return ok }

func (o *obj) set(k string, v any) {
	if _, ok := o.m[k]; !ok {
		o.keys = append(o.keys, k)
	}
	o.m[k] = v
}

// decodeJSON parses exactly one JSON document: trailing text is an error, like json.loads.
func decodeJSON(b []byte) (any, error) {
	dec := json.NewDecoder(bytes.NewReader(b))
	dec.UseNumber()
	v, err := readValue(dec)
	if err != nil {
		return nil, err
	}
	if _, err := dec.Token(); !errors.Is(err, io.EOF) {
		return nil, errors.New("extra data after the JSON document")
	}
	return v, nil
}

func readValue(dec *json.Decoder) (any, error) {
	tok, err := dec.Token()
	if err != nil {
		return nil, err
	}
	d, ok := tok.(json.Delim)
	if !ok {
		return tok, nil // nil, bool, json.Number or string
	}
	if d == '[' {
		list := []any{}
		for dec.More() {
			v, err := readValue(dec)
			if err != nil {
				return nil, err
			}
			list = append(list, v)
		}
		_, err := dec.Token()
		return list, err
	}
	o := &obj{m: map[string]any{}}
	for dec.More() {
		kt, err := dec.Token()
		if err != nil {
			return nil, err
		}
		v, err := readValue(dec)
		if err != nil {
			return nil, err
		}
		o.set(kt.(string), v)
	}
	_, err = dec.Token()
	return o, err
}

// plain converts a decoded value to the map/slice form core/jsonout encodes (sorted keys).
func plain(v any) any {
	switch t := v.(type) {
	case *obj:
		m := make(map[string]any, len(t.keys))
		for _, k := range t.keys {
			m[k] = plain(t.m[k])
		}
		return m
	case []any:
		out := make([]any, len(t))
		for i, e := range t {
			out[i] = plain(e)
		}
		return out
	}
	return v
}

// scalarJSON is json.dumps of a scalar (ensure_ascii), via core/jsonout.
func scalarJSON(v any) string {
	b, err := jsonout.Encode(v, jsonout.Options{ASCII: true})
	if err != nil {
		if n, ok := v.(json.Number); ok {
			return n.String()
		}
		return "null"
	}
	return strings.TrimSuffix(string(b), "\n")
}

// pyDumps is json.dumps(v): insertion order, ", " and ": ", ensure_ascii.
func pyDumps(v any) string {
	switch t := v.(type) {
	case []any:
		parts := make([]string, len(t))
		for i, e := range t {
			parts[i] = pyDumps(e)
		}
		return "[" + strings.Join(parts, ", ") + "]"
	case *obj:
		parts := make([]string, len(t.keys))
		for i, k := range t.keys {
			parts[i] = scalarJSON(k) + ": " + pyDumps(t.m[k])
		}
		return "{" + strings.Join(parts, ", ") + "}"
	}
	return scalarJSON(v)
}

// pyIndented is json.dumps(v, indent=2, sort_keys=True) without the final newline.
func pyIndented(v any) string {
	b, err := jsonout.Indented(plain(v))
	if err != nil {
		return pyDumps(v)
	}
	return strings.TrimSuffix(string(b), "\n")
}

// truthy is Python truthiness for a decoded JSON value.
func truthy(v any) bool {
	switch t := v.(type) {
	case nil:
		return false
	case bool:
		return t
	case string:
		return t != ""
	case json.Number:
		f, err := strconv.ParseFloat(string(t), 64)
		return err != nil || f != 0
	case []any:
		return len(t) > 0
	case *obj:
		return len(t.keys) > 0
	}
	return true
}

// pyStr is str(v) as "%s" formats it.
func pyStr(v any) string {
	if s, ok := v.(string); ok {
		return s
	}
	return pyRepr(v)
}

// pyRepr is repr(v) of a decoded JSON value.
func pyRepr(v any) string {
	switch t := v.(type) {
	case nil:
		return "None"
	case bool:
		if t {
			return "True"
		}
		return "False"
	case json.Number:
		return scalarJSON(t)
	case string:
		return pyStrRepr(t)
	case []any:
		parts := make([]string, len(t))
		for i, e := range t {
			parts[i] = pyRepr(e)
		}
		return "[" + strings.Join(parts, ", ") + "]"
	case *obj:
		parts := make([]string, len(t.keys))
		for i, k := range t.keys {
			parts[i] = pyStrRepr(k) + ": " + pyRepr(t.m[k])
		}
		return "{" + strings.Join(parts, ", ") + "}"
	}
	return "?"
}

// pyStrRepr is repr(str): single quotes unless the text holds ' and no ".
func pyStrRepr(s string) string {
	q := '\''
	if strings.Contains(s, "'") && !strings.Contains(s, `"`) {
		q = '"'
	}
	var b strings.Builder
	b.WriteRune(q)
	for _, r := range s {
		switch {
		case r == q || r == '\\':
			b.WriteByte('\\')
			b.WriteRune(r)
		case r == '\n':
			b.WriteString(`\n`)
		case r == '\r':
			b.WriteString(`\r`)
		case r == '\t':
			b.WriteString(`\t`)
		case unicode.IsPrint(r):
			b.WriteRune(r)
		case r < 0x100:
			b.WriteString(`\x` + hexN(r, 2))
		case r < 0x10000:
			b.WriteString(`\u` + hexN(r, 4))
		default:
			b.WriteString(`\U` + hexN(r, 8))
		}
	}
	b.WriteRune(q)
	return b.String()
}

func hexN(r rune, n int) string {
	s := strconv.FormatUint(uint64(r), 16)
	return strings.Repeat("0", n-len(s)) + s
}

// head is s[:n] counted in characters, as Python slices a str.
func head(s string, n int) string {
	if utf8.RuneCountInString(s) <= n {
		return s
	}
	return string([]rune(s)[:n])
}

// tail is s[-n:] counted in characters.
func tail(s string, n int) string {
	r := []rune(s)
	if len(r) <= n {
		return s
	}
	return string(r[len(r)-n:])
}
