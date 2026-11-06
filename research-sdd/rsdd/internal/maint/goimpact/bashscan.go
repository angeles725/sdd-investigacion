package goimpact

import (
	"fmt"
	"regexp"
	"strings"
)

// Call is one resolved invocation of an rsdd command from bash, with the form it used.
type Call struct {
	Cmd  Command
	Form string
}

var (
	wordRe   = regexp.MustCompile(`^[a-z][a-z0-9-]*$`)
	assignRe = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*=`)
)

// prefixWords may stand between a command separator and the command itself.
var prefixWords = map[string]bool{"if": true, "then": true, "else": true, "elif": true, "do": true, "while": true,
	"until": true, "!": true, "exec": true, "command": true, "time": true, "builtin": true, "env": true}

// execForms maps a normalised command word to its form label and the number of words to skip before the
// <group> <name> pair (rsdd_exec_hook takes a <kind> first).
func execForm(w string) (form string, skip int) {
	switch w {
	case "rsdd_exec":
		return "rsdd_exec", 0
	case "rsdd_exec_hook":
		return "rsdd_exec_hook", 1
	case "$RSDD_BIN", "${RSDD_BIN}":
		return "$RSDD_BIN", 0
	case "$RSDD_REAL_BIN", "${RSDD_REAL_BIN}":
		return "$RSDD_REAL_BIN", 0
	}
	// a literal name, or the installed binary path; a word with '=' is an assignment (`RSDD_BIN=$ROOT/rsdd`)
	if !strings.Contains(w, "=") && (w == "rsdd" || strings.HasSuffix(w, "/bin/rsdd")) {
		return "rsdd", 0
	}
	return "", 0
}

func norm(s string) string { return strings.NewReplacer(`"`, "", `'`, "").Replace(s) }

// commandPos reports whether toks[i] stands where a shell runs a command: first on the line, after a
// separator, or after prefix words (keywords, VAR=value assignments) that follow one.
func commandPos(toks []tok, i int) bool {
	for j := i - 1; j >= 0; j-- {
		if toks[j].sep {
			return toks[j].text != ")" && toks[j].text != "}"
		}
		w := norm(toks[j].text)
		if !prefixWords[w] && !assignRe.MatchString(w) {
			return false
		}
	}
	return true
}

// scanText returns the resolved calls and the unresolvable ones (as a reason each) found in one bash file.
func scanText(text string, known func(Command) bool) (calls []Call, unclass []string) {
	seen := map[Command]bool{}
	for _, line := range logicalLines(text) {
		toks := lex(line)
		for i, t := range toks {
			if t.sep {
				continue
			}
			form, skip := execForm(norm(t.text))
			if form == "" || !commandPos(toks, i) {
				continue
			}
			var args []string
			for j := i + 1; j < len(toks) && !toks[j].sep; j++ {
				args = append(args, norm(toks[j].text))
			}
			if len(args) == 0 && i+1 < len(toks) && toks[i+1].text == "(" {
				continue // `rsdd_exec() {`: a function definition, not a call
			}
			if len(args) < skip {
				unclass = append(unclass, fmt.Sprintf("%s: no command words", form))
				continue
			}
			c, ok := resolve(args[skip:], known)
			if !ok {
				unclass = append(unclass, fmt.Sprintf("%s %s", form, strings.Join(args, " ")))
				continue
			}
			if !seen[c] {
				seen[c] = true
				calls = append(calls, Call{Cmd: c, Form: form})
			}
		}
	}
	if why := blindSpotReason(text, len(calls)); why != "" {
		unclass = append(unclass, why)
	}
	return calls, unclass
}

// resolve reads `<group> <name>` (or a lone ungrouped `<name>`) from the words after the executable.
func resolve(args []string, known func(Command) bool) (Command, bool) {
	if len(args) >= 2 && wordRe.MatchString(args[0]) && wordRe.MatchString(args[1]) && known(Command{args[0], args[1]}) {
		return Command{args[0], args[1]}, true
	}
	if len(args) >= 1 && wordRe.MatchString(args[0]) && known(Command{Name: args[0]}) {
		return Command{Name: args[0]}, true
	}
	return Command{}, false
}
