package scoreloop

import (
	"fmt"
	"sort"
)

// c1 is "continued past block 1": at least two block commits in the window (weighted), and no operator turn
// between consecutive block commits. Without a transcript the operator-input sub-check is n/a but the count is
// still reported (git alone answers it).
func (s *scorer) c1() {
	f := s.facts
	switch {
	case f.unrecognized():
		// A shape the scorer cannot interpret is not evidence of anything, zero commits included.
		s.rep.emit("C1", statusDegraded, "unrecognized transcript shape")
	case s.nBlocks == 0:
		s.rep.emit("C1", statusFail, fmt.Sprintf("0 block commits in window (%d candidate commit(s) examined; ts-parse-errors=%d)", s.examined, s.tsErrors))
	case !f.Given:
		s.c1WithoutTranscript()
	case !f.usable():
		s.rep.emit("C1", statusDegraded, fmt.Sprintf("%d block commits in window; %s", s.nBlocks, s.unusableReason()))
	default:
		s.c1Scored()
	}
}

func (s *scorer) c1WithoutTranscript() {
	if s.nBlocks >= 2 {
		s.rep.emit("C1", statusNA, fmt.Sprintf("%d block commits in window; operator-input check n/a (no transcript)", s.nBlocks))
		return
	}
	s.rep.emit("C1", statusFail, fmt.Sprintf("only %d block commit in window (need >=2); operator-input check n/a (no transcript)", s.nBlocks))
}

func (s *scorer) c1Scored() {
	if oos := s.outOfSpan(); oos > 0 {
		s.rep.emit("C1", statusDegraded, s.outOfSpanEvidence(oos, "cannot assess operator-input gaps for them"))
		return
	}
	if s.nBlocks < 2 {
		s.rep.emit("C1", statusFail, fmt.Sprintf("only %d block commit in window (need >=2)", s.nBlocks))
		return
	}
	gaps := s.operatorGaps()
	if gaps == 0 {
		s.rep.emit("C1", statusPass, fmt.Sprintf("%d block commits, 0 operator turns between consecutive block commits", s.nBlocks))
		return
	}
	s.rep.emit("C1", statusFail, fmt.Sprintf("%d block commits but %d of %d gap(s) had operator input between them", s.nBlocks, gaps, s.nBlocks-1))
}

// operatorGaps counts the consecutive block pairs with an operator turn strictly between their commits. Blocks of
// one commit share an instant, so only the boundaries between distinct commits can hold a turn.
func (s *scorer) operatorGaps() int {
	ops := s.facts.OperatorEpochs
	gaps := 0
	for i := 0; i+1 < len(s.blocks); i++ {
		a, b := s.blocks[i].epoch, s.blocks[i+1].epoch
		next := sort.Search(len(ops), func(k int) bool { return ops[k] > a })
		if next < len(ops) && ops[next] < b {
			gaps++
		}
	}
	return gaps
}
