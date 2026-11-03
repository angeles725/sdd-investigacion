package resume

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"strconv"
	"strings"
	"unicode/utf8"
)

// The two scripts hand JSON values through jq: the PR list of gh is mapped by jq, and resume-render renders any
// document it is given. jv is the value model of that: null (nil), bool, jnum (the number as written), string, []jv and
// *jobj (keys in the order jq keeps them: first insertion position, last value). It is not a general JSON library: it
// has exactly what the two commands need, shaped like jq's observable behaviour (jq 1.8: a number literal keeps its
// literal precision and prints in decNumber's canonical form).
type jv any

// jnum is a JSON number as written in the input.
type jnum string

type jobj struct {
	keys []string
	vals map[string]jv
}

func newObj() *jobj { return &jobj{vals: map[string]jv{}} }

// set adds or overwrites a key; an overwritten key keeps its first position, as jq does.
func (o *jobj) set(k string, v jv) *jobj {
	if _, ok := o.vals[k]; !ok {
		o.keys = append(o.keys, k)
	}
	o.vals[k] = v
	return o
}

func (o *jobj) get(k string) jv { return o.vals[k] }

func (o *jobj) has(k string) bool { _, ok := o.vals[k]; return ok }

// parseDocs reads every JSON document of data (whitespace-separated, as jq does) and reports a malformed stream as
// an error. A leading UTF-8 byte order mark is skipped, as jq does. Invalid UTF-8 inside a string becomes U+FFFD.
func parseDocs(data []byte) ([]jv, error) {
	data = bytes.TrimPrefix(data, []byte("\xef\xbb\xbf"))
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.UseNumber()
	var docs []jv
	for {
		tok, err := dec.Token()
		if errors.Is(err, io.EOF) {
			return docs, nil
		}
		if err != nil {
			return nil, err
		}
		v, err := parseFrom(dec, tok)
		if err != nil {
			return nil, err
		}
		docs = append(docs, v)
	}
}

func parseFrom(dec *json.Decoder, tok json.Token) (jv, error) {
	switch t := tok.(type) {
	case json.Delim:
		switch t {
		case '[':
			arr := []jv{}
			for dec.More() {
				tk, err := dec.Token()
				if err != nil {
					return nil, err
				}
				v, err := parseFrom(dec, tk)
				if err != nil {
					return nil, err
				}
				arr = append(arr, v)
			}
			if _, err := dec.Token(); err != nil {
				return nil, err
			}
			return arr, nil
		case '{':
			o := newObj()
			for dec.More() {
				kt, err := dec.Token()
				if err != nil {
					return nil, err
				}
				key, ok := kt.(string)
				if !ok {
					return nil, errors.New("object key is not a string")
				}
				tk, err := dec.Token()
				if err != nil {
					return nil, err
				}
				v, err := parseFrom(dec, tk)
				if err != nil {
					return nil, err
				}
				o.set(key, v)
			}
			if _, err := dec.Token(); err != nil {
				return nil, err
			}
			return o, nil
		}
		return nil, errors.New("unexpected delimiter")
	case json.Number:
		return jnum(t), nil
	case string, bool, nil:
		return t, nil
	}
	return nil, errors.New("unexpected token")
}

// truthy is jq's truthiness: everything but null and false.
func truthy(v jv) bool {
	if v == nil {
		return false
	}
	b, ok := v.(bool)
	return !ok || b
}

// jqType is jq's `type`.
func jqType(v jv) string {
	switch v.(type) {
	case nil:
		return "null"
	case bool:
		return "boolean"
	case jnum:
		return "number"
	case string:
		return "string"
	case []jv:
		return "array"
	}
	return "object"
}

// field is `.k` on an object; a missing key and a non-object read as null for the callers that guard the type.
func field(v jv, k string) jv {
	if o, ok := v.(*jobj); ok {
		return o.get(k)
	}
	return nil
}

// tostring is jq's `tostring`: a string as is, everything else as compact JSON.
func tostring(v jv) string {
	if s, ok := v.(string); ok {
		return s
	}
	var b strings.Builder
	writeJV(&b, v, false, 0)
	return b.String()
}

