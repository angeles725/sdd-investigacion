package scoreloop

import (
	"fmt"
	"strings"
)

// c4 is "STOP honored": the RETURN CONTRACT `STOP:` token is the last line of the run's final return, the status
// script reports 0 open (`--next` returns `STOP | ...`) and a GENUINELY DECLARED, drained campaign queue, and no
// block commit lands after the STOP moment. n/a without a transcript or when no queue was ever declared; degraded
// when the status script is unusable, STALE, or its STOP is qualified (kit issues #1107, #1995).
//
// KNOWN LIMITS: only the orchestrated /loop mode emits a STOP token; with a delegated sub-agent the token lands in
// a tool_result, so evals/profile-ab/PROTOCOL.md requires the driver to repeat it verbatim.
func (s *scorer) c4() {
	f := s.facts
	switch {
	case !f.Given:
		s.rep.emit("C4", statusNA, "no transcript: cannot locate the final return or STOP moment")
		return
	case !f.usable():
		s.rep.emit("C4", statusDegraded, s.unusableReason())
		return
	case f.unrecognized():
		s.rep.emit("C4", statusDegraded, "unrecognized transcript shape")
		return
	case len(f.FinalParas) == 0:
		s.rep.emit("C4", statusNA, "transcript has no assistant final messages (empty-input)")
		return
	case !readable(s.statusScript):
		s.rep.emit("C4", statusDegraded, fmt.Sprintf("research-sdd-status.sh not found or not readable at %s", s.statusScript))
		return
	}
	st := s.status(s.statusScript, s.corpus)
	if reason := statusFailure(st); reason != "" {
		s.rep.emit("C4", statusDegraded, reason)
		return
	}
	last := len(f.FinalParas) - 1
	in := c4Inputs{
		stopEpoch:   f.FinalEpochs[last],
		stopPresent: s.cfg.StopToken.MatchString(stripMarkdownWrap(lastLine(f.FinalParas[last]))),
		next:        classifyNext(st.next),
		queue:       parseQueue(st.def),
	}
	var err error
	if in.after, in.unwitnessed, err = s.afterStop(in.stopEpoch); err != nil {
		s.abort = err
		return
	}
	s.c4Verdict(in)
}

// statusFailure is the degraded evidence for a status script that could not answer, or "" when it did.
func statusFailure(st statusOutcome) string {
	switch {
	case st.problem != "":
		return st.problem
	case st.rcDef != 0 || st.rcNext != 0:
		reason := fmt.Sprintf("research-sdd-status.sh failed (default exit=%d, --next exit=%d)", st.rcDef, st.rcNext)
		if st.stderrFirstLine != "" {
			reason += ": " + st.stderrFirstLine
		}
		return reason
	case strings.HasPrefix(st.next, "STALE"):
		return "research-sdd-status.sh --next reports STALE: " + st.next
	}
	return ""
}

// lastLine is the last line of a paragraph.
func lastLine(para string) string {
	return para[strings.LastIndex(para, "\n")+1:]
}

// markdownWrapChars are stripped from the front of the STOP line: a backtick, emphasis, quote or blank.
const markdownWrapChars = "`*_> \t\n\v\f\r"

func stripMarkdownWrap(line string) string { return strings.TrimLeft(line, markdownWrapChars) }
