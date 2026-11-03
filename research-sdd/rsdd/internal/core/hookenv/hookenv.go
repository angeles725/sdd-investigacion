// Package hookenv is what every SessionStart hook shares: the jq-compatible envelope encoder and the panic guard
// that keeps a hook's "could not run" envelope alive when the code inside it panics (kit issues #2610, #2386).
package hookenv

import (
	"bytes"
	"fmt"
	"io"
	"strings"
	"unicode/utf8"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// WriteSessionStart prints the envelope exactly as
// `jq -n --arg c "$ctx" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$c}}'` does:
// two-space indent, keys in insertion order (not sorted), a trailing newline.
func WriteSessionStart(w io.Writer, ctx string) {
	fmt.Fprintf(w, "{\n  \"hookSpecificOutput\": {\n    \"hookEventName\": \"SessionStart\",\n    \"additionalContext\": %s\n  }\n}\n", JQString(ctx))
}

// JQString is jq's string encoding: the short escapes for " \ \b \f \n \r \t, \u00xx (lowercase hex) for the
// other control characters and DEL, every other character as is (no <>& escaping, no U+2028), and U+FFFD for
// each byte that is not valid UTF-8. core/jsonout and core/envelope reject invalid UTF-8 instead, so neither can
// stand in for it.
func JQString(s string) string {
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

// Guard runs run and returns its exit code. A panic inside it is recovered once, written to buf as
// "rsdd: internal-error: <value>" and reported as cli.ExitOperational, so the hook still emits its could-not-run
// envelope. Left to cli.Run's own recover, a panic would reach only stderr and the SessionStart hook would say
// nothing at all (CLAUDE.md §7, kit issue #2610). buf must be the buffer the hook builds its context from.
func Guard(buf *bytes.Buffer, run func() int) (rc int) {
	defer func() {
		if p := recover(); p != nil {
			fmt.Fprintf(buf, "rsdd: internal-error: %v\n", p)
			rc = cli.ExitOperational
		}
	}()
	return run()
}
