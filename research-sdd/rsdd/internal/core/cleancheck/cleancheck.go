package cleancheck

import (
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
// Check reads almost nothing from the process: the working directory, the environment (git, TMPDIR) and the clock
// are in Options, and every relative path is resolved against Options.Cwd. The one process read is the owner uid,
// taken from os.Getuid only when neither Options.UID nor Options.Self is set. Options.Now and Options.Cwd are
// required: a nil clock or an empty working directory is a typed refusal (Refused, exit 2, no Summary), never a
// panic or a path resolved against "/"; the rsdd command supplies the process clock and directory. It runs only git,
// and only to read.
func Check(o Options) Result {
	r := newRun(o)
	if o.Now == nil {
		r.refuse("Options.Now is required (the command layer supplies the clock)")
		return r.res
	}
	if o.Cwd == "" {
		r.refuse("Options.Cwd is required (relative paths are resolved against it)")
		return r.res
	}
	r.settleScratchpad()
	if r.resolveInputs() && r.resolveBase() && r.loadKeep() && r.scanUntracked() && r.scanStaleTmp() {
		if r.scan() {
			r.summarize()
		}
	}
	return r.res
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
		"tmp.* in " + r.tmp + " older than " + strconv.Itoa(r.o.StaleHours) + "h",
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
