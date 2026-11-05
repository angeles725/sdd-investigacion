package show

import (
	"bytes"
	"fmt"
	"os"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// verdictPrefixes are the first-column verdict shapes --emit-token recognises (ET-VERDICT-PICK).
var verdictPrefixes = []string{"NEXT | ", "STOP | ", "ISSUES-DUE | ", "RETRO-DUE | ", "STALE | ", "BOOTSTRAP | "}

// emitToken is the --emit-token block (kit #1706): it re-runs the command on the same argv minus the flag, prints
// that output, then ONE `return-token: <token>` line mapped from the same verdict, or `return-token: unavailable
// (<reason>)` with exit 1. The re-run is in process (the script re-execs itself): same stdin, stderr and tail.
func emitToken(args []string, s cli.Stdio, t tail) int {
	var rerun []string
	for _, a := range args {
		if a != "--emit-token" {
			rerun = append(rerun, a)
		}
	}
	var buf bytes.Buffer
	child := s
	child.Out = &buf
	rc := run(rerun, child, t)
	out := strings.TrimRight(buf.String(), "\n") // $(...) drops the trailing newlines
	if out != "" {
		fmt.Fprintf(s.Out, "%s\n", out)
	}
	unavail := func(why string) int {
		fmt.Fprintf(s.Out, "return-token: unavailable (%s)\n", why)
		return 1
	}
	if rc != 0 {
		return unavail(fmt.Sprintf("--next exited %d", rc)) // ET-RC-GATE
	}
	if out == "" {
		return unavail("--next printed nothing")
	}
	verdict, n := pickVerdict(out)
	if n != 1 {
		return unavail(fmt.Sprintf("--next output carries %d verdict lines (want exactly 1)", n)) // ET-VERDICT-ONE
	}
	switch {
	case strings.HasPrefix(verdict, "NEXT | "):
		rest := strings.TrimPrefix(verdict, "NEXT | ")
		_, gap, found := strings.Cut(rest, " | ")
		if !found || gap == "" {
			return unavail("NEXT verdict carries no gap")
		}
		fmt.Fprintf(s.Out, "return-token: next: %s\n", gap) // ET-NEXT-MAP
		return 0
	case strings.HasPrefix(verdict, "STOP | "):
		return stopToken(args, verdict, s, unavail)
	}
	return unavail(fmt.Sprintf("verdict '%s' has no RETURN CONTRACT token; resolve it first", firstWord(verdict))) // ET-OTHER-UNAVAILABLE
}

// pickVerdict selects the verdict line by prefix (kit #1726): lines are read with IFS= read -r, so blanks are
// kept and an indented line is not a verdict. n counts the verdict lines seen; the picked one is the last.
func pickVerdict(out string) (verdict string, n int) {
	for _, ln := range strings.Split(out, "\n") {
		for _, p := range verdictPrefixes {
			if strings.HasPrefix(ln, p) {
				verdict = ln
				n++
				break
			}
		}
	}
	return verdict, n
}

// firstWord is `${v%% *}`.
func firstWord(v string) string {
	w, _, _ := strings.Cut(v, " ")
	return w
}

// stopToken maps a STOP verdict to `STOP: campaign — <reason>` only for ONE state file with no `## Campaign queue`
// (the count is corpus-wide, never narrowed by --focus/--root).
func stopToken(args []string, verdict string, s cli.Stdio, unavail func(string) int) int {
	if strings.Contains(verdict, "[backlog-unreadable: ") {
		return unavail("STOP carries [backlog-unreadable: N rows] — unread backlog rows must be reconciled before any STOP: campaign token") // ET-BU-NONTERMINAL
	}
	c := &ctx{s: s, target: args[0]}
	states, err := listStateFiles(c.abs(c.target))
	if err != nil {
		return unavail("STOP: cannot enumerate state files (" + err.Error() + ")")
	}
	if len(states) != 1 {
		return unavail(fmt.Sprintf("STOP over %d state files needs the §8c campaign-close partition check (--focus/--root scope the verdict, not the campaign)", len(states))) // ET-STOP-MULTI-GUARD
	}
	body, err := os.ReadFile(states[0])
	if err != nil || hasCampaignQueue(body) {
		return unavail("STOP with a ## Campaign queue (or unreadable state) needs next-entry vs STOP: campaign from §8c") // ET-STOP-QUEUE-GUARD
	}
	fmt.Fprintf(s.Out, "return-token: STOP: campaign — %s\n", strings.TrimPrefix(verdict, "STOP | ")) // ET-STOP-MAP
	return 0
}

// hasCampaignQueue is `grep -q '^## Campaign queue'`: a line that starts with the heading text.
func hasCampaignQueue(body []byte) bool {
	return bytes.HasPrefix(body, []byte("## Campaign queue")) || bytes.Contains(body, []byte("\n## Campaign queue"))
}
