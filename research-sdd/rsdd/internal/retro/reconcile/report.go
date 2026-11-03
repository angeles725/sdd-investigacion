package reconcile

import (
	"fmt"
	"io"
)

// Delta is one finding of an audit: a retro row id, the retro file it belongs to (base name) and, for an orphaned
// issue, the reason the row is no longer open.
type Delta struct {
	Row   string
	Retro string
	Why   string
}

// Report is the outcome of auditing one retro. The typed states stay distinct (CLAUDE.md §7): Degraded is a
// "degraded:" line (exit 1), Failure an operational stop such as absent-input or an unresolvable target (exit 1),
// OutOfScopeMarker the corpus finding that sits outside the failure channel (exit 0, nothing classified).
type Report struct {
	Untracked []Delta
	Tracked   []Delta
	Orphaned  []Delta
	// Shipped are rows with no open issue whose issue was closed as completed AND whose closure evidence holds
	// (Why = the cited commit that reaches the main ref); Borderline the same with incomplete evidence (Why = the
	// reasons); Regressed the shipped rows proposed again as open deltas in a later retro (Why = the legacy line
	// after "regressed: "). None of them is also Untracked.
	Shipped    []Delta
	Borderline []Delta
	Regressed  []Delta
	// Degraded is the "degraded: ..." line of a run that could not reach a verdict; "" = not degraded.
	Degraded string
	// OutOfScopeMarker is the "out-of-scope-marker: ..." line; "" = none.
	OutOfScopeMarker string
	// Failure is the line of a stop that is neither a verdict nor a "degraded:" (absent-input, no registered
	// target); "" = none.
	Failure string
	// Notes are the stderr lines in emission order, without their newline.
	Notes []string

	stdout []string
}

func (r *Report) note(format string, args ...any) {
	r.Notes = append(r.Notes, fmt.Sprintf(format, args...))
}

func (r *Report) out(format string, args ...any) {
	r.stdout = append(r.stdout, fmt.Sprintf(format, args...))
}

func (r *Report) degrade(format string, args ...any) {
	r.Degraded = fmt.Sprintf(format, args...)
	r.Notes = append(r.Notes, r.Degraded)
}

func (r *Report) fail(format string, args ...any) {
	r.Failure = fmt.Sprintf(format, args...)
	r.Notes = append(r.Notes, r.Failure)
}

// Render writes the legacy bytes: the findings to stdout, the typed states to stderr. The result is the exit
// code of reconcile-issues.sh: 1 for a degraded run or an operational stop, 0 otherwise (findings never fail).
func (r Report) Render(stdout, stderr io.Writer) int {
	for _, l := range r.stdout {
		fmt.Fprintln(stdout, l)
	}
	for _, l := range r.Notes {
		fmt.Fprintln(stderr, l)
	}
	if r.Degraded != "" || r.Failure != "" {
		return 1
	}
	return 0
}
