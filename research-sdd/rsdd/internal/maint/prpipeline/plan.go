package prpipeline

import "fmt"

// say is kit_say: `kit-pr-pipeline: MSG` on stdout.
func (p *pipeline) say(format string, a ...any) {
	fmt.Fprintf(p.s.Out, "%s: %s\n", tool, fmt.Sprintf(format, a...))
}

// fail is kit_fail: the typed line (`kit-pr-pipeline: STATE[: MSG]`), and the exit code to return.
func (p *pipeline) fail(code int, state, format string, a ...any) int {
	if format == "" {
		p.say("%s", state)
		return code
	}
	p.say("%s: %s", state, fmt.Sprintf(format, a...))
	return code
}

// printPlan is the --dry-run output: the six steps and the state dir; nothing is run.
func (p *pipeline) printPlan() {
	o := p.o
	sizeCheck := o.sizeCheck
	if sizeCheck == "" {
		sizeCheck = "none"
	}
	consent := o.consent
	if consent == "" {
		consent = "NOT given (the envelope is printed, exit 15)"
	}
	p.say("plan: 1. fetch %s; restack: merge %s into the branch only when it is behind (conflict -> abort, exit 11)", o.remote, o.base)
	p.say("plan: 2. push HEAD to %s:%s (3 tries)", o.remote, o.branch)
	p.say("plan: 3. size-check hook: %s", sizeCheck)
	p.say("plan: 4. RDD: assess %s..HEAD; if due, STATUS -> START; consent %s; then follow the review to acknowledgement", o.base, consent)
	p.say("plan: 5. gate: %s", p.gatePlan())
	p.say("plan: 6. CI wait on PR #%s, then merge-gate --merge (degraded retried)", o.pr)
	p.say("plan: state dir %s; nothing was run", p.state)
}

// gatePlan is the step-5 line of the plan.
func (p *pipeline) gatePlan() string {
	o := p.o
	if o.noGate {
		return "skipped"
	}
	switch {
	case o.gateCmd != "":
		return "flock'd " + o.gateCmd
	case o.serial:
		return "flock'd run-all.sh --prove-teeth (serial)"
	}
	return "flock'd run-all.sh -j 4 --prove-teeth"
}
