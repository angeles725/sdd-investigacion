package sweep

import (
	"bytes"
	"fmt"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// Port of research-sdd/toolbelt/sweep-audits-hook.sh (kit issue #2577), `rsdd sweep audits --hook [--full]`: the
// SessionStart hook that runs the sweep and emits its output as additionalContext. The default is SUMMARY mode
// (the per-target absent-input lines are dropped, the empty-input lines counted in one line at the end); --full
// passes the sweep output through unchanged. Like the script it always exits 0: a hook never fails the session.
//
// The sweep runs in process (the script ran $here/sweep-audits.sh with `2>&1`), so the stdout and stderr of the
// sweep share one buffer and keep the order they were written in. The seam is the pure functions
// auditsSummaryFilter and auditsHookContext, tested directly. The envelope is the one of the retro hook.

const (
	auditsHookHeader    = "Research-SDD pending audits (per-target §13):"
	auditsHookFailedFmt = "Research-SDD audits sweep could not run (exit %d — check TARGETS.md and lib/ helper):"
)

func runAuditsHook(o options, s cli.Stdio) int {
	var buf bytes.Buffer // one writer for both streams: the script's `2>&1`
	rc := sweepAudits(o, s, &buf, &buf)
	writeSessionStart(s.Out, auditsHookContext(strings.TrimRight(buf.String(), "\n"), rc, o.fl))
	return cli.ExitOK
}

// auditsHookContext is the additionalContext for the output of one sweep run: out (trailing newlines stripped)
// and its exit code. A sweep that failed is reported unfiltered under its own header.
func auditsHookContext(out string, rc int, full bool) string {
	if rc != 0 {
		return fmt.Sprintf(auditsHookFailedFmt, rc) + "\n" + out
	}
	if !full {
		out = strings.TrimRight(auditsSummaryFilter(out), "\n")
	}
	return auditsHookHeader + "\n" + out
}

// auditsSummaryFilter is the awk of the hook: the per-target absent-input lines are dropped, the aggregate
// absent-input line points at --full, and the empty-input lines (§7: a state of its own, neither absent nor
// no-match) are counted and replaced by ONE line after everything else, whatever order they came in.
func auditsSummaryFilter(out string) string {
	var b strings.Builder
	empty := 0
	for _, line := range strings.Split(out, "\n") {
		switch {
		case reAbsentInfo.MatchString(line):
		case strings.HasPrefix(line, "INFO: corpus exists, no audits found (empty-input):"):
			empty++
		case reAbsentAgg.MatchString(line):
			if loc := reSeeInfo.FindStringIndex(line); loc != nil { // awk sub: the first match only
				line = line[:loc[0]] + "run --full to list them." + line[loc[1]:]
			}
			b.WriteString(line + "\n")
		default:
			b.WriteString(line + "\n")
		}
	}
	if empty > 0 {
		fmt.Fprintf(&b, "INFO: %d corpus(es) empty-input — run --full to list them\n", empty)
	}
	return b.String()
}
