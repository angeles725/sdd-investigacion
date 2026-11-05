package scoreloop

import (
	"fmt"
	"regexp"
	"strings"
)

// spanishPair is a `¿ ... ?` pair anywhere in the paragraph (it may cross lines).
var spanishPair = regexp.MustCompile(`¿[^¿]*\?`)

// c2 counts the assistant FINAL messages (the last assistant record before the next operator turn, or before the
// end of the transcript) whose final paragraph contains a question. KNOWN LIMIT: a rhetorical question reads
// identically to a genuine ask; the criterion sees phrasing, not intent.
func (s *scorer) c2() {
	f := s.facts
	switch {
	case !f.Given:
		s.rep.emit("C2", statusNA, "no transcript")
		return
	case !f.usable():
		s.rep.emit("C2", statusDegraded, s.unusableReason())
		return
	case f.unrecognized():
		s.rep.emit("C2", statusDegraded, "unrecognized transcript shape")
		return
	case len(f.FinalParas) == 0:
		s.rep.noFinals("C2")
		return
	}
	matches, first := 0, -1
	for i, para := range f.FinalParas {
		if s.asksQuestion(para) {
			matches++
			if first < 0 {
				first = i
			}
		}
	}
	total := len(f.FinalParas)
	if matches == 0 {
		s.rep.emit("C2", statusPass, fmt.Sprintf("0 of %d final returns end in a question", total))
		return
	}
	s.rep.emit("C2", statusFail, fmt.Sprintf("%d of %d final returns end in a question (first @ %d)", matches, total, f.FinalEpochs[first]))
}

// asksQuestion: a `¿...?` pair anywhere in the paragraph, or a line that matches the question expression.
func (s *scorer) asksQuestion(para string) bool {
	if spanishPair.MatchString(para) {
		return true
	}
	for _, line := range strings.Split(para, "\n") {
		if s.cfg.Question.MatchString(line) {
			return true
		}
	}
	return false
}
