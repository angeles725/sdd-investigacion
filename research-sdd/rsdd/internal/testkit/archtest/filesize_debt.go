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
	Reason string // runs of white space collapsed to one space
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
	f := strings.Fields(t)
	if len(f) < 4 {
		return e, true, "malformed line, fewer than four fields"
	}
	n, err := strconv.Atoi(f[1])
	if err != nil || n <= 0 {
		return e, true, fmt.Sprintf("%q is not a positive line count", f[1])
	}
	if f[2] != "legacy" && f[2] != "accepted" {
		return e, true, fmt.Sprintf("unknown kind %q", f[2])
	}
	reason := strings.Join(f[3:], " ")
	if utf8.RuneCountInString(reason) < minReason {
		return e, true, fmt.Sprintf("reason is shorter than %d characters", minReason)
	}
	return debtEntry{Path: f[0], Lines: n, Kind: f[2], Reason: reason, Raw: line}, true, ""
}

// orderProblem reports why path may not follow prev. Entries are in strictly
// increasing byte order, so an equal path is a duplicate.
func orderProblem(prev, path string) string {
	if path > prev {
		return ""
	}
	if path == prev {
		return "duplicate path " + path
	}
	return fmt.Sprintf("%s is not after %s (unsorted)", path, prev)
}

// parseDebt returns the well-formed entries and a message for every bad line.
func parseDebt(text string) ([]debtEntry, []string) {
	var entries []debtEntry
	var bad []string
	prev := ""
	for i, line := range strings.Split(text, "\n") {
		e, isEntry, problem := parseLine(line)
		if !isEntry {
			continue
		}
		if problem == "" {
			problem = orderProblem(prev, e.Path)
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
