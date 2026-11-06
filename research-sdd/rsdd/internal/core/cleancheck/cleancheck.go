package cleancheck

import (
	"context"
	"strconv"
	"strings"
)

// Check is the whole of clean-check: it lists what a run should not leave behind in a target, and it never writes
// anything (propose-never-apply). It is the one entry point; the rsdd command only parses flags and prints the lines,
// and internal/status/show calls it in process.
//
// The Result carries the verdict, the exact lines the script printed on stdout and stderr in the order it printed
// them (Merged is the `2>&1` view), the exit code (0 clean, 1 findings, 2 a refused input or a failed scan, 3
// degraded), and the typed states: Absent for each input that was not there (the keep-list, the scratchpad, the base,
// the evidence directory) and Degraded for each check that could not run. Retention WARNs are counted in Warnings and
// never change the verdict. A run that stopped early (Refused, or git missing) has no Summary line.
//
// The context bounds the run: once it is cancelled or its deadline passes, the walks and loops stop at the next
// entry, a running git is stopped (when the context has a deadline: its timeout is cut to it) and the Result is the
// typed TimedOut state (exit 124, one stderr line, nothing else), never a clean or a partial findings list. A context
// that never ends bounds nothing beyond the ten-minute ceiling of each git.
//
// Check reads its inputs from Options (see there for the exact process reads): the working directory, the environment
// (git, TMPDIR, CLEAN_CHECK_SCRATCHPAD, CLEAN_CHECK_UID) and the clock, and every relative path is resolved against
// Options.Cwd. Options.Now, an absolute Options.Cwd and a context are required: a missing or relative one is a typed
// refusal (Refused, exit 2, no Summary), never a panic or a path resolved against the process. It runs only git, and
// only to read.
func Check(ctx context.Context, o Options) Result {
	r := newRun(ctx, o)
	if !r.requirements() {
		return r.res
	}
	if r.stopped() {
		return r.timedOut()
	}
	r.applyEnv()
	r.settleScratchpad()
	if r.resolveInputs() && r.resolveBase() && r.loadKeep() && r.scanUntracked() && r.scanStaleTmp() {
		if r.scan() {
			r.summarize()
		}
	}
	if r.stopped() {
		return r.timedOut()
	}
	return r.res
}

// requirements refuses the Options a run cannot start from: no clock, no or a relative working directory, no context.
func (r *run) requirements() bool {
	if r.o.Now == nil {
		return r.refuse("Options.Now is required (the command layer supplies the clock)")
	}
	if r.o.Cwd == "" {
		return r.refuse("Options.Cwd is required (relative paths are resolved against it)")
	}
	if !strings.HasPrefix(r.o.Cwd, "/") {
		return r.refuse("Options.Cwd must be an absolute path (a relative one would be resolved against the process): '" + r.o.Cwd + "'")
	}
	if r.ctx == nil {
		return r.refuse("a context is required (context.Background() for a run nothing bounds)")
	}
	return true
}

// scan runs the scratchpad and retention scans in the script's order and keeps their summary fields.
func (r *run) scan() bool {
	scratch, ok := r.scanScratchpad()
	if !ok {
		return false
	}
	ws := r.scanWorktrees()
	r.fields = []string{
		"untracked in " + r.target,
		"tmp.* in " + r.tmp + " older than " + strconv.Itoa(r.staleHours) + "h",
		"keep-list entries: " + strconv.Itoa(len(r.keep.globs)),
		"scratchpad: " + scratch,
		"worktrees: " + ws.state,
	}
	r.fields = append(r.fields, "branches: "+r.scanBranches(ws), "evidence: "+r.scanEvidence())
	return true
}

// summarize prints the final CLEAN-CHECK line and settles the verdict. Findings win over a degraded scan (they are
// true and actionable); a degraded run with no findings is never clean.
func (r *run) summarize() {
	r.fields = append(r.fields, "warnings: "+strconv.Itoa(r.warnings))
	if len(r.degradedWhy) > 0 {
		r.fields = append(r.fields, "degraded: "+strings.Join(r.degradedWhy, "; "))
	}
	detail := strings.Join(r.fields, ", ")
	r.res.Findings, r.res.Warnings = r.findings, r.warnings
	switch {
	case r.findings > 0:
		r.res.Verdict, r.res.Exit = Findings, 1
		r.res.Summary = "CLEAN-CHECK: " + strconv.Itoa(r.findings) + " finding(s) (" + detail + ")"
	case len(r.degradedWhy) > 0:
		r.res.Verdict, r.res.Exit = Degraded, 3
		r.res.Summary = "CLEAN-CHECK: degraded (" + detail + ")"
	default:
		r.res.Verdict, r.res.Exit = Clean, 0
		r.res.Summary = "CLEAN-CHECK: clean (" + detail + ")"
	}
	r.stdout(r.res.Summary)
}
