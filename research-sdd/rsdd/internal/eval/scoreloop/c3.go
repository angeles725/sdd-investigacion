package scoreloop

import "fmt"

// c3 is compaction: the block commits before and after the first structural compaction event. NO compaction found
// is the best outcome (nothing to survive) and reports pass, not n/a.
func (s *scorer) c3() {
	f := s.facts
	switch {
	case !f.Given:
		s.rep.emit("C3", statusNA, "no transcript")
		return
	case !f.usable():
		s.rep.emit("C3", statusDegraded, s.unusableReason())
		return
	case f.unrecognized():
		s.rep.emit("C3", statusDegraded, "unrecognized transcript shape")
		return
	}
	if oos := s.outOfSpan(); oos > 0 {
		s.rep.emit("C3", statusDegraded, s.outOfSpanEvidence(oos, "cannot assess compaction timing for them"))
		return
	}
	if !f.HasCompaction {
		s.rep.emit("C3", statusPass, fmt.Sprintf("no compaction, %d block(s)", s.nBlocks))
		return
	}
	var before, after int64
	for _, b := range s.blocks {
		if b.epoch < f.FirstCompaction {
			before += b.weight
		} else {
			after += b.weight
		}
	}
	if after > 0 {
		s.rep.emit("C3", statusPass, fmt.Sprintf("compaction detected; %d block commit(s) before, %d after", before, after))
		return
	}
	s.rep.emit("C3", statusFail, fmt.Sprintf("compaction detected; %d block commit(s) before, 0 after (no continuation past compaction)", before))
}
