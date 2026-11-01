package gate

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"regexp"
	"strconv"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// Port of templates/hook-pretool-pkill-guard.sh (PreToolUse, matcher Bash; kit issues #1244, #2208): refuses a
// self-matching `pkill -f` / `pgrep -f` and, with --strict-name-kill, every name-based kill. Contract (unchanged):
// the hook JSON is read from stdin, the process ALWAYS exits 0, a refusal is the hookSpecificOutput JSON on
// stdout, an allow is empty stdout. Bytes of stdout, stderr and the exit code match the bash original; the frozen
// copy in testdata/legacy is the differential oracle.
//
// Intended divergences from the bash (each pinned by a test):
//   - no jq dependency: the "jq missing" degraded branch cannot happen, the JSON is parsed with encoding/json;
//   - a stdin read error is a typed degraded state that FAILS CLOSED (strict: deny, default: ask); bash cannot see it;
//   - locale: bash uses the caller's locale for [[:space:]]/[[:alnum:]] and the bracket regex; Go classes are ASCII
//     for the former and character based (UTF-8) for the latter, which is the UTF-8 locale behaviour.
//
// It remains a regex heuristic, not a shell parser; the known limits listed in the bash header still hold.

const (
	strictText = `Kill only processes you started yourself, by PID: record $! when you spawn the process (or read it back with jobs -p), kill that PID, and bound a runaway run with timeout. Never match processes by name or pattern: a name match can hit another session's processes.`
	alternates = `Safe alternatives: (a) record the PID at spawn ($! or a PID file) and kill that PID; (b) match by exact process name: pkill -x <name> / pgrep -x <name>; (c) bracket-escape the pattern so it cannot match its own text: pkill -f "[p]attern". See PROMPT-LOOP-APPENDIX.md#hard-rules-loop-mechanics "PKILL -F WRAPPER-SHELL MATCH".`
)

var (
	bracketRe = regexp.MustCompile(`\[[^\]]+\]`)
	plainRe   = regexp.MustCompile(`\[([^\]])[^\]]*\]`)
	// pgrep/pidof output piped into xargs/while ... kill, or substituted into kill: the per-segment scan cannot
	// see across separators, so both shapes are matched on the whole quote-stripped command.
	pipeRe = regexp.MustCompile(`(pgrep|pidof)[^&|;]*\|[[:space:]]*(xargs|while)[^&]*(^|[^[:alnum:]_-])kill([^[:alnum:]_-]|$)`)
	subRe  = regexp.MustCompile("(^|[^[:alnum:]_-])kill[^;|&]*(\\$\\(|`)[[:space:]]*(pgrep|pidof)")
)

// PkillGuard is `rsdd guard pkill [--strict-name-kill]`.
func PkillGuard(args []string, s cli.Stdio) int {
	strict := false
	for _, a := range args {
		if a == "--strict-name-kill" {
			strict = true
		}
	}
	raw, rerr := io.ReadAll(s.In)
	if rerr != nil {
		why := "stdin unreadable (" + rerr.Error() + ")"
		fmt.Fprintf(s.Err, "degraded: pkill-guard: %s — cannot inspect the command\n", why)
		if strict {
			emit(s.Out, "deny", "pkill-guard degraded ("+why+"): the command could not be read, so strict mode refuses it. Retry; if it persists, report it.")
		} else {
			emit(s.Out, "ask", "pkill-guard degraded ("+why+"): the command could not be read and checked for a self-matching -f pattern. Confirm the pattern is bracket-escaped or use -x / a PID file.")
		}
		return cli.ExitOK
	}
	input := bashSubst(raw)
	if input == "" {
		return cli.ExitOK
	}
	cmd, ok := extractCommand(input)
	if !ok {
		const why = "stdin is not parseable PreToolUse JSON"
		fmt.Fprintf(s.Err, "degraded: pkill-guard: %s — cannot inspect the command\n", why)
		if strings.Contains(input, "pkill") || strings.Contains(input, "pgrep") {
			emit(s.Out, "ask", "pkill-guard degraded ("+why+"): this payload mentions pkill/pgrep and could not be checked for a self-matching -f pattern. Confirm the pattern is bracket-escaped or use -x / a PID file.")
		}
		return cli.ExitOK
	}
	if cmd == "" {
		return cli.ExitOK
	}
	strictBad, bad := judge(cmd, strict)
	switch {
	case strictBad != "":
		emit(s.Out, "deny", "Refused name-based kill `"+strictBad+"`: this repo forbids killing processes by name or pattern (writer discipline, kit issue #2208). "+strictText)
	case bad != "":
		emit(s.Out, "deny", "Refused `"+bad+"`: an unescaped -f pattern also matches this shell's own wrapper command line and kills the session (exit 144). "+alternates)
	}
	return cli.ExitOK
}

