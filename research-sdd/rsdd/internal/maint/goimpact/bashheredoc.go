package goimpact

import (
	"cmp"
	"path"
	"regexp"
	"slices"
	"strings"
)

// srcLine is one logical line of a bash file. Exec is set on the body lines of a here-doc that a shell runs.
type srcLine struct {
	Text string
	Exec bool
}

var hereRe = regexp.MustCompile(`<<(-?)[ \t]*(?:"([^"]+)"|'([^']+)'|\\?([A-Za-z_][A-Za-z0-9_]*))`)

// execWords run their here-doc as a program.
var execWords = map[string]bool{"bash": true, "sh": true, "dash": true, "zsh": true, "source": true, ".": true, "eval": true}

// sourceLines returns the logical lines of text. A here-doc body is returned line by line like any other code
// (a generated script is scanned as the code it will become), flagged Exec when a shell runs it; the
// delimiter line is dropped.
func sourceLines(text string) []srcLine {
	lines := logicalLines(text)
	var out []srcLine
	for i := 0; i < len(lines); i++ {
		l := lines[i]
		out = append(out, srcLine{Text: l})
		loc := hereRe.FindStringIndex(l)
		if loc == nil || strings.HasSuffix(l[:loc[0]], "<") { // no here-doc, or a here-string (<<<)
			continue
		}
		g := hereRe.FindStringSubmatch(l)
		body, consumed := heredocBody(lines[i+1:], cmp.Or(g[2], g[3], g[4]))
		exec := hasExecWord(l)
		for _, b := range body {
			out = append(out, srcLine{Text: b, Exec: exec})
		}
		i += consumed
	}
	return out
}

// heredocBody splits the lines after a here-doc start into its body and the count of lines it consumed (the
// body plus the delimiter line). A delimiter that never comes takes every remaining line.
func heredocBody(rest []string, delim string) (body []string, consumed int) {
	k := slices.IndexFunc(rest, func(s string) bool { return strings.TrimSpace(s) == delim })
	if k == -1 {
		return rest, len(rest)
	}
	return rest[:k], k + 1
}

func hasExecWord(line string) bool {
	for _, t := range lex(line) {
		if !t.sep && execWords[path.Base(norm(t.text))] {
			return true
		}
	}
	return false
}
