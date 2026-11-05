package cleancheck

import "strings"

// Verdict is how a run ended. Exit maps it: Clean 0, Findings 1, Refused 2, Degraded 3.
type Verdict int

const (
	Clean    Verdict = iota // nothing to report (retention WARNs never change it)
	Findings                // at least one GARBAGE, UNPRESERVED-ARTIFACT or UNMANIFESTED-SCRIPT line
	Refused                 // a refused input or a scan that failed partway: nothing is claimed
	Degraded                // nothing was measured (git missing) or a scan could not run
)

// Stream is stdout or stderr.
type Stream int

const (
	Out Stream = iota
	Err
)

// Line is one line the script prints, without its newline (the text may hold one of its own: a path with a newline).
type Line struct {
	Stream Stream
	Text   string
}

// AbsentKind names an input that is not there: information, never a finding.
type AbsentKind string

// The typed absent-input lines.
const (
	AbsentKeepList   AbsentKind = "ABSENT-KEEPLIST"
	AbsentScratchpad AbsentKind = "ABSENT-SCRATCHPAD"
	AbsentBase       AbsentKind = "ABSENT-BASE"
	AbsentEvidence   AbsentKind = "ABSENT-EVIDENCE"
)

// Absent is one absent input and what was looked for.
type Absent struct {
	Kind AbsentKind
	What string
}

// DegradedKind names a check that could not run.
type DegradedKind string

// The typed degraded states. DEGRADED-NO-SHA256 of the script no longer exists: the hash is computed in process.
const (
	DegradedGit      DegradedKind = "git"
	DegradedWorktree DegradedKind = "DEGRADED-WORKTREE-SCAN"
	DegradedBranch   DegradedKind = "DEGRADED-BRANCH-SCAN"
	DegradedEvidence DegradedKind = "DEGRADED-EVIDENCE-SCAN"
)

// Result is the whole answer of Check.
type Result struct {
	Verdict  Verdict
	Exit     int
	Lines    []Line // stdout and stderr in the order the script printed them
	Findings int
	Warnings int
	Absent   []Absent
	Degraded []DegradedKind
	Summary  string // the final CLEAN-CHECK line; empty when the run stopped before one
}

// Stdout is the stdout lines joined, each ended by a newline.
func (r Result) Stdout() string { return r.stream(Out) }

// Stderr is the stderr lines joined, each ended by a newline.
func (r Result) Stderr() string { return r.stream(Err) }

// Merged is both streams in print order, as `2>&1` shows them.
func (r Result) Merged() string {
	var b strings.Builder
	for _, l := range r.Lines {
		b.WriteString(l.Text + "\n")
	}
	return b.String()
}

func (r Result) stream(s Stream) string {
	var b strings.Builder
	for _, l := range r.Lines {
		if l.Stream == s {
			b.WriteString(l.Text + "\n")
		}
	}
	return b.String()
}
