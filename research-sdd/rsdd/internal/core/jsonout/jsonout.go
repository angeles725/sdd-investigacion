// Package jsonout is the single canonical-JSON encoder of the rsdd port.
//
// It reproduces, byte for byte, the Python json.dumps forms used across the toolbelt:
//
//   - Canonical: sort_keys, separators (",", ":"), ensure_ascii (research-sdd/toolbelt/lib/adapter_core.py).
//   - CanonicalUnicode: the same with ensure_ascii=False (analysis_manifest.py, zip_metadata.py).
//   - Indented: indent=2, sort_keys, ensure_ascii (the _write_json helpers).
//
// Every form ends with a single newline.
//
// Known divergence: Python can carry invalid UTF-8 inside a str as lone surrogates (surrogateescape), and
// json.dumps then emits \udcXX escapes. Go strings holding invalid UTF-8 are rejected here instead; a
// caller with such bytes must decide how to represent them before encoding.
//
// Go's encoding/json is deliberately not used for output: it escapes <, > and & and formats floats
// differently from Python.
package jsonout

import (
	"bytes"
	"encoding/json"
	"fmt"
	"math"
	"math/big"
	"reflect"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"unicode/utf8"
)

// Options selects an output form.
type Options struct {
	// Indent is the indent width; 0 selects the compact form with ":" and "," separators.
	Indent int
	// ASCII escapes every non-ASCII rune as \uXXXX (UTF-16 surrogate pairs above the BMP), like
	// ensure_ascii=True.
	ASCII bool
}

// Encode renders v with o. Supported values: nil, bool, string, every int and uint size, float32/float64,
// json.Number, []any, map[string]any, and any slice, array or string-keyed map of those (via reflection).
// Structs, non-string map keys, NaN, infinities and strings that are not valid UTF-8 are errors.
func Encode(v any, o Options) ([]byte, error) {
	e := encoder{o: o}
	if err := e.value(v, 0); err != nil {
		return nil, err
	}
	e.buf.WriteByte('\n')
	return e.buf.Bytes(), nil
}

// Canonical is the compact sorted ASCII form.
func Canonical(v any) ([]byte, error) { return Encode(v, Options{ASCII: true}) }

// CanonicalUnicode is the compact sorted form that keeps non-ASCII text as UTF-8.
func CanonicalUnicode(v any) ([]byte, error) { return Encode(v, Options{}) }

// Indented is the indent=2 sorted ASCII form of the _write_json helpers.
func Indented(v any) ([]byte, error) { return Encode(v, Options{Indent: 2, ASCII: true}) }

var errDepth = fmt.Errorf("jsonout: nesting depth exceeds %d (cyclic value?)", MaxDepth)

var errIndirection = fmt.Errorf("jsonout: pointer/interface indirection exceeds %d (cyclic value?)", MaxDepth)

type encoder struct {
	o   Options
	buf bytes.Buffer
	// indirections counts the pointer/interface hops on the current path. They add no nesting, so a
	// cycle made only of them would bypass the container depth bound and overflow the stack.
	indirections int
}

var numberSyntax = regexp.MustCompile(`^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$`)

func (e *encoder) newline(depth int) {
	e.buf.WriteByte('\n')
	e.buf.WriteString(strings.Repeat(" ", e.o.Indent*depth))
}

func (e *encoder) value(v any, depth int) error {
	switch x := v.(type) {
	case nil:
		e.buf.WriteString("null")
	case bool:
		e.buf.WriteString(strconv.FormatBool(x))
	case string:
		return e.str(x)
	case json.Number:
		return e.number(x)
	case float64:
		return e.float(x)
	case float32:
		return e.float(float64(x))
	case []any:
		return e.list(len(x), depth, func(i int) any { return x[i] })
	case map[string]any:
		return e.object(reflect.ValueOf(x), depth)
	default:
		return e.reflected(reflect.ValueOf(v), depth)
	}
	return nil
}

