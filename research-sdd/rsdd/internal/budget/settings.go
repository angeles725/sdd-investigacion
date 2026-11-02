package budget

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"regexp"
	"strings"
)

// The SessionStart selection of verify-session-budget.sh, which the script did with one jq program. The rules are
// Claude Code's documented "Matcher patterns" (see the package doc in session.go).

// sources are the SessionStart sources, in the order the script walks them.
var sources = []string{"startup", "resume", "clear", "compact", "fork"}

// exactClass is the matcher alphabet that makes a value an exact string or a list of exact strings.
// altSplit is the jq split("[|,]"; null).
var altSplit = regexp.MustCompile(`[|,]`)

var exactClass = regexp.MustCompile(`^[A-Za-z0-9_ ,|-]+$`)

// parseSettings reads settings.json the way `jq -e 'type == "object"'` judged it. The script's jq accepted a
// stream of JSON values and judged the last one; here exactly one object is required (declared divergence).
func parseSettings(data []byte) (map[string]any, bool) {
	vals, ok := decodeStream(data)
	if !ok || len(vals) != 1 {
		return nil, false
	}
	m, isObj := vals[0].(map[string]any)
	return m, isObj
}

// decodeStream decodes every JSON value in data. ok is false on any syntax error; numbers keep their literal.
func decodeStream(data []byte) (vals []any, ok bool) {
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.UseNumber()
	for {
		var v any
		err := dec.Decode(&v)
		if err == io.EOF {
			return vals, true
		}
		if err != nil {
			return nil, false
		}
		vals = append(vals, v)
	}
}

// record is one selected hook: its command and its declared timeout text ("" when absent).
type record struct{ cmd, decl string }

// selectHooks returns the SessionStart command hooks whose matcher selects src, as the NUL-delimited record
// stream the script's jq printed (`<command> \x01 <timeout> \0`), already split the way its read loop split it.
// The error is the reason jq would have failed with; the caller prints its own text after the same prefix.
func selectHooks(doc map[string]any, src string) (stream string, err error) {
	var b strings.Builder
	// jq's `?` guards only the iteration: a hooks value that is neither null nor an object fails the program.
	hooks, isObj := doc["hooks"].(map[string]any)
	if v := doc["hooks"]; v != nil && !isObj {
		//lint:ignore ST1005 jq's own error text, kept byte-identical for parity with the frozen script
		return "", fmt.Errorf("Cannot index %s with string \"SessionStart\"", jqType(v))
	}
	list, _ := hooks["SessionStart"].([]any)
	for _, e := range list {
		var entry map[string]any
		switch t := e.(type) {
		case nil:
		case map[string]any:
			entry = t
		default:
			//lint:ignore ST1005 jq's own error text, kept byte-identical for parity with the frozen script
			return "", fmt.Errorf("Cannot index %s with string \"matcher\"", jqType(e))
		}
		matcher := ""
		if v := entry["matcher"]; truthy(v) {
			matcher = jqToString(v)
		}
		hit, err := matches(matcher, src)
		if err != nil {
			return "", err
		}
		if !hit {
			continue
		}
		inner, _ := entry["hooks"].([]any)
		for _, h := range inner {
			var hook map[string]any
			switch t := h.(type) {
			case nil:
			case map[string]any:
				hook = t
			default:
				//lint:ignore ST1005 jq's own error text, kept byte-identical for parity with the frozen script
				return "", fmt.Errorf("Cannot index %s with string \"type\"", jqType(h))
			}
			if typ, _ := hook["type"].(string); typ != "command" {
				continue
			}
			cmd, isStr := hook["command"].(string)
			if !isStr {
				continue
			}
			decl := ""
			if v := hook["timeout"]; truthy(v) {
				decl = jqToString(v)
			}
			b.WriteString(cmd + "\x01" + decl + "\x00")
		}
	}
	return b.String(), nil
}

// matches is the jq function mm($m; $s).
func matches(m, src string) (bool, error) {
	if m == "" || m == "*" {
		return true, nil
	}
	if exactClass.MatchString(m) {
		for _, alt := range altSplit.Split(m, -1) {
			if strings.Trim(alt, " \t\n\v\f\r") == src {
				return true, nil
			}
		}
		return false, nil
	}
	re, err := regexp.Compile(m)
	if err != nil {
		return false, fmt.Errorf("%s (at matcher): %s", m, err)
	}
	return re.MatchString(src), nil
}

// splitRecords is the script's `read -r -d ”` loop over a record stream: a record is cut at its first \x01.
func splitRecords(stream string) []record {
	parts := strings.Split(stream, "\x00")
	if len(parts) > 0 {
		parts = parts[:len(parts)-1] // the stream ends in NUL: what follows the last one is never a record
	}
	out := make([]record, 0, len(parts))
	for _, rec := range parts {
		cmd, decl, found := strings.Cut(rec, "\x01")
		if !found {
			decl = rec // ${rec#*$'\x01'} leaves the record whole when there is no \x01
		}
		out = append(out, record{cmd, decl})
	}
	return out
}

func truthy(v any) bool {
	if v == nil {
		return false
	}
	b, isBool := v.(bool)
	return !isBool || b
}

func jqType(v any) string {
	switch v.(type) {
	case nil:
		return "null"
	case bool:
		return "boolean"
	case json.Number:
		return "number"
	case string:
		return "string"
	case []any:
		return "array"
	}
	return "object"
}
