package hook

import (
	"fmt"
	"io"
	"strings"
	"unicode/utf8"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// Port of the jq branch of research-sdd/toolbelt/lib/hook-emit.sh (rsdd_hook_emit):
//
//	rsdd hook emit [HDR] BODY
//
// Prints {"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":C}} where C is
// "HDR\nBODY" (two or more arguments: only the first two count, like the function) or BODY alone (one
// argument), byte for byte as `jq -n --arg c "$ctx" ...` prints it. Always exits 0: a hook never fails its
// session. Arguments are positional text, never flags. With no argument C is empty.
//
// Differences, by design: the function printed plain text when jq was missing; here no jq is involved, so the
// output is always the JSON contract. The sourced bash function itself stays bash (it is also the degraded
// path of lib/rsdd-exec.sh, which must work when rsdd cannot run).

// Emit is the `hook emit` command.
func Emit(args []string, s cli.Stdio) int {
	ctx := ""
	switch {
	case len(args) >= 2:
		ctx = args[0] + "\n" + args[1]
	case len(args) == 1:
		ctx = args[0]
	}
	writeSessionStart(s.Out, ctx)
	return cli.ExitOK
}

func writeSessionStart(w io.Writer, ctx string) {
	fmt.Fprintf(w, "{\n  \"hookSpecificOutput\": {\n    \"hookEventName\": \"SessionStart\",\n    \"additionalContext\": %s\n  }\n}\n", jqString(ctx))
}

// jqString is jq's string encoding: the short escapes for " \ \b \f \n \r \t, \u00xx (lowercase hex) for the
// other control characters and DEL, every other character as is (no <>& escaping, no U+2028), and U+FFFD for
// each byte that is not valid UTF-8.
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
