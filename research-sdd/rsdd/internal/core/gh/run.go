package gh

// RunResult is a bounded gh call: State is OK, TIMEOUT, GH_ERROR, GH_MISSING, OUTPUT_CAP or PROBE_FAILED; RC
// is the shell exit code (124 for the bound, 127 for a missing gh); Stdout and Stderr are gh's, for the caller
// to write.
type RunResult struct {
	State          State
	RC             int
	Bound          Bound
	Stdout, Stderr []byte
}

// Run is gh_bounded_run: `gh <args>` under the bound. A gh killed by SIGKILL (137) is the bound's KILL
// escalation and reads as TIMEOUT, as in the bash. The error is non-nil only for StateProbeFailed.
func Run(o Options, args ...string) (RunResult, error) {
	out, err := o.launch(args)
	r := RunResult{State: out.state, RC: out.rc, Bound: out.bound, Stdout: out.res.Stdout, Stderr: out.res.Stderr}
	switch {
	case r.State == "":
		r.State = StateOK
	case r.State == StateMissing:
		r.RC = 127
	case r.State == StateError && r.RC == 137:
		r.State, r.RC = StateTimeout, 124
	}
	return r, err
}
