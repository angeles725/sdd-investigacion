package scoreloop

import (
	"math"
	"strconv"
)

// afterStop counts the blocks committed at or after the STOP moment. A block committed in the SAME second as STOP
// counts as after it (git has 1 s resolution, so it cannot be ordered before it).
//
// The default window ends at the transcript's last record, so a block committed seconds after a final STOP would
// read as "0 after STOP" (kit issue #1017); with no explicit window git is asked again with no upper bound. An
// explicit window is the operator's own choice and is respected as given. A later commit counts against the run
// only inside the grace window or the transcript span; one beyond both is unwitnessed (possibly another session's
// work): reported apart, never a fail.
func (s *scorer) afterStop(stopEpoch int64) (after, unwitnessed int64, err error) {
	entries := s.blocks
	if !s.opt.windowExplicit {
		res, err := s.win.scan("@"+strconv.FormatInt(stopEpoch, 10), "")
		if err != nil {
			return 0, 0, err
		}
		entries = res.entries
	}
	graceEnd := graceDeadline(stopEpoch, s.cfg.GraceMin)
	for _, b := range entries {
		if b.epoch < stopEpoch {
			continue
		}
		if s.opt.windowExplicit || b.epoch <= graceEnd || b.epoch <= s.facts.LastEpoch {
			after += b.weight
		} else {
			unwitnessed += b.weight
		}
	}
	return after, unwitnessed, nil
}

// graceDeadline is stop + minutes*60 seconds, saturating at the int64 maximum.
func graceDeadline(stop, minutes int64) int64 {
	if minutes > (math.MaxInt64-stop)/60 {
		return math.MaxInt64
	}
	return stop + minutes*60
}