// bashSubst is what `$(...)` does to a byte stream: NUL bytes are dropped, trailing newlines are stripped.
func bashSubst(b []byte) string {
	return strings.TrimRight(string(bytes.ReplaceAll(b, []byte{0}, nil)), "\n")
}

// extractCommand is `jq -er 'if (.tool_name // "") == "Bash" then (.tool_input.command // "") else "" end'` over a
// stream of JSON values, outputs joined by newlines. ok is false where jq fails (exit != 0): unparseable input,
// no output at all, indexing a non-object, or a last output that is false/null.
func extractCommand(input string) (string, bool) {
	if loneHighSurrogate(input) {
		return "", false // jq 1.7+: "Invalid \\uXXXX\\uXXXX surrogate pair escape" is a parse error (encoding/json would substitute U+FFFD)
	}
	dec := json.NewDecoder(strings.NewReader(strings.TrimPrefix(input, "\ufeff"))) // jq skips a leading UTF-8 BOM
	var outs []string
	for {
		var v json.RawMessage
		err := dec.Decode(&v)
		if err == io.EOF {
			break
		}
		if err != nil {
			return "", false
		}
		o, ok := evalOne(v)
		if !ok {
			return "", false
		}
		outs = append(outs, o)
	}
	if len(outs) == 0 {
		return "", false
	}
	return bashSubst([]byte(strings.Join(outs, "\n"))), true
}

// field is jq's `.key`: null yields null, an object its member (the last duplicate wins), anything else is an error.
func field(v json.RawMessage, key string) (json.RawMessage, bool) {
	t := bytes.TrimSpace(v)
	if string(t) == "null" {
		return json.RawMessage("null"), true
	}
	if len(t) == 0 || t[0] != '{' {
		return nil, false
	}
	var m map[string]json.RawMessage
	if err := json.Unmarshal(t, &m); err != nil {
		return nil, false
	}
	if x, found := m[key]; found {
		return x, true
	}
	return json.RawMessage("null"), true
}

func evalOne(v json.RawMessage) (string, bool) {
	name, ok := field(v, "tool_name")
	if !ok {
		return "", false
	}
	var tool string
	if err := json.Unmarshal(name, &tool); err != nil || tool != "Bash" { // non-string, null or false never equals "Bash"
		return "", true
	}
	in, ok := field(v, "tool_input")
	if !ok {
		return "", false
	}
	c, ok := field(in, "command")
	if !ok {
		return "", false
	}
	switch t := string(bytes.TrimSpace(c)); t {
	case "null", "false":
		return "", true
	case "true":
		return "true", true
	}
	var str string
	if json.Unmarshal(c, &str) == nil {
		return str, true
	}
	var pretty bytes.Buffer // number, object or array: jq -r prints its JSON text (objects and arrays indented)
	if err := json.Indent(&pretty, bytes.TrimSpace(c), "", "  "); err != nil {
		return "", false
	}
	return pretty.String(), true
}