func (e *encoder) reflected(rv reflect.Value, depth int) error {
	switch rv.Kind() {
	case reflect.Int, reflect.Int8, reflect.Int16, reflect.Int32, reflect.Int64:
		e.buf.WriteString(strconv.FormatInt(rv.Int(), 10))
	case reflect.Uint, reflect.Uint8, reflect.Uint16, reflect.Uint32, reflect.Uint64, reflect.Uintptr:
		e.buf.WriteString(strconv.FormatUint(rv.Uint(), 10))
	case reflect.Slice, reflect.Array:
		if rv.Type().Elem().Kind() == reflect.Uint8 {
			return fmt.Errorf("jsonout: %s is bytes; json.dumps raises TypeError on bytes, so convert to a string or a list of ints first", rv.Type())
		}
		return e.list(rv.Len(), depth, func(i int) any { return rv.Index(i).Interface() })
	case reflect.Map:
		return e.object(rv, depth)
	case reflect.String:
		return e.str(rv.String())
	case reflect.Bool:
		e.buf.WriteString(strconv.FormatBool(rv.Bool()))
	case reflect.Float32, reflect.Float64:
		return e.float(rv.Float())
	case reflect.Interface, reflect.Pointer:
		if rv.IsNil() {
			e.buf.WriteString("null")
			return nil
		}
		if e.indirections >= MaxDepth {
			return errIndirection
		}
		e.indirections++
		defer func() { e.indirections-- }()
		return e.value(rv.Elem().Interface(), depth)
	default:
		return fmt.Errorf("jsonout: unsupported value of type %s", rv.Type())
	}
	return nil
}

func (e *encoder) list(n, depth int, at func(int) any) error {
	if depth >= MaxDepth {
		return errDepth
	}
	if n == 0 {
		e.buf.WriteString("[]")
		return nil
	}
	e.buf.WriteByte('[')
	for i := 0; i < n; i++ {
		if i > 0 {
			e.buf.WriteByte(',')
		}
		if e.o.Indent > 0 {
			e.newline(depth + 1)
		}
		if err := e.value(at(i), depth+1); err != nil {
			return err
		}
	}
	if e.o.Indent > 0 {
		e.newline(depth)
	}
	e.buf.WriteByte(']')
	return nil
}

func (e *encoder) object(rv reflect.Value, depth int) error {
	if depth >= MaxDepth {
		return errDepth
	}
	if rv.Type().Key().Kind() != reflect.String {
		return fmt.Errorf("jsonout: map key type %s is not a string", rv.Type().Key())
	}
	if rv.Len() == 0 {
		e.buf.WriteString("{}")
		return nil
	}
	keys := make([]string, 0, rv.Len())
	byKey := make(map[string]reflect.Value, rv.Len())
	it := rv.MapRange()
	for it.Next() {
		k := it.Key().String()
		keys = append(keys, k)
		byKey[k] = it.Value()
	}
	// Go compares strings by UTF-8 bytes, which orders exactly like Python's code point order.
	sort.Strings(keys)
	e.buf.WriteByte('{')
	for i, k := range keys {
		if i > 0 {
			e.buf.WriteByte(',')
		}
		if e.o.Indent > 0 {
			e.newline(depth + 1)
		}
		if err := e.str(k); err != nil {
			return err
		}
		e.buf.WriteByte(':')
		if e.o.Indent > 0 {
			e.buf.WriteByte(' ')
		}
		if err := e.value(byKey[k].Interface(), depth+1); err != nil {
			return err
		}
	}
	if e.o.Indent > 0 {
		e.newline(depth)
	}
	e.buf.WriteByte('}')
	return nil
}

const hexDigits = "0123456789abcdef"

func (e *encoder) u16(r rune) {
	e.buf.WriteString(`\u`)
	e.buf.WriteByte(hexDigits[r>>12&0xf])
	e.buf.WriteByte(hexDigits[r>>8&0xf])
	e.buf.WriteByte(hexDigits[r>>4&0xf])
	e.buf.WriteByte(hexDigits[r&0xf])
}

