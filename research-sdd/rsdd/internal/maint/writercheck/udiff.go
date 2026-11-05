package writercheck

import (
	"strconv"
	"strings"
)

// addedLine is one line a change adds: the file (its new path), its number in the new file and its text.
type addedLine struct {
	file string
	line int
	text string
}

// parseAdded reads a `git diff -U0 --no-color` document and returns its added lines in order. A hunk is read by its
// header counts (`@@ -a,b +c,d @@`: b removed lines, d added lines), so an added line whose own text looks like a
// file header (`++ b/x`) is still an added line. A path with a space (git ends the header with a tab) or a quoted
// path (a tab, a quote, a backslash or a control character in the name) is read whole.
func parseAdded(diff string) []addedLine {
	var out []addedLine
	file, ln, removed, added := "", 0, 0, 0
	for _, l := range strings.Split(diff, "\n") {
		if removed > 0 || added > 0 {
			switch {
			case strings.HasPrefix(l, "-"):
				removed--
			case strings.HasPrefix(l, "+"):
				out = append(out, addedLine{file: file, line: ln, text: l[1:]})
				ln++
				added--
			}
			continue
		}
		switch {
		case strings.HasPrefix(l, "diff --git "):
			file = ""
		case strings.HasPrefix(l, "+++ "):
			file = headerPath(l[4:])
		case strings.HasPrefix(l, "@@ "):
			ln, removed, added = hunkCounts(l)
		}
	}
	return out
}

// headerPath is the new path of a `+++ ` header (or /dev/null for a deletion).
func headerPath(s string) string {
	s = strings.TrimRight(s, "\t")
	if strings.HasPrefix(s, `"`) {
		if u, err := strconv.Unquote(s); err == nil {
			s = u
		}
	}
	return strings.TrimPrefix(s, "b/")
}

// hunkCounts reads `@@ -a[,b] +c[,d] @@`: the first new line number c, the removed count b and the added count d
// (a missing count is 1). A header it cannot read counts nothing.
func hunkCounts(h string) (first, removed, added int) {
	f := strings.Fields(h)
	if len(f) < 3 || !strings.HasPrefix(f[1], "-") || !strings.HasPrefix(f[2], "+") {
		return 0, 0, 0
	}
	num := func(s string, def int) int {
		if v, err := strconv.Atoi(s); err == nil {
			return v
		}
		return def
	}
	_, rem, hasRem := strings.Cut(f[1][1:], ",")
	start, add, hasAdd := strings.Cut(f[2][1:], ",")
	removed, added = 1, 1
	if hasRem {
		removed = num(rem, 0)
	}
	if hasAdd {
		added = num(add, 0)
	}
	return num(start, 0), removed, added
}
