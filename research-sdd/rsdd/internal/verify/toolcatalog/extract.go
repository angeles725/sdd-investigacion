package toolcatalog

import (
	"regexp"
	"strings"
)

// Tool names come out of INSTALLED-TOOLS.md in two forms, both of which are logged tools:
//
//	form 1, the auto-log table install-tool.sh appends:   | <tool> | How | Status | ... |
//	form 2, the older hand-written narrative sections:     ## <tool> (<desc>) — <date>
//
// Form 1 names come first, then form 2; a name seen again is dropped, the first one seen kept.

// headingRE is a level-2 heading whose first token is followed by a parenthesised description.
var headingRE = regexp.MustCompile(`^## +[^ ]+ *\(`)

// toolNames is the distinct tool names of text, in order of first sight.
func (l locale) toolNames(text string) []string {
	lines := strings.Split(text, "\n")
	var names []string
	for _, line := range lines {
		if strings.HasPrefix(line, "|") && !l.isSeparatorRow(line) && !l.isHeaderRow(line) {
			if name := l.trim(cell2(line)); name != "" {
				names = append(names, name)
			}
		}
	}
	for _, line := range lines {
		if headingRE.MatchString(line) {
			names = append(names, awkField2(line))
		}
	}
	seen := make(map[string]bool, len(names))
	distinct := names[:0]
	for _, n := range names {
		if !seen[n] {
			seen[n] = true
			distinct = append(distinct, n)
		}
	}
	return distinct
}

// cell2 is awk -F'|' '{print $2}': the text between the first pipe and the next one (or the end of the line).
func cell2(line string) string {
	rest := line[1:]
	if i := strings.IndexByte(rest, '|'); i >= 0 {
		return rest[:i]
	}
	return rest
}

// awkField2 is awk '{print $2}': the second field when fields are separated by blanks and tabs.
func awkField2(line string) string {
	return strings.FieldsFunc(line, func(r rune) bool { return r == ' ' || r == '\t' })[1]
}

// isSeparatorRow is `^\|[[:space:]]*[-:]+[[:space:]]*\|`: the dashes row under a table header.
func (l locale) isSeparatorRow(line string) bool {
	rest := l.skipSpace(line[1:])
	n := 0
	for n < len(rest) && (rest[n] == '-' || rest[n] == ':') {
		n++
	}
	return n > 0 && strings.HasPrefix(l.skipSpace(rest[n:]), "|")
}

// isHeaderRow is `^\|[[:space:]]*Tool[[:space:]]*\|`, case-insensitively: a table header whose first cell is Tool.
func (l locale) isHeaderRow(line string) bool {
	rest := l.skipSpace(line[1:])
	if !strings.EqualFold(rest[:min(len(rest), len("tool"))], "tool") {
		return false
	}
	return strings.HasPrefix(l.skipSpace(rest[len("tool"):]), "|")
}

// skipSpace is s without its leading `[[:space:]]`.
func (l locale) skipSpace(s string) string {
	for i := 0; i < len(s); {
		r, n := l.next(s, i)
		if !l.isSpace(r) {
			return s[i:]
		}
		i += n
	}
	return ""
}