// judge returns the strict-mode reason (strictBad) and the default-mode reason (bad); "" for none.
func judge(cmd string, strict bool) (strictBad, bad string) {
	nq := strings.NewReplacer("'", "", `"`, "").Replace(cmd)
	flat := strings.TrimRight(strings.NewReplacer(";", "\n", "&", "\n", "|", "\n", "(", "\n", ")", "\n", "{", "\n", "}", "\n", "`", "\n", "$", "\n").Replace(nq), "\n")
	nq = strings.TrimRight(nq, "\n")
	if strict {
		switch {
		case pipeRe.MatchString(nq):
			strictBad = "pgrep/pidof output piped into kill"
		case subRe.MatchString(nq):
			strictBad = "kill of a pgrep/pidof substitution"
		}
	}
	for _, seg := range strings.Split(flat, "\n") {
		tok := bashWords(seg)
		i := 0
		for i < len(tok) && skippable(tok[i]) {
			i++
		}
		if i >= len(tok) {
			continue
		}
		base := tok[i][strings.LastIndex(tok[i], "/")+1:]
		if strict && strictBad == "" {
			switch base {
			case "pkill", "killall":
				strictBad = strings.Join(tok[i:], " ")
			case "kill":
				for _, t := range tok[i+1:] {
					if t == "-1" {
						strictBad = strings.Join(tok[i:], " ")
						break
					}
				}
			}
		}
		if base != "pkill" && base != "pgrep" {
			continue
		}
		f, x, pat := false, false, ""
		for _, t := range tok[i+1:] {
			switch {
			case t == "--full":
				f = true
			case t == "--exact":
				x = true
			case strings.HasPrefix(t, "--"):
			case strings.HasPrefix(t, "-"):
				f = f || strings.Contains(t, "f")
				x = x || strings.Contains(t, "x")
			default:
				pat += " " + t
			}
		}
		if !f || x {
			continue
		}
		rest := strings.TrimPrefix(pat, " ")
		if !bracketRe.MatchString(pat) {
			bad = base + " -f"
			if pat != "" {
				bad += " " + rest
			}
			break
		}
		plain := strings.TrimRight(plainRe.ReplaceAllString(rest, "$1"), "\n")
		if strings.Contains(flat, plain) {
			bad = base + " -f " + rest + " (its plain text \"" + plain + "\" also appears elsewhere in this command)"
			break
		}
	}
	return strictBad, bad
}

// bashWords is `read -ra` under the default IFS: words split on space and tab only.
func bashWords(s string) []string {
	return strings.FieldsFunc(s, func(r rune) bool { return r == ' ' || r == '\t' || r == '\n' })
}

// skippable is the wrapper/flag/assignment/number prefix the bash skips before the command word.
func skippable(t string) bool {
	switch t {
	case "sudo", "exec", "env", "nohup", "xargs", "time", "timeout", "bash", "sh", "zsh", "dash", "then", "do", "else", "!", "if", "elif", "while", "until", "command", "nice":
		return true
	}
	return strings.HasPrefix(t, "-") || strings.Contains(t, "=") || (t != "" && t[0] >= '0' && t[0] <= '9')
}

func emit(w io.Writer, decision, reason string) {
	fmt.Fprintf(w, `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":%s,"permissionDecisionReason":%s}}`+"\n", jqString(decision), jqString(reason))
}

// jqString encodes s the way jq does, which is NOT encoding/json: no HTML escaping, lowercase \u00xx for control
// characters and DEL, U+2028/U+2029 raw, invalid UTF-8 as U+FFFD. TODO(#2386): core/jsonout will own this.
func jqString(s string) string {
	var b strings.Builder
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
			fmt.Fprintf(&b, `\u%04x`, r)
		default: // includes utf8.RuneError, written as U+FFFD, which is what jq prints for invalid bytes
			b.WriteRune(r)
		}
	}
	b.WriteByte('"')
	return b.String()
}

// loneHighSurrogate reports a JSON string escape \uD800-\uDBFF that is not followed by a \uDC00-\uDFFF escape; a
// lone low surrogate is accepted by jq (as U+FFFD), and an escaped backslash before "ud800" is not an escape.
func loneHighSurrogate(s string) bool {
	hex := func(i int) (int, bool) {
		if i+6 > len(s) || s[i] != '\\' || s[i+1] != 'u' {
			return 0, false
		}
		v, err := strconv.ParseUint(s[i+2:i+6], 16, 32)
		return int(v), err == nil
	}
	inStr := false
	for i := 0; i < len(s); i++ {
		switch {
		case s[i] == '"':
			inStr = !inStr
		case inStr && s[i] == '\\':
			if v, ok := hex(i); ok && v >= 0xd800 && v <= 0xdbff {
				if lo, ok := hex(i + 6); !ok || lo < 0xdc00 || lo > 0xdfff {
					return true
				}
				i += 11
				continue
			}
			i++ // skip the escaped character
		}
	}
	return false
}
