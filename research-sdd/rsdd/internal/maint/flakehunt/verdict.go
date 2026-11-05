package flakehunt

import (
	"regexp"
	"strconv"
	"strings"
)

// Outcomes of one suite run, as results.tsv spells them.
const (
	stPass    = "PASS"
	stFail    = "FAIL"
	stSkip    = "SKIP"
	stTimeout = "TIMEOUT"
)

// exitTimeout is what `timeout` returns when it had to stop its command.
const exitTimeout = 124

var (
	summaryRe   = regexp.MustCompile(`^== ([0-9]+) passed · ([0-9]+) failed ==$`)
	malformedRe = regexp.MustCompile(`(?i)passed.*failed|failed.*passed`)
)

// onlyZeros is true for a run of '0' digits ("000"); with digits only it means "the number is zero" at any length.
func onlyZeros(digits string) bool { return strings.Trim(digits, "0") == "" }

// passProblem says why an exit-0 log is not a PASS under run-all.sh's rules (a `== N passed · M failed ==` line with
// M = 0 and N > 0), or "" when it is one. The last well-formed summary line counts. The counts are judged as digits,
// so no length overflows.
func passProblem(log, path string) string {
	last := ""
	for _, l := range strings.Split(log, "\n") {
		if summaryRe.MatchString(l) {
			last = l
		}
	}
	if last == "" {
		for _, l := range strings.Split(log, "\n") {
			if malformedRe.MatchString(l) {
				return "exit 0 but malformed summary line (want '== N passed · M failed ==') in " + path
			}
		}
		return "exit 0 but no '== N passed · M failed ==' summary line in " + path
	}
	m := summaryRe.FindStringSubmatch(last)
	if !onlyZeros(m[2]) {
		return "exit 0 but the summary reports " + m[2] + " failed"
	}
	if onlyZeros(m[1]) {
		return "exit 0 but the summary reports zero test cases"
	}
	return ""
}

// firstFail is the first `  FAIL  ` line of the log with its leading blanks dropped, or a note naming the exit code
// and the log when there is none.
func firstFail(log, path string, rc int) string {
	for _, l := range strings.Split(log, "\n") {
		if strings.HasPrefix(l, "  FAIL  ") {
			return strings.TrimLeft(l, " \t\n\v\f\r")
		}
	}
	return "exit=" + strconv.Itoa(rc) + ", no '  FAIL  ' line in " + path
}

// verdict classifies one finished suite: its status and, for a failure, the first failing line (tabs flattened, as
// results.tsv has four tab-separated fields). rc is the shell exit code of the suite command.
func verdict(rc int, log, path string) (status, first string) {
	switch {
	case rc == exitTimeout:
		status = stTimeout
	case rc != 0:
		status = stFail
	case hasLinePrefix(log, "SKIP:"):
		return stSkip, ""
	default:
		if first = passProblem(log, path); first == "" {
			return stPass, ""
		}
		status = stFail
	}
	if first == "" {
		first = firstFail(log, path, rc)
	}
	return status, strings.ReplaceAll(first, "\t", " ")
}

func hasLinePrefix(log, prefix string) bool {
	return strings.HasPrefix(log, prefix) || strings.Contains(log, "\n"+prefix)
}