// str writes a JSON string exactly as Python's json encoder does. With ASCII, Python escapes everything
// outside space..~ (so DEL becomes \u007f); without it only the control characters, quote and backslash.
func (e *encoder) str(s string) error {
	if !utf8.ValidString(s) {
		return fmt.Errorf("jsonout: string %q is not valid UTF-8", s)
	}
	e.buf.WriteByte('"')
	for _, r := range s {
		switch {
		case r == '"':
			e.buf.WriteString(`\"`)
		case r == '\\':
			e.buf.WriteString(`\\`)
		case r == '\n':
			e.buf.WriteString(`\n`)
		case r == '\r':
			e.buf.WriteString(`\r`)
		case r == '\t':
			e.buf.WriteString(`\t`)
		case r == '\b':
			e.buf.WriteString(`\b`)
		case r == '\f':
			e.buf.WriteString(`\f`)
		case r < 0x20:
			e.u16(r)
		case !e.o.ASCII:
			e.buf.WriteRune(r)
		case r >= 0x20 && r <= 0x7e:
			e.buf.WriteByte(byte(r))
		case r >= 0x10000:
			r -= 0x10000
			e.u16(0xd800 + (r >> 10))
			e.u16(0xdc00 + (r & 0x3ff))
		default:
			e.u16(r)
		}
	}
	e.buf.WriteByte('"')
	return nil
}

func (e *encoder) number(n json.Number) error {
	s := string(n)
	if !numberSyntax.MatchString(s) {
		return fmt.Errorf("jsonout: %q is not a JSON number", s)
	}
	if !strings.ContainsAny(s, ".eE") {
		i, ok := new(big.Int).SetString(s, 10)
		if !ok {
			return fmt.Errorf("jsonout: %q is not an integer", s)
		}
		e.buf.WriteString(i.String())
		return nil
	}
	f, err := strconv.ParseFloat(s, 64)
	if err != nil {
		return fmt.Errorf("jsonout: number %q: %w", s, err)
	}
	return e.float(f)
}

func (e *encoder) float(f float64) error {
	if math.IsNaN(f) || math.IsInf(f, 0) {
		return fmt.Errorf("jsonout: %v has no valid JSON form (Python would emit NaN/Infinity)", f)
	}
	e.buf.WriteString(pyFloat(f))
	return nil
}

// pyFloat formats f like Python's repr(float): the shortest round-trip digits, positional notation for
// decimal exponents in [-4, 16), otherwise scientific with a signed exponent of at least two digits.
func pyFloat(f float64) string {
	sign := ""
	if math.Signbit(f) {
		sign = "-"
		f = -f
	}
	if f == 0 {
		return sign + "0.0"
	}
	sci := strconv.FormatFloat(f, 'e', -1, 64) // d.ddddde±XX
	mant, expStr, _ := strings.Cut(sci, "e")
	exp, _ := strconv.Atoi(expStr)
	digits := strings.Replace(mant, ".", "", 1)
	switch {
	case exp >= 16 || exp < -4:
		m := digits[:1]
		if len(digits) > 1 {
			m += "." + digits[1:]
		}
		es := "+"
		if exp < 0 {
			es, exp = "-", -exp
		}
		return fmt.Sprintf("%s%se%s%02d", sign, m, es, exp)
	case exp >= 0:
		if len(digits) <= exp+1 {
			return sign + digits + strings.Repeat("0", exp+1-len(digits)) + ".0"
		}
		return sign + digits[:exp+1] + "." + digits[exp+1:]
	default:
		return sign + "0." + strings.Repeat("0", -exp-1) + digits
	}
}

// MaxDepth is the deepest container nesting Encode accepts. Python's json.dumps stops at its recursion
// limit (about 1000 frames); this bound likewise turns a cyclic value into an error instead of a stack
// overflow.
const MaxDepth = 1000
