package verify

import (
	"bytes"
	"fmt"
	"io"
	"strings"
	"unicode/utf8"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// Port of research-sdd/toolbelt/verify-kit-clean-hook.sh, the SessionStart wrapper of verify kit-clean:
//
//	rsdd verify kit-clean-hook [<kit-repo>]
//
// Silent (no output) when the kit is clean. Otherwise it prints the SessionStart envelope whose
// additionalContext is a header and the full stdout+stderr of the check. Like the script it always exits 0:
// a hook never fails the session. The header differs for exit 1 (dirty or unpushed) and any other code (the
// check could not run).
//
// Difference, by design: the script printed plain text when jq was missing; the envelope is built here with
// no jq, so it is always the JSON contract of the harness.
//
// The envelope encoder duplicates internal/hook (a domain package cannot import another domain); both are
// pinned to jq's output by their own tests.

const (
	hdrNotClean = "Research-SDD KIT is NOT clean — commit/stash + push before staging §18 retros (else the retro branch/PR mixes unrelated history):"
	hdrCouldNot = "Research-SDD kit-clean check could not run (exit %d — misconfigured path or not a git repo):"
)

// RunKitCleanHook is the `verify kit-clean-hook` command.
func RunKitCleanHook(args []string, s cli.Stdio) int {
	var buf bytes.Buffer // one writer for both streams, so the order is the script's `2>&1`
	rc := kitClean(repoArg(args), s.Cwd, &buf, &buf, gitRunner(s))
	if rc == 0 {
		return cli.ExitOK
	}
	hdr := hdrNotClean
	if rc != 1 {
		hdr = fmt.Sprintf(hdrCouldNot, rc)
	}
	writeSessionStart(s.Out, hdr+"\n"+strings.TrimRight(buf.String(), "\n"))
	return cli.ExitOK
}

// writeSessionStart prints the envelope exactly as
// `jq -n --arg c "$ctx" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$c}}'` does:
// two-space indent, keys in insertion order (not sorted), a trailing newline.
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
