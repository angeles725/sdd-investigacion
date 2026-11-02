package gate

import (
	"bytes"
	"encoding/json"
	"math"
	"sort"
	"strconv"
	"strings"
)

// The merge gate's bash reads every JSON answer with jq. These helpers reproduce the few jq behaviours the
// gate depends on, over json.RawMessage values (they keep number literals exactly as written, as jq 1.7+ does):
//
//   - a stream of values is evaluated value by value; a value whose filter raises an error contributes nothing
//     and the evaluation goes on with the next one (jq prints the outputs it had and continues);
//   - `-r` prints a string raw and any other value as JSON (containers indented by two spaces);
//   - `//` treats null and false as absent;
//   - jq's total order (null < false < true < numbers < strings < arrays < objects) drives group_by and sort.
//
// One divergence is accepted: a number is printed as its literal text, so a literal jq would canonicalise
// (1E2, 100000000000000000000.0) prints as written. The gate only prints ids and counts GitHub sends as plain
// integers.

// jqType is jq's `type` of a raw JSON value.
func jqType(v json.RawMessage) string {
	t := bytes.TrimSpace(v)
	if len(t) == 0 {
		return "null"
	}
	switch t[0] {
	case '{':
		return "object"
	case '[':
		return "array"
	case '"':
		return "string"
	case 't', 'f':
		return "boolean"
	case 'n':
		return "null"
	}
	return "number"
}

// jqIndex is `.key`: null for a null input or an absent key, ok=false (a jq error) for anything but an object.
func jqIndex(v json.RawMessage, key string) (out json.RawMessage, ok bool) {
	switch jqType(v) {
	case "null":
		return json.RawMessage("null"), true
	case "object":
		var obj map[string]json.RawMessage
		if json.Unmarshal(v, &obj) != nil {
			return nil, false
		}
		if f, present := obj[key]; present {
			return f, true
		}
		return json.RawMessage("null"), true
	}
	return nil, false
}

// jqPath is `.a.b.c`; the first jq error ends it.
func jqPath(v json.RawMessage, keys ...string) (json.RawMessage, bool) {
	for _, k := range keys {
		var ok bool
		if v, ok = jqIndex(v, k); !ok {
			return nil, false
		}
	}
	return v, true
}

// jqAbsent reports whether v is what `//` replaces: null or false.
func jqAbsent(v json.RawMessage) bool {
	t := strings.TrimSpace(string(v))
	return t == "null" || t == "false"
}

// jqString decodes a JSON string value.
func jqString(v json.RawMessage) (string, bool) {
	if jqType(v) != "string" {
		return "", false
	}
	var s string
	if json.Unmarshal(v, &s) != nil {
		return "", false
	}
	return s, true
}

// jqNumber is the float64 of a number value.
func jqNumber(v json.RawMessage) (float64, bool) {
	if jqType(v) != "number" {
		return 0, false
	}
	f, err := strconv.ParseFloat(strings.TrimSpace(string(v)), 64)
	return f, err == nil
}

// jqRaw is how `jq -r` prints v: a string raw, a container indented, anything else as its literal.
func jqRaw(v json.RawMessage) string {
	if s, ok := jqString(v); ok {
		return s
	}
	t := bytes.TrimSpace(v)
	if jqType(v) == "array" || jqType(v) == "object" {
		var b bytes.Buffer
		if json.Indent(&b, t, "", "  ") == nil {
			return b.String()
		}
	}
	return string(t)
}

// jqToString is jq's `tostring`: a string as is, anything else as compact JSON.
func jqToString(v json.RawMessage) string {
	if s, ok := jqString(v); ok {
		return s
	}
	var b bytes.Buffer
	if json.Compact(&b, v) == nil {
		return b.String()
	}
	return strings.TrimSpace(string(v))
}

// jqEach runs f over every value of a stream and returns what a `$(jq -r ...)` captures: one line per output,
// NULs dropped, trailing newlines removed. f returns emit=false for a value on which the filter errors or
// prints nothing.
func jqEach(vals []json.RawMessage, f func(v json.RawMessage) (line string, emit bool)) string {
	var out strings.Builder
	for _, v := range vals {
		if line, emit := f(v); emit {
			out.WriteString(line + "\n")
		}
	}
	return cmdSub(out.String())
}

// jqOptKey is `jq -r '.key // empty'` as a jqEach filter.
func jqOptKey(key string) func(json.RawMessage) (string, bool) {
	return func(v json.RawMessage) (string, bool) {
		f, ok := jqIndex(v, key)
		if !ok || jqAbsent(f) {
			return "", false
		}
		return jqRaw(f), true
	}
}

// jqStream decodes what jq reads from stdin: NULs are gone (the shell dropped them) and a leading UTF-8 byte
// order mark is skipped, as jq does. ok is false on a parse error; the values before it are still returned.
func jqStream(data string) (vals []json.RawMessage, ok bool) {
	return decodeStream([]byte(strings.TrimPrefix(stripNUL(data), "\xef\xbb\xbf")))
}

// jqSlurp is `jq -s` over a stream: ok is false when the stream does not parse (no output at all).
func jqSlurp(data string) (vals []json.RawMessage, ok bool) { return jqStream(data) }

// jqCmp is jq's total order over two values.
func jqCmp(a, b json.RawMessage) int {
	ta, tb := jqOrderRank(a), jqOrderRank(b)
	if ta != tb {
		if ta < tb {
			return -1
		}
		return 1
	}
	switch jqType(a) {
	case "number":
		fa, _ := jqNumber(a)
		fb, _ := jqNumber(b)
		return cmpFloat(fa, fb)
	case "string":
		sa, _ := jqString(a)
		sb, _ := jqString(b)
		return strings.Compare(sa, sb)
	case "array":
		var xa, xb []json.RawMessage
		_ = json.Unmarshal(a, &xa)
		_ = json.Unmarshal(b, &xb)
		for i := 0; i < len(xa) && i < len(xb); i++ {
			if c := jqCmp(xa[i], xb[i]); c != 0 {
				return c
			}
		}
		return cmpInt(len(xa), len(xb))
	case "object":
		var oa, ob map[string]json.RawMessage
		_ = json.Unmarshal(a, &oa)
		_ = json.Unmarshal(b, &ob)
		ka, kb := sortedKeys(oa), sortedKeys(ob)
		for i := 0; i < len(ka) && i < len(kb); i++ {
			if c := strings.Compare(ka[i], kb[i]); c != 0 {
				return c
			}
		}
		if c := cmpInt(len(ka), len(kb)); c != 0 {
			return c
		}
		for _, k := range ka {
			if c := jqCmp(oa[k], ob[k]); c != 0 {
				return c
			}
		}
	}
	return 0
}

// jqOrderRank is the position of v's kind in jq's order; false sorts before true.
func jqOrderRank(v json.RawMessage) int {
	switch jqType(v) {
	case "null":
		return 0
	case "boolean":
		if strings.TrimSpace(string(v)) == "false" {
			return 1
		}
		return 2
	case "number":
		return 3
	case "string":
		return 4
	case "array":
		return 5
	}
	return 6
}

func sortedKeys(m map[string]json.RawMessage) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

func cmpFloat(a, b float64) int {
	switch {
	case a < b:
		return -1
	case a > b:
		return 1
	case math.IsNaN(a) != math.IsNaN(b):
		if math.IsNaN(a) {
			return -1
		}
		return 1
	}
	return 0
}

func cmpInt(a, b int) int {
	switch {
	case a < b:
		return -1
	case a > b:
		return 1
	}
	return 0
}
