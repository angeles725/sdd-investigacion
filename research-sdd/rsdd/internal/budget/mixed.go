package budget

// mixed.go: the mixed worst case of the SessionStart budget (kit issue #2756).
//
// Claude Code runs every SessionStart hook as its own process and nobody trims their sum, so a hook that FAILS
// still hands the model a bounded failure context (hookenv.FailureCap) in place of its normal one. The worst mix of
// a source is therefore the sum, over its hooks, of max(normal size, FailureCap): a failing hook costs the cap only
// when its normal context is smaller. The figure is a READING built from measured normal sizes; it becomes a bound
// only when every hook declares a success-path maximum (kit issue #2773).

import (
	"fmt"
	"path/filepath"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/hookenv"
)

// piBound is the cap the pi extension puts on its whole injected string (MAX_INJECT_CHARS in the extension).
const piBound = 7900

// reading is one hook of one session source: its measured normal context, or "not measured" when it degraded.
type reading struct {
	name  string
	chars int
	deg   bool
}

// hookName is the label of a hook in the mixed lines: the script basename of its command, without ".sh".
func hookName(cmd string) string {
	f := strings.Fields(cmd)
	if len(f) == 0 {
		return ""
	}
	if i := indexScript(f); i >= 0 {
		f = f[i:]
	}
	return strings.TrimSuffix(filepath.Base(strings.Trim(f[0], `"'`)), ".sh")
}

// indexScript is the index of the first word that names a .sh script, or -1.
func indexScript(f []string) int {
	for i, w := range f {
		if strings.HasSuffix(strings.Trim(w, `"'`), ".sh") {
			return i
		}
	}
	return -1
}

// mixedSourceLine is the `mixed[<src>]:` line of one source and its mixed total. A degraded hook has no measured
// size: it is counted at the cap and the line is marked partial, never printed as if complete.
func mixedSourceLine(src string, rs []reading) (string, int) {
	total, normal, ndeg := 0, 0, 0
	var big, capped []string
	for _, r := range rs {
		switch {
		case r.deg:
			ndeg++
			total += hookenv.FailureCap
			capped = append(capped, r.name+" (not measured)")
		case r.chars >= hookenv.FailureCap:
			normal += r.chars
			total += r.chars
			big = append(big, fmt.Sprintf("%s %d", r.name, r.chars))
		default:
			normal += r.chars
			total += hookenv.FailureCap
			capped = append(capped, r.name)
		}
	}
	partial := ""
	if ndeg > 0 {
		partial = fmt.Sprintf(" (partial: %d degraded, counted at the cap)", ndeg)
	}
	return fmt.Sprintf("mixed[%s]: %d chars (budget < %d) mixed-verdict=%s (normal total %d, all-fail %d x %d = %d) — normal: %s; cap %d: %s%s",
		src, total, sessionCap, mixedVerdict(total), normal, len(rs), hookenv.FailureCap, len(rs)*hookenv.FailureCap,
		orNone(big), hookenv.FailureCap, orNone(capped), partial), total
}

// mixedOverallLine is the `mixed:` line over all sources, with what the figure is.
func mixedOverallLine(worst int, worstSrc string, ndeg int) string {
	partial := ""
	if ndeg > 0 {
		partial = fmt.Sprintf(" (partial: %d degraded)", ndeg)
	}
	return fmt.Sprintf("mixed: %d chars (budget < %d) mixed-verdict=%s%s worst-source=%s — a reading from measured normal contexts, not a bound until every hook declares a success-path maximum (#2773)",
		worst, sessionCap, mixedVerdict(worst), partial, worstSrc)
}

// piMixedLine is what the pi harness says about the mixed case.
func piMixedLine() string {
	return fmt.Sprintf("mixed: not computed for pi (the extension caps its whole injected string at %d characters itself)", piBound)
}

// mixedVerdict reuses the budget verdict with words that the OVER BUDGET parser of the normal total never matches.
func mixedVerdict(total int) string {
	if verdict(total) == "OK" {
		return "OK"
	}
	return "OVER"
}

func orNone(s []string) string {
	if len(s) == 0 {
		return "none"
	}
	return strings.Join(s, ", ")
}
