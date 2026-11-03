package show

import "strings"

// Helpers for the C-locale awk and bash idioms the status script uses. Everything here is byte-wise on purpose:
// the script runs its readers under LC_ALL=C, so tolower, [[:space:]] and bracket expressions see bytes.

// lowerASCII is awk's tolower under LC_ALL=C: only A-Z change.
func lowerASCII(s string) string {
	b := []byte(s)
	for i, c := range b {
		if isUpper(c) {
			b[i] = c + 'a' - 'A'
		}
	}
	return string(b)
}

// The one place that spells out the C-locale byte classes: [0-9], [A-Z], [a-z] and their union.
func isDigit(b byte) bool { return b >= '0' && b <= '9' }
func isUpper(b byte) bool { return b >= 'A' && b <= 'Z' }
func isLower(b byte) bool { return b >= 'a' && b <= 'z' }
func isAlnum(b byte) bool { return isUpper(b) || isLower(b) || isDigit(b) }

// isWordByte is the bracket [A-Za-z0-9_-] of the child-gap negation window.
func isWordByte(b byte) bool { return isAlnum(b) || b == '_' || b == '-' }

// awkFields is awk's default field splitting: runs of space, tab and newline separate fields, leading and
// trailing runs are ignored.
func awkFields(s string) []string {
	return strings.FieldsFunc(s, func(r rune) bool { return r == ' ' || r == '\t' || r == '\n' })
}

// isAllDashes is `s ~ /^-+$/`.
func isAllDashes(s string) bool { return s != "" && strings.Trim(s, "-") == "" }

// isPriorityHeader is `s ~ /^(priority|pr\.?|p|prioridad)$/`.
func isPriorityHeader(s string) bool {
	switch s {
	case "priority", "pr", "pr.", "p", "prioridad":
		return true
	}
	return false
}

// isGapBacklogHeading is `$0 ~ /^## Gap-backlog( \([^)]+\))?$/`: the bare heading, or one qualifier in
// parentheses holding at least one character and no `)`.
func isGapBacklogHeading(line string) bool {
	rest, ok := strings.CutPrefix(line, "## Gap-backlog")
	if !ok {
		return false
	}
	if rest == "" {
		return true
	}
	inner, ok := strings.CutPrefix(rest, " (")
	if !ok || !strings.HasSuffix(inner, ")") {
		return false
	}
	inner = inner[:len(inner)-1]
	return inner != "" && !strings.Contains(inner, ")")
}

// trimBlanks is gsub(/^[ \t]+|[ \t]+$/, "", s).
func trimBlanks(s string) string { return strings.Trim(s, " \t") }

// isRowStart is `$0 ~ /^[ \t]*\|/`.
func isRowStart(line string) bool { return strings.HasPrefix(strings.TrimLeft(line, " \t"), "|") }

// stripQualifier is `sub(/ *\([^)]*\)$/, "", s)`: a trailing parenthesised group without `)` inside, and the
// blanks before it, removed. The leftmost match wins, which is the first `(` after the last `)` that precedes
// the final one.
func stripQualifier(s string) string {
	if !strings.HasSuffix(s, ")") {
		return s
	}
	body := s[:len(s)-1]
	from := strings.LastIndexByte(body, ')') + 1
	open := strings.IndexByte(body[from:], '(')
	if open < 0 {
		return s
	}
	return strings.TrimRight(s[:from+open], " ")
}

// tabRead is `IFS=$'\t' read -r a b rest`: tab is IFS whitespace, so leading and trailing tabs are dropped and
// a run of tabs is one separator (an empty cell collapses away). rest keeps any further tabs.
func tabRead(line string) (a, b, rest string) {
	s := strings.Trim(line, "\t")
	a, s, _ = strings.Cut(s, "\t")
	b, s, _ = strings.Cut(strings.TrimLeft(s, "\t"), "\t")
	return a, b, strings.TrimLeft(s, "\t")
}

// readRows is the loop `while IFS=$'\t' read -r p gap st; do ...; done < <(cmd)` over a command's output: a final
// line without a newline is not seen by the loop body.
func readRows(stream string, each func(pri, gap, st string)) {
	for _, line := range strings.SplitAfter(stream, "\n") {
		line, complete := strings.CutSuffix(line, "\n")
		if !complete {
			continue
		}
		p, g, s := tabRead(line)
		each(p, g, s)
	}
}
