package scoreloop

import (
	"fmt"
	"io"
)

// Criterion outcomes. n/a is "could not be measured here" (no transcript, no queue declared); degraded is "the
// instrument could not see" (a missing dependency, an unparsable or unrecognised transcript, an unwitnessed commit).
const (
	statusPass     = "pass"
	statusFail     = "fail"
	statusNA       = "n/a"
	statusDegraded = "degraded"
)

// report accumulates the criterion lines and their tally.
type report struct {
	lines                    []string
	pass, fail, na, degraded int
}

func (r *report) emit(id, status, evidence string) {
	switch status {
	case statusPass:
		r.pass++
	case statusFail:
		r.fail++
	case statusNA:
		r.na++
	case statusDegraded:
		r.degraded++
	}
	r.lines = append(r.lines, fmt.Sprintf("%s %s %s", id, status, evidence))
}

// noFinals reports the empty-input state of the final-message criteria (C2, C4): the transcript parsed but holds no
// assistant final message. The state name goes through fmt.Sprintf so the reason-codes scanner sees the emission.
func (r *report) noFinals(id string) {
	r.emit(id, statusNA, fmt.Sprintf("transcript has no assistant final messages (%s)", "empty-input"))
}

func (r *report) summary() string {
	return fmt.Sprintf("SUMMARY pass=%d fail=%d n/a=%d degraded=%d", r.pass, r.fail, r.na, r.degraded)
}

// write prints the criterion lines, then (when complete) the summary.
func (r *report) write(w io.Writer, complete bool) {
	for _, l := range r.lines {
		fmt.Fprintln(w, l)
	}
	if complete {
		fmt.Fprintln(w, r.summary())
	}
}
