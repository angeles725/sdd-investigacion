package scoreloop

import "fmt"

// scorer holds the inputs every criterion reads: the transcript facts, the block commits of the window, and the
// report the criteria write to. Each criterion is one method in its own file (c1.go to c4.go).
type scorer struct {
	cfg   *Config
	opt   options
	facts *Facts
	win   *window
	rep   *report
	// blocks are the window's block commits in time order; nBlocks is their total weight.
	blocks  []blockEntry
	nBlocks int64
	// examined and tsErrors prove the instrument looked: every candidate commit git returned, and the matched
	// commits whose date did not parse.
	examined, tsErrors int
	status             statusRunner
	statusScript       string
	corpus             string
	// abort is a `git log` that failed after output began (C4's rescan): the run ends with exit 1.
	abort error
}

// unusableReason says why the transcript cannot be read ("" when it can).
func (s *scorer) unusableReason() string {
	f := s.facts
	switch {
	case !f.Given:
		return "no transcript"
	case f.MissingTool != "":
		return fmt.Sprintf("degraded: %s not found in PATH — transcript parsing unavailable", f.MissingTool)
	case f.ParseFailed:
		return "degraded: transcript did not parse cleanly as JSON"
	}
	return ""
}

// outOfSpan counts the blocks committed outside the transcript's own span: the transcript never saw them, so it
// cannot say whether an operator turn or a compaction came near them.
func (s *scorer) outOfSpan() int64 {
	if !s.facts.HasSpan {
		return 0
	}
	var n int64
	for _, b := range s.blocks {
		if b.epoch < s.facts.FirstEpoch || b.epoch > s.facts.LastEpoch {
			n += b.weight
		}
	}
	return n
}

// outOfSpanEvidence is the shared C1/C3 degraded evidence for commits outside the span.
func (s *scorer) outOfSpanEvidence(n int64, why string) string {
	return fmt.Sprintf("%d of %d block commit(s) outside transcript span [%s,%s]; %s",
		n, s.nBlocks, s.facts.FirstISO, s.facts.LastISO, why)
}
