package gate

import (
	"bytes"
	"encoding/json"
	"io"
	"strconv"
	"strings"
	"unicode/utf8"
)

// Port of the input side of toolbelt/return-token-gate.sh: the hook JSON (jq -r field reads), the final report
// of a transcript (the jq filter) and the continuation-token grammar (the `while read` loop).
//
// jq parity notes, measured against jq 1.8.2 and pinned by the parity cases:
//   - a hook JSON stream is every value jq would accept; an empty stream, a parse error anywhere in it, or a last
//     value of null/false makes `jq -e .` fail (typed degraded "hook JSON unreadable");
//   - a field read on a non-object value is a jq error, which the bash turns into "" (stop_hook_active: "false");
//   - NaN/Infinity literals, which jq accepts, are rejected by encoding/json; objects and arrays read as a field
//     render compact (jq -r would pretty-print them); neither shape occurs in a Stop-hook payload.

// cSpace is [[:space:]] of the C locale.
const cSpace = " \t\n\v\f\r"

// stripNUL is what bash command substitution does to a NUL byte.
func stripNUL(s string) string { return strings.ReplaceAll(s, "\x00", "") }

// cmdSub is the text a `$(...)` captures: NULs dropped, every trailing newline removed.
func cmdSub(s string) string { return strings.TrimRight(stripNUL(s), "\n") }

// decodeStream decodes every JSON value of data, as jq does. ok is false on any parse error.
func decodeStream(data []byte) (vals []json.RawMessage, ok bool) {
	dec := json.NewDecoder(bytes.NewReader(data))
	for {
		var v json.RawMessage
		err := dec.Decode(&v)
		if err == io.EOF {
			return vals, true
		}
		if err != nil {
			return vals, false
		}
		vals = append(vals, v)
	}
}

// decodeOne decodes data as exactly one JSON value (jq's fromjson).
func decodeOne(data []byte) (json.RawMessage, bool) {
	vals, ok := decodeStream(data)
	if !ok || len(vals) != 1 {
		return nil, false
	}
	return vals[0], true
}

// hookReadable is `jq -e .`: a non-empty, fully parsable stream whose last value is neither null nor false.
func hookReadable(vals []json.RawMessage, ok bool) bool {
	if !ok || len(vals) == 0 {
		return false
	}
	last := strings.TrimSpace(string(vals[len(vals)-1]))
	return last != "null" && last != "false"
}

// rawText renders one JSON value the way `jq -r` prints it: a string raw, anything else as its JSON text.
func rawText(v json.RawMessage) string {
	t := strings.TrimSpace(string(v))
	if strings.HasPrefix(t, `"`) {
		var s string
		if json.Unmarshal(v, &s) == nil {
			return s
		}
	}
	var b bytes.Buffer
	if json.Compact(&b, v) == nil {
		return b.String()
	}
	return t
}

// hookField is `jq -r '.<key> // empty'` over a stream (or `// false` when dflt is non-empty). A value that is
// not an object, other than null, is a jq error: the caller's `|| var=...` fallback then applies, so the result is
// dflt for the stop flag and "" otherwise.
func hookField(vals []json.RawMessage, key, dflt string) string {
	var out strings.Builder
	for _, v := range vals {
		t := strings.TrimSpace(string(v))
		if t == "null" {
			if dflt != "" {
				out.WriteString(dflt + "\n")
			}
			continue
		}
		var obj map[string]json.RawMessage
		if !strings.HasPrefix(t, "{") || json.Unmarshal(v, &obj) != nil {
			return dflt
		}
		f, present := obj[key]
		ft := strings.TrimSpace(string(f))
		if !present || ft == "null" || ft == "false" {
			if dflt != "" {
				out.WriteString(dflt + "\n")
			}
			continue
		}
		out.WriteString(rawText(f) + "\n")
	}
	return cmdSub(out.String())
}

// lastReport is the jq filter of the gate: the text blocks of the LAST main-thread assistant message that has any
// text. Lines that are not one JSON value are skipped. ok is false when the filter itself errors (a message that
// is not an object, or a text block that is a container), which the bash turns into an empty report.
func lastReport(data []byte) (report string, ok bool) {
	last := ""
	for _, line := range strings.Split(string(data), "\n") {
		raw, parsed := decodeOne([]byte(line))
		if !parsed {
			continue
		}
		var obj map[string]json.RawMessage
		if json.Unmarshal(raw, &obj) != nil {
			continue
		}
		if string(bytes.TrimSpace(obj["type"])) != `"assistant"` || string(bytes.TrimSpace(obj["isSidechain"])) == "true" {
			continue
		}
		text, good := messageText(obj["message"])
		if !good {
			return "", false
		}
		if text != "" {
			last = text
		}
	}
	return last, true
}

// messageText is `.message.content | if string then . elif array then <text blocks joined> else "" end`.
func messageText(msg json.RawMessage) (string, bool) {
	t := strings.TrimSpace(string(msg))
	if t == "" || t == "null" {
		return "", true
	}
	var m map[string]json.RawMessage
	if !strings.HasPrefix(t, "{") || json.Unmarshal(msg, &m) != nil {
		return "", false // `.content` on a string, number, boolean or array is a jq error
	}
	c := bytes.TrimSpace(m["content"])
	switch {
	case bytes.HasPrefix(c, []byte(`"`)):
		var s string
		_ = json.Unmarshal(c, &s)
		return s, true
	case bytes.HasPrefix(c, []byte("[")):
		var blocks []json.RawMessage
		if json.Unmarshal(c, &blocks) != nil {
			return "", true
		}
		var parts []string
		for _, b := range blocks {
			var o map[string]json.RawMessage
			if !strings.HasPrefix(strings.TrimSpace(string(b)), "{") || json.Unmarshal(b, &o) != nil {
				continue
			}
			if string(bytes.TrimSpace(o["type"])) != `"text"` {
				continue
			}
			p, good := joinPart(o["text"])
			if !good {
				return "", false
			}
			parts = append(parts, p)
		}
		return strings.Join(parts, "\n"), true
	}
	return "", true
}

