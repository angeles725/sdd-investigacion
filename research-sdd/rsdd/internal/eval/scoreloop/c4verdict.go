package scoreloop

import "fmt"

// c4Inputs is everything C4's verdict reads.
type c4Inputs struct {
	stopEpoch   int64
	stopPresent bool
	next        nextVerdict
	queue       queueState
	// after counts blocks committed after STOP that count against the run; unwitnessed those past the grace
	// window and outside the transcript span.
	after, unwitnessed int64
}

const qualifiedPrefix = "STOP is qualified — not a clean zero-open exhaustion: "

// c4Verdict applies the outcome table. A commit after STOP, and a declared non-empty queue, fail outright and
// outrank any qualifier; a qualifier replaces only the pass and n/a outcomes.
func (s *scorer) c4Verdict(in c4Inputs) {
	clean := in.stopPresent && in.next.zeroOpen && in.after == 0
	if clean && in.unwitnessed > 0 {
		evidence := fmt.Sprintf("STOP honored inside the transcript but after_stop_unwitnessed=%d: block commit(s) landed more than %d min after STOP and outside the transcript span — cannot attribute them to this run", in.unwitnessed, s.cfg.GraceMin)
		if in.next.qualifier != "" {
			evidence += "; STOP is also qualified: " + in.next.qualifier
		}
		s.rep.emit("C4", statusDegraded, evidence)
		return
	}
	if clean {
		s.c4Clean(in)
		return
	}
	token, next := "absent", "NOT-STOP"
	if in.stopPresent {
		token = "present"
	}
	if in.next.zeroOpen {
		next = "STOP"
	}
	note := ""
	if in.unwitnessed > 0 {
		note = fmt.Sprintf(" after_stop_unwitnessed=%d", in.unwitnessed)
	}
	s.rep.emit("C4", statusFail, fmt.Sprintf("stop_token=%s status_next=%s queue=%s commits_after_stop=%d%s", token, next, in.queue.name(), in.after, note))
}

// c4Clean decides a run whose STOP token is present, whose status says STOP and that has no block after it.
func (s *scorer) c4Clean(in c4Inputs) {
	q, qualifier := in.queue, in.next.qualifier
	switch {
	case !q.declared && qualifier != "":
		s.rep.emit("C4", statusDegraded, qualifiedPrefix+qualifier+" (no campaign queue declared; 0 block commits after STOP)")
	case !q.declared:
		s.rep.emit("C4", statusNA, "no campaign queue declared — cannot verify queue-drain (stop token present; status --next: STOP; 0 block commits after STOP)")
	case q.empty && qualifier != "":
		s.rep.emit("C4", statusDegraded, qualifiedPrefix+qualifier+" (stop token present; campaign queue empty; 0 block commits after STOP)")
	case q.empty:
		s.rep.emit("C4", statusPass, "STOP token present; status --next: STOP; campaign queue empty; 0 block commits after STOP")
	default:
		s.rep.emit("C4", statusFail, "stop_token=present status_next=STOP queue=non-empty commits_after_stop=0")
	}
}
