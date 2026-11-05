package cleancheck

import (
	"io/fs"
	"os"
	"strings"
	"time"
)

// run is the state of one Check: the resolved inputs, the counters of the summary and the lines printed so far.
type run struct {
	o   Options
	res Result
	env []string // the environment of git: Options.Env without the repository selectors

	target, targetP string // --target as given, and its physical path
	tmp, tmpP       string // the tmp directory as printed (one trailing slash stripped), and its physical path
	uid             uint64 // the owner of the tmp.* entries that are reported
	now             time.Time

	scratchP string // the scratchpad: physical when it exists, as given (one slash stripped) otherwise; empty = not set
	keep     keepList

	base baseRef // the branch scan's base, when one resolves

	findings, warnings int
	degradedWhy        []string
	fields             []string // the summary's fields, in order

	lstat func(string) (fs.FileInfo, error) // os.Lstat; a test replaces it to make an entry vanish
}

func newRun(o Options) *run {
	return &run{o: o, lstat: os.Lstat}
}

// stdout prints one line on stdout.
func (r *run) stdout(text string) { r.res.Lines = append(r.res.Lines, Line{Out, text}) }

// stderr prints one line on stderr.
func (r *run) stderr(text string) { r.res.Lines = append(r.res.Lines, Line{Err, text}) }

// passthrough forwards a child's stderr as it came: the script left git's and find's diagnostics visible.
func (r *run) passthrough(text string) {
	if text != "" {
		r.stderr(strings.TrimSuffix(text, "\n"))
	}
}

// refuse ends the run with the script's `_err` line and exit 2: an input it will not measure, or a scan that failed
// partway. Nothing is claimed about the target.
func (r *run) refuse(msg string) bool {
	r.stderr("clean-check: ERROR: " + msg)
	r.res.Verdict, r.res.Exit = Refused, 2
	return false
}

// finding prints one finding line and counts it.
func (r *run) finding(line string) {
	r.stdout(line)
	r.findings++
}

// warn prints one report-only retention warning and counts it (it never changes the exit code).
func (r *run) warn(text string) {
	r.stdout("WARN " + text)
	r.warnings++
}

// absent prints a typed absent-input line and records it.
func (r *run) absent(kind AbsentKind, what, line string) {
	r.stdout(line)
	r.res.Absent = append(r.res.Absent, Absent{kind, what})
}

// degrade prints a typed line for a scan that could not run: never a finding, never a quiet zero.
func (r *run) degrade(kind DegradedKind, line, why string) {
	r.stdout(line)
	r.res.Degraded = append(r.res.Degraded, kind)
	r.degradedWhy = append(r.degradedWhy, why)
}

// oneLine is a message with its newlines turned into spaces, as `${m//$'\n'/ }`.
func oneLine(s string) string { return strings.ReplaceAll(s, "\n", " ") }