// joinPart is `.text // ""` followed by jq's join: null/false/absent become "", a string is itself, a number or
// true its text, and an object or array is a jq error.
func joinPart(v json.RawMessage) (string, bool) {
	t := strings.TrimSpace(string(v))
	switch {
	case t == "" || t == "null" || t == "false":
		return "", true
	case strings.HasPrefix(t, `"`):
		var s string
		_ = json.Unmarshal(v, &s)
		return s, true
	case strings.HasPrefix(t, "{") || strings.HasPrefix(t, "["):
		return "", false
	}
	return t, true
}

// tailWindow is the bounded read of the transcript. data is the whole file, or only its last n bytes when size
// exceeds n; in that case the first (partial) line is dropped, as `tail -c n | sed 1d`. truncated reports it.
func tailWindow(data []byte, n, size int64) (window []byte, truncated bool) {
	if size <= n {
		return data, false
	}
	if i := bytes.IndexByte(data, '\n'); i >= 0 {
		return data[i+1:], true
	}
	return nil, true
}

// tailBytes is RETURN_TOKEN_GATE_TAIL_BYTES: empty, non-numeric or 0 means the 2 MiB default. A value too large
// for int64 can never be exceeded by a file, so it is the maximum.
func tailBytes(v string) int64 {
	const dflt = 2097152
	if v == "" || v == "0" || strings.Trim(v, "0123456789") != "" {
		return dflt
	}
	n, err := strconv.ParseInt(v, 10, 64)
	if err != nil {
		return 1<<63 - 1
	}
	return n
}

// reportTokens walks the report line by line (grammar in the script header): the last token line wins, and a
// `return-token-override:` line with a non-empty reason sets the override.
func reportTokens(report string) (reported, override string) {
	for _, line := range strings.Split(report, "\n") {
		l := strings.TrimLeft(line, cSpace)
		if rest, ok := strings.CutPrefix(l, "return-token-override:"); ok {
			if why := strings.TrimLeft(rest, cSpace); why != "" {
				override = why
			}
			continue
		}
		if strings.HasPrefix(l, "- ") || strings.HasPrefix(l, "* ") || strings.HasPrefix(l, "> ") {
			l = l[2:]
		}
		l = strings.TrimPrefix(l, "`")
		l = strings.TrimPrefix(l, "return-token: ")
		if isTokenLine(l) {
			reported = strings.TrimRight(l, cSpace+"`")
		}
	}
	return reported, override
}

// isTokenLine is the RTG-TOKEN-PATTERN case: `next: X`, `next-entry: X` (X starts with a non-space) or `STOP: campaign...`.
func isTokenLine(l string) bool {
	for _, p := range []string{"next: ", "next-entry: "} {
		if rest, ok := strings.CutPrefix(l, p); ok && rest != "" && !strings.ContainsRune(cSpace, rune(rest[0])) {
			return true
		}
	}
	return strings.HasPrefix(l, "STOP: campaign")
}

// lastEmitted is the last `return-token: ` line of the status output.
func lastEmitted(out string) string {
	emitted := ""
	for _, line := range strings.Split(out, "\n") {
		if strings.HasPrefix(line, "return-token: ") {
			emitted = line
		}
	}
	return emitted
}

// sidSafe is `${id//[^A-Za-z0-9._-]/_}`: one underscore per character, which is per rune in a UTF-8 locale and
// per byte otherwise.
func sidSafe(id string, utf8Locale bool) string {
	var b strings.Builder
	if !utf8Locale {
		for i := 0; i < len(id); i++ {
			c := id[i]
			if safeByte(c) {
				b.WriteByte(c)
			} else {
				b.WriteByte('_')
			}
		}
		return b.String()
	}
	for len(id) > 0 {
		r, size := utf8.DecodeRuneInString(id)
		if r < utf8.RuneSelf && safeByte(byte(r)) {
			b.WriteByte(byte(r))
		} else {
			b.WriteByte('_')
		}
		id = id[size:]
	}
	return b.String()
}

func safeByte(c byte) bool {
	return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '.' || c == '_' || c == '-'
}

// blockJSON is `jq -nc --arg r "$reason" '{decision:"block",reason:$r}'`: jq escapes the controls, the quote, the
// backslash and DEL, keeps every other rune raw, and turns an invalid byte into U+FFFD.
func blockJSON(reason string) string {
	var b strings.Builder
	b.WriteString(`{"decision":"block","reason":"`)
	for _, r := range reason {
		switch {
		case r == '"':
			b.WriteString(`\"`)
		case r == '\\':
			b.WriteString(`\\`)
		case r == '\n':
			b.WriteString(`\n`)
		case r == '\r':
			b.WriteString(`\r`)
		case r == '\t':
			b.WriteString(`\t`)
		case r == '\b':
			b.WriteString(`\b`)
		case r == '\f':
			b.WriteString(`\f`)
		case r < 0x20 || r == 0x7f:
			b.WriteString(`\u00`)
			b.WriteByte("0123456789abcdef"[r>>4])
			b.WriteByte("0123456789abcdef"[r&0xf])
		default:
			b.WriteRune(r)
		}
	}
	b.WriteString("\"}\n")
	return b.String()
}
