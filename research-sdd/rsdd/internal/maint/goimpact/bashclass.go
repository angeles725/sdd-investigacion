package goimpact

import (
	"path"
	"regexp"
	"strings"
)

// Mention classes (rule i'): every RSDD_BIN / RSDD_REAL_BIN mention in bash code is exactly one of these.
const (
	ClassA           = "A"           // assignment, export, declare, local, unset, env prefix: not a call
	ClassB           = "B"           // operand of [ ], [[ ]] or test: not a call
	ClassC           = "C"           // command position: a call
	ClassD           = "D"           // argument position after another command word: treated as a call
	ClassUnplaceable = "unplaceable" // inside eval, a `bash -c` string or an executed here-doc
	ClassEmptyReach  = "empty-reach" // file-level: mentions the binary, reaches no command by any route
)

// Mention is one classified mention. Resolved is true for a C or D mention whose literal group and name are a
// recovered command (it produced an edge). A, B and a resolved C or D never make a blind spot.
type Mention struct {
	Class    string
	Resolved bool
}

var binNameRe = regexp.MustCompile(`RSDD_(REAL_)?BIN\b`)

// declWords are the commands whose arguments declare or remove variables.
var declWords = map[string]bool{"export": true, "declare": true, "local": true, "unset": true, "readonly": true, "typeset": true}

// shellWords run a program text given with -c, or read one from stdin.
var shellWords = map[string]bool{"bash": true, "sh": true, "dash": true, "zsh": true}

// mentionForm labels a mention by the variable it names.
func mentionForm(word string) string {
	if strings.Contains(word, "RSDD_REAL_BIN") {
		return "$RSDD_REAL_BIN"
	}
	return "$RSDD_BIN"
}

// classify places the mention at words[j] of one simple command whose command word is words[w0] (-1 when the
// segment has none). inDouble is true while inside a [[ ... ]] that spans separators; execDoc is true inside a
// here-doc fed to a shell.
func classify(words []string, j, w0 int, inDouble, execDoc bool) string {
	cmd := ""
	if w0 >= 0 {
		cmd = path.Base(norm(words[w0]))
	}
	switch {
	case assignRe.MatchString(norm(words[j])):
		return ClassA
	case inDouble || cmd == "[" || cmd == "[[" || cmd == "test":
		return ClassB
	case declWords[cmd]:
		return ClassA
	case execDoc || cmd == "eval" || (shellWords[cmd] && dashC(words[w0+1:], j-w0-1)):
		return ClassUnplaceable
	case j == w0:
		return ClassC
	}
	return ClassD
}

// dashC reports whether a -c style flag precedes args[upto] (bash -c "...", bash -lc "...").
func dashC(args []string, upto int) bool {
	for i := 0; i < upto && i < len(args); i++ {
		if a := norm(args[i]); strings.HasPrefix(a, "-") && !strings.HasPrefix(a, "--") && strings.Contains(a, "c") {
			return true
		}
	}
	return false
}
