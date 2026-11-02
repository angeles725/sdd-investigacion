package budget

import (
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
	"unicode/utf8"
)

// Character counting measures what the consumer receives: Unicode code points of the DECODED text, never bytes
// and never the raw JSON stream (CLAUDE.md section 7).

// wcm is `wc -m` under a UTF-8 locale: bytes that are not part of a valid sequence are not counted (a lone 0xFF
// is 0 characters), a NUL byte is one.
func wcm(b []byte) int {
	n := 0
	for len(b) > 0 {
		r, w := utf8.DecodeRune(b)
		if !(r == utf8.RuneError && w == 1) {
			n++
		}
		b = b[w:]
	}
	return n
}

// hookChars counts one hook's stdout: the two fields Claude Code caps when stdout is a JSON object
// (hookSpecificOutput.additionalContext and systemMessage), plain characters otherwise. A stdout that is not
// exactly one JSON object (empty, malformed, several values, an array) is plain text.
func hookChars(out []byte) (first, second int) {
	vals, ok := decodeStream(out)
	if ok && len(vals) == 1 {
		if obj, isObj := vals[0].(map[string]any); isObj {
			if hso, isObj := obj["hookSpecificOutput"].(map[string]any); isObj {
				first = fieldLen(hso["additionalContext"])
			}
			return first, fieldLen(obj["systemMessage"])
		}
	}
	return wcm(out), 0
}

// fieldLen is jq's `(. // "") | tostring | length`.
func fieldLen(v any) int {
	if !truthy(v) {
		return 0
	}
	return utf8.RuneCountInString(jqToString(v))
}

// jqToString is jq's tostring: a string as is, anything else as compact JSON. Numbers keep their literal.
// Differences, by design: a number written with an exponent or a trailing fraction jq canonicalises (1E2 prints
// 1E+2) keeps its source spelling here, and a lone-surrogate escape (a JSON text jq rejects outright) is
// replaced by U+FFFD instead of turning the whole stdout into plain text.
func jqToString(v any) string {
	if s, ok := v.(string); ok {
		return s
	}
	var b strings.Builder
	writeJSON(&b, v)
	return b.String()
}

func writeJSON(b *strings.Builder, v any) {
	switch t := v.(type) {
	case nil:
		b.WriteString("null")
	case bool:
		b.WriteString(strconv.FormatBool(t))
	case json.Number:
		b.WriteString(t.String())
	case string:
		writeJSONString(b, t)
	case []any:
		b.WriteByte('[')
		for i, e := range t {
			if i > 0 {
				b.WriteByte(',')
			}
			writeJSON(b, e)
		}
		b.WriteByte(']')
	case map[string]any:
		b.WriteByte('{')
		first := true
		for k, e := range t {
			if !first {
				b.WriteByte(',')
			}
			first = false
			writeJSONString(b, k)
			b.WriteByte(':')
			writeJSON(b, e)
		}
		b.WriteByte('}')
	}
}

// writeJSONString escapes the way jq does: quote, backslash and C0 controls (and DEL), nothing else.
func writeJSONString(b *strings.Builder, s string) {
	b.WriteByte('"')
	for _, r := range s {
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
			fmt.Fprintf(b, `\u%04x`, r)
		default:
			b.WriteRune(r)
		}
	}
	b.WriteByte('"')
}
