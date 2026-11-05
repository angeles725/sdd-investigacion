package sweep

import (
	"bytes"
	"fmt"
	"regexp"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/hookenv"
)

// Port of research-sdd/toolbelt/sweep-breakthroughs-hook.sh (kit issue #2360), `rsdd sweep breakthroughs --hook
// [--full]`: the SessionStart hook that runs the sweep and emits its output as additionalContext. The default is
// SUMMARY mode (the per-target absent-input lines are dropped, the empty-input and no-match lines counted in one
// line each, the unindexed WARNs collapsed into one line naming five); --full passes the sweep output through
// unchanged. Like the script it always exits 0: a hook never fails the session, and it always speaks.
//
// The sweep runs in process (the script ran $here/sweep-breakthroughs.sh with `2>&1`), so its stdout and stderr
// share one buffer and keep the order they were written in. The seam is the pure functions
// breakthroughsSummaryFilter and breakthroughsHookContext. The envelope is hookenv.WriteSessionStart, and
// hookenv.Guard turns a panic in the sweep into the could-not-run context. As the other ported
// hook, it is always JSON (the script printed plain text when jq was missing).

const (
	btHookHeader    = "Research-SDD breakthrough ledger sweep (§22):"
	btHookFailedFmt = "Research-SDD breakthroughs sweep could not run (exit %d — check TARGETS.md and lib/ helper):"
	btNamedLimit    = 5
)

var (
	btEmptyPrefix = "INFO: corpus exists, no block files (empty-input):"
	reBTNoMatch   = regexp.MustCompile(`^INFO: no tagged breakthroughs in corpus \(no-match[^)]*\):`)
)

// The sweep exits 1 only when it could not run (a finding never fails it), so a panic, which hookenv.Guard reports
// as cli.ExitOperational (also 1), shares that header truthfully and needs no finished flag.
func runBreakthroughsHook(o options, s cli.Stdio, read readFunc) int {
	var buf bytes.Buffer // one writer for both streams: the script's `2>&1`
	rc := hookenv.Guard(&buf, func() int { return sweepBreakthroughs(o, s, &buf, &buf, read) })
	hookenv.WriteSessionStart(s.Out, breakthroughsHookContext(strings.TrimRight(buf.String(), "\n"), rc, o.fl))
	return cli.ExitOK
}

// breakthroughsHookContext is the additionalContext for the output of one sweep run: out (trailing newlines
// stripped) and its exit code. A sweep that failed is reported unfiltered under its own header.
func breakthroughsHookContext(out string, rc int, full bool) string {
	if rc != 0 {
		return fmt.Sprintf(btHookFailedFmt, rc) + "\n" + out
	}
	if !full {
		out = strings.TrimRight(breakthroughsSummaryFilter(out), "\n")
	}
	return btHookHeader + "\n" + out
}

// breakthroughsSummaryFilter is the awk of the hook. The per-target absent-input lines are dropped and the
// aggregate one points at --full; the empty-input and no-match lines (§7: states of their own) are counted;
// the unindexed WARNs are counted and the first five named as parentdir/file:line; blank lines and the
// "For each unindexed" hint are dropped. The counted lines come after everything else, in that order.
func breakthroughsSummaryFilter(out string) string {
	var b strings.Builder
	var names []string
	empty, noMatch, unindexed := 0, 0, 0
	for _, line := range strings.Split(out, "\n") {
		switch {
		case reAbsentInfo.MatchString(line):
		case strings.HasPrefix(line, btEmptyPrefix):
			empty++
		case reBTNoMatch.MatchString(line):
			noMatch++
		case reAbsentAgg.MatchString(line):
			if loc := reSeeInfo.FindStringIndex(line); loc != nil { // awk sub: the first match only
				line = line[:loc[0]] + "run --full to list them." + line[loc[1]:]
			}
			b.WriteString(line + "\n")
		case strings.HasPrefix(line, "WARN: unindexed breakthrough"):
			unindexed++
			if unindexed <= btNamedLimit {
				names = append(names, parentAndFile(line))
			}
		case strings.HasPrefix(line, "For each unindexed breakthrough:"):
		case strings.Trim(line, " \t") == "":
		default:
			b.WriteString(line + "\n")
		}
	}
	if unindexed > 0 {
		more := ""
		if unindexed > btNamedLimit {
			more = fmt.Sprintf(", +%d more", unindexed-btNamedLimit)
		}
		fmt.Fprintf(&b, "WARN: %d unindexed breakthrough(s) not in BREAKTHROUGHS.md: %s%s — add a row each (path:line); run --full for all\n",
			unindexed, strings.Join(names, ", "), more)
	}
	switch {
	case empty > 0 && noMatch > 0:
		fmt.Fprintf(&b, "INFO: %d corpus(es) empty-input, %d no-match — run --full to list them\n", empty, noMatch)
	case empty > 0:
		fmt.Fprintf(&b, "INFO: %d corpus(es) empty-input — run --full to list them\n", empty)
	case noMatch > 0:
		fmt.Fprintf(&b, "INFO: %d corpus(es) no-match — run --full to list them\n", noMatch)
	}
	return b.String()
}

// parentAndFile is the pointer of an unindexed WARN reduced to its last two path segments: the text after the
// last "BREAKTHROUGHS.md: " (awk's greedy sub), then parentdir/file:line.
func parentAndFile(warn string) string {
	const lead = "BREAKTHROUGHS.md: "
	p := warn
	if i := strings.LastIndex(p, lead); i >= 0 {
		p = p[i+len(lead):]
	}
	seg := strings.Split(p, "/")
	return strings.Join(seg[max(0, len(seg)-2):], "/")
}
