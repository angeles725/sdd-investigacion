package goimpact

import (
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
	assignRe = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*\+?=`)
)

// prefixWords may stand before the command word of a simple command (`env` is a command, not a prefix).
var prefixWords = map[string]bool{"if": true, "then": true, "else": true, "elif": true, "do": true, "while": true,
	"until": true, "!": true, "exec": true, "command": true, "time": true, "builtin": true}

// segment is one simple command: its words, and the separator that ended it.
type segment struct {
	words []string
	next  string
}

func segments(toks []tok) []segment {
	var out []segment
	var cur segment
	for _, t := range toks {
		if !t.sep {
			cur.words = append(cur.words, t.text)
			continue
		}
		cur.next = t.text
		out = append(out, cur)
		cur = segment{}
	}
	return append(out, cur)
}

func norm(s string) string { return strings.NewReplacer(`"`, "", `'`, "").Replace(s) }

// commandIndex is the index of the command word (after keywords and assignments), or -1.
func commandIndex(words []string) int {
	for i, w := range words {
		if n := norm(w); !prefixWords[n] && !assignRe.MatchString(n) {
			return i
		}
	}
	return -1
}

// literalForm labels the non-variable ways to run the binary and the words to skip before <group> <name>
// (rsdd_exec_hook takes a <kind> first). The literal path form excludes assignments (`RSDD_BIN=$ROOT/rsdd`).
func literalForm(w string) (form string, skip int) {
	switch {
	case w == "rsdd_exec":
		return "rsdd_exec", 0
	case w == "rsdd_exec_hook":
		return "rsdd_exec_hook", 1
	case !strings.Contains(w, "=") && (w == "rsdd" || strings.HasSuffix(w, "/bin/rsdd")):
		return "rsdd", 0
	}
	return "", 0
}

// scanText returns the resolved calls and every classified RSDD_BIN mention of one bash file; a literal
// rsdd_exec / rsdd / rsdd_exec_hook call counts as a class C mention.
func scanText(text string, known func(Command) bool) ([]Call, []Mention) {
	seen := map[Command]bool{}
	var calls []Call
	var ms []Mention
	record := func(class, form string, args []string) {
		c, ok := resolve(args, known)
		ms = append(ms, Mention{Class: class, Resolved: ok})
		if ok && !seen[c] {
			seen[c] = true
			calls = append(calls, Call{Cmd: c, Form: form})
		}
	}
	for _, sl := range sourceLines(text) {
		inDouble := false
		for _, seg := range segments(lex(sl.Text)) {
			w0 := commandIndex(seg.words)
			if w0 >= 0 && norm(seg.words[w0]) == "[[" {
				inDouble = true
			}
			for j, w := range seg.words {
				if binNameRe.MatchString(w) {
					class := classify(seg.words, j, w0, inDouble, sl.Exec)
					if class == ClassC || class == ClassD {
						record(class, mentionForm(w), normAll(seg.words[j+1:]))
					} else {
						ms = append(ms, Mention{Class: class})
					}
				} else if form, skip := literalForm(norm(w)); form != "" && j == w0 {
					args := normAll(seg.words[j+1:])
					if len(args) == 0 && seg.next == "(" {
						continue // `rsdd_exec() {`: a function definition, not a call
					}
					if len(args) < skip {
						ms = append(ms, Mention{Class: ClassC})
						continue
					}
					record(ClassC, form, args[skip:])
				}
			}
			for _, w := range seg.words {
				if norm(w) == "]]" {
					inDouble = false
				}
			}
		}
	}
	return calls, ms
}

func normAll(ws []string) []string {
	out := make([]string, len(ws))
	for i, w := range ws {
		out[i] = norm(w)
	}
	return out
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
