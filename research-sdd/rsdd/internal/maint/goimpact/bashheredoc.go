package goimpact

import (
	"path"
	"regexp"
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
		m := hereRe.FindStringSubmatchIndex(l)
		if m == nil || (m[0] > 0 && l[m[0]-1] == '<') {
			continue
		}
		delim := ""
		for g := 4; g <= 8 && delim == ""; g += 2 {
			if m[g] >= 0 {
				delim = l[m[g]:m[g+1]]
			}
		}
		exec := hasExecWord(l)
		for i+1 < len(lines) {
			i++
			if strings.TrimSpace(lines[i]) == delim {
				break
			}
			out = append(out, srcLine{Text: lines[i], Exec: exec})
		}
	}
	return out
}

func hasExecWord(line string) bool {
	for _, t := range lex(line) {
		if !t.sep && execWords[path.Base(norm(t.text))] {
			return true
		}
	}
	return false
}
