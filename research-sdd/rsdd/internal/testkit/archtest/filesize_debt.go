package archtest

import (
	"fmt"
	"strconv"
	"strings"
	"unicode/utf8"
)

// minReason is the shortest reason an entry may carry.
const minReason = 10

// reasonPlaceholder is what the not-listed message prints where the reason goes. A line pasted with it is refused
// by name, so the refusal does not depend on the placeholder being shorter than minReason.
const reasonPlaceholder = "<reason>"

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
// lines; problem is non-empty when an entry line is malformed, and e then
// carries only the path the line names.
func parseLine(line string) (e debtEntry, isEntry bool, problem string) {
	t := strings.TrimSpace(line)
	if t == "" || strings.HasPrefix(t, "#") {
		return e, false, ""
	}
	f := strings.Fields(t)
	e.Path = f[0]
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
	if reason == reasonPlaceholder {
		return e, true, "replace " + reasonPlaceholder + " with the reason this file is accepted"
	}
	if utf8.RuneCountInString(reason) < minReason {
		return e, true, fmt.Sprintf("reason is shorter than %d characters", minReason)
	}
	return debtEntry{Path: f[0], Lines: n, Kind: f[2], Reason: reason, Raw: line}, true, ""
}

// placeProblem reports why path may not follow prev, the path of the entry line before it, and whether the entry
// is still read. Entries are in strictly increasing byte order. A path already listed is a duplicate and is
// dropped, wherever its second line stands; any other path out of order is reported and kept, so one misplaced
// line costs one message and no listed file is taken for an unlisted one.
func placeProblem(prev, path string, seen map[string]bool) (problem string, keep bool) {
	// Duplicates first: a misplaced line lowers prev, so a second listing can sort after it.
	if seen[path] {
		return "duplicate path " + path, false
	}
	// prev was read, so a path equal to it is a duplicate and never reaches this comparison. It is written
	// with Compare and not with ">": no test could tell ">" from ">=" here, so the mutation run would report a
	// mutant nobody can kill, while this form keeps two it can.
	if strings.Compare(prev, path) == -1 {
		return "", true
	}
	return fmt.Sprintf("%s is not after %s (unsorted)", path, prev), true
}

// parseDebt returns the entries it read, a message for every bad line, and the paths that malformed lines name.
func parseDebt(text string) (entries []debtEntry, bad []string, named map[string]bool) {
	named = map[string]bool{}
	prev, seen := "", map[string]bool{}
	for i, line := range strings.Split(text, "\n") {
		e, isEntry, problem := parseLine(line)
		if !isEntry {
			continue
		}
		keep := false
		if problem != "" {
			named[e.Path] = true
		} else {
			problem, keep = placeProblem(prev, e.Path, seen)
		}
		if problem != "" {
			bad = append(bad, fmt.Sprintf(msgMalformed, DebtFileName, i+1, problem, minReason))
		}
		if !keep {
			continue
		}
		e.LineNo = i + 1
		entries = append(entries, e)
		prev, seen[e.Path] = e.Path, true
	}
	return entries, bad, named
}
