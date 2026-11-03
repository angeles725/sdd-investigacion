package sweep

import (
	"bytes"
	"fmt"
	"regexp"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/hookenv"
)

// Port of research-sdd/toolbelt/sweep-retros-hook.sh (kit issue #2359), `rsdd sweep retros --hook [--full]`:
// the SessionStart hook that runs the sweep and emits its output as additionalContext. The default is SUMMARY
// mode (the oldest five PENDING blocks, the absent targets collapsed to one line, the Summary: line); --full
// passes the sweep output through unchanged. Like the script it always exits 0: a hook never fails the session.
//
// The sweep runs in process (the script ran $here/sweep-retros.sh with `2>&1`), so the stdout and stderr of
// the sweep share one buffer and keep the order they were written in. A stub of sweep-retros.sh beside the
// hook no longer takes part: the seam is the pure functions summaryFilter and hookContext, tested directly.
// The envelope is always JSON (the script printed plain text when jq was missing).

const (
	hookHeader    = "Research-SDD retro sweep (supervisor project):"
	hookFailedFmt = "Research-SDD retro sweep could not run (exit %d — check TARGETS.md and lib/ helper):"
	pendingLimit  = 5
)

var (
	reAbsentAgg   = regexp.MustCompile(`^INFO: [0-9]+ target\(s\) not traversed \(absent-input\)`)
	reSeeInfo     = regexp.MustCompile(`see INFO lines above\.?`)
	reAbsentInfo  = regexp.MustCompile(`^INFO: corpus not found \(absent-input\):`)
	nineSpaces    = "         "
	pendingPrefix = "PENDING  "
)

func runRetrosHook(o options, s cli.Stdio) int {
	var buf bytes.Buffer // one writer for both streams: the script's `2>&1`
	var res sweepResult
	rc := hookenv.Guard(&buf, func() int { res = sweepRetros(o, s, &buf, &buf); return res.rc })
	hookenv.WriteSessionStart(s.Out, hookContext(strings.TrimRight(buf.String(), "\n"), rc, o.fl))
	return cli.ExitOK
}

// hookContext is the additionalContext for the output of one sweep run: out (trailing newlines stripped) and its
// exit code. A sweep that failed is reported unfiltered under its own header.
func hookContext(out string, rc int, full bool) string {
	if rc != 0 {
		return fmt.Sprintf(hookFailedFmt, rc) + "\n" + out
	}
	if !full {
		out = strings.TrimRight(summaryFilter(out), "\n")
	}
	return hookHeader + "\n" + out
}

// summaryFilter is the awk of the hook: WARN, MISSING-RETRO and waived lines and the per-target absent-input
// lines are dropped; the aggregate absent-input line points at --full; only the oldest five PENDING blocks
// (header plus their nine-space continuation lines) are kept, with a "N more" line before the Summary: line,
// which is otherwise printed as it came.
func summaryFilter(out string) string {
	var b strings.Builder
	pcnt, inBlock := 0, false
	for _, line := range strings.Split(out, "\n") {
		switch {
		case strings.HasPrefix(line, "WARN:"), strings.HasPrefix(line, "MISSING-RETRO:"), strings.HasPrefix(line, "waived:"):
		case reAbsentInfo.MatchString(line):
		case reAbsentAgg.MatchString(line):
			if loc := reSeeInfo.FindStringIndex(line); loc != nil { // awk sub: the first match only
				line = line[:loc[0]] + "run --full to list them." + line[loc[1]:]
			}
			b.WriteString(line + "\n")
		case strings.HasPrefix(line, pendingPrefix):
			pcnt++
			inBlock = pcnt <= pendingLimit
			if inBlock {
				b.WriteString(line + "\n")
			}
		case strings.HasPrefix(line, nineSpaces):
			if inBlock {
				b.WriteString(line + "\n")
			}
		case strings.HasPrefix(line, "Summary:"):
			if pcnt > pendingLimit {
				fmt.Fprintf(&b, "… and %d more — run sweep-retros.sh --full\n", pcnt-pendingLimit)
			}
			b.WriteString(line + "\n")
		default:
			inBlock = false
			b.WriteString(line + "\n")
		}
	}
	return b.String()
}