// decNumber formats a number literal the way jq 1.8 prints it (decNumber's to-scientific-string of the literal): the
// coefficient and exponent are kept as written, so 1.0 stays 1.0, 1e2 becomes 1E+2 and 10E-3 becomes 0.010.
func decNumber(lit string) string {
	neg := strings.HasPrefix(lit, "-")
	lit = strings.TrimPrefix(lit, "-")
	exp := 0
	if i := strings.IndexAny(lit, "eE"); i >= 0 {
		exp, _ = strconv.Atoi(strings.TrimPrefix(lit[i+1:], "+"))
		lit = lit[:i]
	}
	ip, fp, _ := strings.Cut(lit, ".")
	exp -= len(fp)
	digits := strings.TrimLeft(ip+fp, "0")
	if digits == "" {
		digits = "0"
	}
	adjusted := exp + len(digits) - 1
	var out string
	switch {
	case exp == 0:
		out = digits
	case exp < 0 && adjusted >= -6:
		p := len(digits) + exp
		if p > 0 {
			out = digits[:p] + "." + digits[p:]
		} else {
			out = "0." + strings.Repeat("0", -p) + digits
		}
	default:
		out = digits[:1]
		if len(digits) > 1 {
			out += "." + digits[1:]
		}
		sign := "+"
		if adjusted < 0 {
			sign = "-"
			adjusted = -adjusted
		}
		out += "E" + sign + strconv.Itoa(adjusted)
	}
	if neg {
		out = "-" + out
	}
	return out
}

// writeJV prints v like jq: member order kept, "{}" and "[]" for empty containers, two-space indent when pretty,
// only the characters below U+0020, DEL, the quote and the backslash escaped.
func writeJV(b *strings.Builder, v jv, pretty bool, depth int) {
	nlIndent := func(d int) {
		if pretty {
			b.WriteByte('\n')
			b.WriteString(strings.Repeat("  ", d))
		}
	}
	switch x := v.(type) {
	case nil:
		b.WriteString("null")
	case bool:
		b.WriteString(strconv.FormatBool(x))
	case jnum:
		b.WriteString(decNumber(string(x)))
	case int:
		b.WriteString(strconv.Itoa(x))
	case string:
		writeString(b, x)
	case []jv:
		if len(x) == 0 {
			b.WriteString("[]")
			return
		}
		b.WriteByte('[')
		for i, e := range x {
			if i > 0 {
				b.WriteByte(',')
			}
			nlIndent(depth + 1)
			writeJV(b, e, pretty, depth+1)
		}
		nlIndent(depth)
		b.WriteByte(']')
	case *jobj:
		if len(x.keys) == 0 {
			b.WriteString("{}")
			return
		}
		b.WriteByte('{')
		for i, k := range x.keys {
			if i > 0 {
				b.WriteByte(',')
			}
			nlIndent(depth + 1)
			writeString(b, k)
			b.WriteByte(':')
			if pretty {
				b.WriteByte(' ')
			}
			writeJV(b, x.vals[k], pretty, depth+1)
		}
		nlIndent(depth)
		b.WriteByte('}')
	}
}

func writeString(b *strings.Builder, s string) {
	b.WriteByte('"')
	for _, r := range toValid(s) {
		switch {
		case r == '"':
			b.WriteString(`\"`)
		case r == '\\':
			b.WriteString(`\\`)
		case r == '\n':
			b.WriteString(`\n`)
		case r == '\t':
			b.WriteString(`\t`)
		case r == '\r':
			b.WriteString(`\r`)
		case r == '\b':
			b.WriteString(`\b`)
		case r == '\f':
			b.WriteString(`\f`)
		case r < 0x20 || r == 0x7f:
			b.WriteString(`\u00`)
			b.WriteByte("0123456789abcdef"[r>>4])
			b.WriteByte("0123456789abcdef"[r&15])
		default:
			b.WriteRune(r)
		}
	}
	b.WriteByte('"')
}

// toValid is how jq reads bytes that are not UTF-8: each offending byte becomes U+FFFD.
func toValid(s string) string {
	if utf8.ValidString(s) {
		return s
	}
	var b strings.Builder
	for i := 0; i < len(s); {
		r, n := utf8.DecodeRuneInString(s[i:])
		if r == utf8.RuneError && n == 1 {
			b.WriteRune(utf8.RuneError)
		} else {
			b.WriteString(s[i : i+n])
		}
		i += n
	}
	return b.String()
}
