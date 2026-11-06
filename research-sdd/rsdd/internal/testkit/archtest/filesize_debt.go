package archtest

import (
	"fmt"
	"strconv"
	"strings"
	"unicode/utf8"
)

const minReason = 10

// debtEntry is one parsed line of the debt file.
type debtEntry struct {
	Path   string
	Lines  int
	Kind   string // "legacy" or "accepted"
	Reason string
	LineNo int
	Raw    string
}

// parseLine parses one debt-file line. isEntry is false for blank and comment
// lines; problem is non-empty when an entry line is malformed.
func parseLine(line string) (e debtEntry, isEntry bool, problem string) {
	t := strings.TrimSpace(line)
	if t == "" || strings.HasPrefix(t, "#") {
		return e, false, ""
	}
	path, rest := cutField(t)
	lines, rest := cutField(rest)
	kind, rest := cutField(rest)
	reason := strings.TrimSpace(rest)
	if path == "" || lines == "" || kind == "" || reason == "" {
		return e, true, "malformed line, fewer than four fields"
	}
	n, err := strconv.Atoi(lines)
	if err != nil || n <= 0 {
		return e, true, fmt.Sprintf("%q is not a positive line count", lines)
	}
	if kind != "legacy" && kind != "accepted" {
		return e, true, fmt.Sprintf("unknown kind %q", kind)
	}
	if utf8.RuneCountInString(reason) < minReason {
		return e, true, fmt.Sprintf("reason is shorter than %d characters", minReason)
	}
	return debtEntry{Path: path, Lines: n, Kind: kind, Reason: reason, Raw: line}, true, ""
}

// cutField splits off the first whitespace-separated field.
func cutField(s string) (field, rest string) {
	s = strings.TrimLeft(s, " \t")
	i := strings.IndexAny(s, " \t")
	if i < 0 {
		return s, ""
	}
	return s[:i], strings.TrimLeft(s[i:], " \t")
}

// parseDebt returns the well-formed entries and a message for every bad line.
// Entries must be in strictly increasing byte order of path.
func parseDebt(text string) ([]debtEntry, []string) {
	var entries []debtEntry
	var bad []string
	prev := ""
	for i, line := range strings.Split(text, "\n") {
		e, isEntry, problem := parseLine(line)
		if !isEntry {
			continue
		}
		if problem == "" && len(entries) > 0 {
			switch {
			case e.Path == prev:
				problem = "duplicate path " + e.Path
			case e.Path < prev:
				problem = fmt.Sprintf("%s is not after %s (unsorted)", e.Path, prev)
			}
		}
		if problem != "" {
			bad = append(bad, fmt.Sprintf(msgMalformed, DebtFileName, i+1, problem, minReason))
			continue
		}
		e.LineNo = i + 1
		entries = append(entries, e)
		prev = e.Path
	}
	return entries, bad
}
