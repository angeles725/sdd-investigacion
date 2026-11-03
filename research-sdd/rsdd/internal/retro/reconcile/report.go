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
	// Fleet is the --all summary; nil for a single-retro audit.
	Fleet *Fleet

	stdout []string
	// ancDegraded marks a retro whose commit reachability could not be verified (the probe is run-wide and
	// written once, but every retro that needed it is degraded, kit issue #1709).
	ancDegraded bool
	// done marks an audit that reached its end: only such a retro is counted in the fleet totals.
	done bool
}

// Fleet is the --all summary: the totals of the retros that were audited to the end, the retros that could not
// be (Degraded) and the corpus findings outside the failure channel (OutOfScope).
type Fleet struct {
	Tracked, Untracked, Shipped, Borderline, Regressed, Orphaned int
	Degraded, OutOfScope, Retros                                 int
}

// Line is the fleet-summary line of the legacy script.
func (f Fleet) Line() string {
	return fmt.Sprintf("fleet-summary: tracked=%d untracked=%d shipped=%d borderline=%d regressed=%d orphaned=%d degraded=%d out-of-scope=%d retros=%d",
		f.Tracked, f.Untracked, f.Shipped, f.Borderline, f.Regressed, f.Orphaned, f.Degraded, f.OutOfScope, f.Retros)
}

// failed reports whether the audit returned 1 in the legacy script: a degraded line, or commit reachability that
// could not be verified.
func (r *Report) failed() bool { return r.Degraded != "" || r.ancDegraded }

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
	if r.Degraded != "" || r.Failure != "" || (r.Fleet != nil && r.Fleet.Degraded > 0) {
		return 1
	}
	return 0
}
