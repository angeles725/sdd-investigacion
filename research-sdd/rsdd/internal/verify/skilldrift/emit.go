package skilldrift

import (
	"fmt"
	"io"
	"strings"
	"unicode/utf8"
)

// writeSessionStart prints the SessionStart envelope exactly as
// `jq -n --arg c "$ctx" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$c}}'` does (lib/hook-emit.sh):
// two-space indent, keys in insertion order (not sorted), a trailing newline.
//
// Difference, by design: lib/hook-emit.sh printed plain text when jq was missing; the envelope is built here with no jq, so it
// is always the JSON contract of the harness.
func writeSessionStart(w io.Writer, ctx string) {
	fmt.Fprintf(w, "{\n  \"hookSpecificOutput\": {\n    \"hookEventName\": \"SessionStart\",\n    \"additionalContext\": %s\n  }\n}\n", jqString(ctx))
}

// jqString is jq's string encoding: the short escapes for " \ \b \f \n \r \t, \u00xx (lowercase hex) for the other control
// characters and DEL, every other character as is (no <>& escaping, no U+2028), and U+FFFD for each byte that is not valid UTF-8.
// TODO(#2386): delete this private copy (the same one lives in internal/verify) once core/jsonout has the jq-compatible encoder.
func jqString(s string) string {
	var b strings.Builder
	b.WriteByte('"')
	for i := 0; i < len(s); {
		r, n := utf8.DecodeRuneInString(s[i:]) // an invalid byte decodes as U+FFFD, width 1: exactly jq's replacement
		i += n
		switch {
		case r == '"':
			b.WriteString(`\"`)
		case r == '\\':
			b.WriteString(`\\`)
		case r == '\b':
			b.WriteString(`\b`)
		case r == '\f':
			b.WriteString(`\f`)
		case r == '\n':
			b.WriteString(`\n`)
		case r == '\r':
			b.WriteString(`\r`)
		case r == '\t':
			b.WriteString(`\t`)
		case r < 0x20 || r == 0x7f:
			fmt.Fprintf(&b, `\u%04x`, r)
		default:
			b.WriteRune(r)
		}
	}
	b.WriteByte('"')
	return b.String()
}
