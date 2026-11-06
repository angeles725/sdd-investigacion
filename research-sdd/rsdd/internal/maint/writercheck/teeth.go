package writercheck

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/textlog"
)

// A teeth log is a `--prove-teeth` run: the binding header, a teeth banner line (`-- teeth ...` / `== teeth ...`,
// the marker run-all.sh counts), the last summary line `== N passed · 0 failed ==` with N>0 and no `  FAIL  ` line.
var (
	reHeader  = regexp.MustCompile(`^# writer-check: head=[0-9a-f]+ tree=[0-9a-f]{40}$`)
	reSummary = regexp.MustCompile(`^== ([0-9]+) passed · ([0-9]+) failed ==[[:space:]]*$`)
	reBanner  = regexp.MustCompile(`(?i)^[[:space:]]*(--|==)[[:space:]]*teeth\b`)
	reFail    = regexp.MustCompile(`^  FAIL  `)
)

// Verdict kinds of a log that is not valid evidence.
const (
	missing = "missing-teeth"
	stale   = "stale-teeth"
)

// logName is the file name of a suite's log: the repo-relative suite path with / -> __, so the same basename in two
// corpora cannot collide.
func logName(suite string) string { return strings.ReplaceAll(suite, "/", "__") + ".log" }

// checkLog judges the log of one suite against the binding header of the checked range. It returns the finding kind
// and reason, or "" when the log is valid evidence.
func checkLog(dir, suite, bindHeader string) (kind, reason string) {
	if dir == "" {
		return missing, "no --teeth-log given"
	}
	p := filepath.Join(dir, logName(suite))
	// `[ -f ]` and `[ -s ]` follow symlinks, as os.Stat does.
	fi, err := os.Stat(p)
	if err != nil || !fi.Mode().IsRegular() {
		return missing, "no log " + filepath.Base(p)
	}
	if fi.Size() == 0 {
		return missing, "log is empty"
	}
	// An unreadable log gives head(1) no first line, so the bash reports no header.
	b, err := os.ReadFile(p)
	lines := strings.Split(string(b), "\n")
	if err != nil || !reHeader.MatchString(lines[0]) {
		return stale, "no writer-check header (a log not produced by --write-teeth-log is not evidence)"
	}
	if treeOf(lines[0]) != treeOf(bindHeader) {
		return stale, "changed files differ from when the log was written (re-run --write-teeth-log)"
	}
	// grep finds no summary line in a log it reads as binary.
	if textlog.Binary(b) {
		return missing, "no summary line"
	}
	return judgeBody(lines)
}

// treeOf is the text after the last " tree=" of a header line.
func treeOf(h string) string {
	parts := strings.Split(h, " tree=")
	return parts[len(parts)-1]
}

// judgeBody applies the content rules, in order: a summary line, no failures in it, some passed cases, no FAIL line,
// a teeth banner. The counts are compared as text, as the bash did (`00` is not `0`).
func judgeBody(lines []string) (kind, reason string) {
	summary, passed, failed := "", "", ""
	for _, l := range lines {
		if m := reSummary.FindStringSubmatch(l); m != nil {
			summary, passed, failed = l, m[1], m[2]
		}
	}
	switch {
	case summary == "":
		return missing, "no summary line"
	case failed != "0":
		return missing, fmt.Sprintf("summary reports failures: %s", summary)
	case passed == "0":
		return missing, "summary reports zero passed cases"
	}
	if anyMatch(lines, reFail) {
		return missing, "log contains a FAIL line"
	}
	if !anyMatch(lines, reBanner) {
		return missing, "plain run: no teeth banner (not a --prove-teeth run)"
	}
	return "", ""
}

func anyMatch(lines []string, re *regexp.Regexp) bool {
	for _, l := range lines {
		if re.MatchString(l) {
			return true
		}
	}
	return false
}
