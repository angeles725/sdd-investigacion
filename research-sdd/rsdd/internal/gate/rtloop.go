package gate

import (
	"fmt"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/loopevidence"
)

// loopGate is RTG-LOOP-EVIDENCE (kit issues #2792, #2841): the gate holds a report to a continuation token only
// when the session transcript shows the research loop ran (core/loopevidence: a --next / --emit-token status run,
// a block or RESEARCH-STATE write inside the target, the research-sdd skill or slash command). A target that merely
// has a RESEARCH-STATE file is not enough: the kit repository is one, and a session that coordinated pull requests
// elsewhere was asked to copy a token it never earned.
//
// It reports whether the gate goes on. false always came with one typed stderr line, never a block and never a
// token offer: `branch=no-loop-session (...)` when the transcript was read and shows no loop, and a typed
// `branch=degraded (...)` when it could not be read (RTG-EVIDENCE-READ): "could not look" is never "no loop".
func (g *rtGate) loopGate(transcript, target string) bool {
	if why := transcriptUnreadable(transcript); why != "" { // RTG-TRANSCRIPT-DEGRADED
		g.degraded(why)
		return false
	}
	sc, err := loopevidence.ScanTranscript(transcript, loopevidence.Options{Target: target})
	switch {
	case err != nil: // RTG-EVIDENCE-READ
		g.degraded("loop evidence unreadable: " + strings.TrimPrefix(err.Error(), loopevidence.ErrUnreadable.Error()+": "))
		return false
	case sc.Found:
		return true
	case sc.Oversize > 0:
		g.degraded(fmt.Sprintf("loop evidence incomplete: %d transcript line(s) over %d bytes were not inspected", sc.Oversize, loopevidence.DefaultMaxLineBytes))
		return false
	case sc.Lines == 0:
		g.degraded("loop evidence absent: the transcript has no lines")
		return false
	}
	g.log("state=allow branch=no-loop-session (no loop evidence in %d transcript lines)", sc.Lines)
	return false
}

// transcriptUnreadable is the typed reason for a transcript the gate cannot open at all, "" when it can.
func transcriptUnreadable(transcript string) string {
	if transcript == "" {
		return "transcript unreadable: no transcript_path in the hook JSON"
	}
	if !readable(transcript) {
		return "transcript unreadable: " + transcript
	}
	return ""
}
