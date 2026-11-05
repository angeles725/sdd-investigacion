package stageissues

import (
	"strings"
	"testing"
)

// trackerLimitCases are tracker lookups whose reply is exactly as long as the --limit cap but holds a hit: a hit
// proves the lookup answered, so it must not read as a possibly truncated result (kit issue #2592).
func trackerLimitCases() []dcase {
	apply := []string{"--apply"}
	return []dcase{
		trackerRetro("teeth/tracker-sigs-full-but-hit", apply...).withEnv("STAGE_RETRO_ISSUES_LIST_LIMIT", "1").
			seed(map[string]string{"trkset": "[" + trk("50", "OPEN") + "]\n"}),
		trackerRetro("teeth/tracker-sig-full-but-hit", apply...).withEnv("STAGE_RETRO_ISSUES_LIST_LIMIT", "1").
			seed(map[string]string{"trksig": `[{"state":"CLOSED","body":"x\nUnclassifiable item set: 2093460367\ny"}]` + "\n"}),
	}
}

func TestTrackerLookupHitIsNotTruncation(t *testing.T) {
	want := map[string]string{
		"teeth/tracker-sigs-full-but-hit": "occurrence-commented: #50",
		"teeth/tracker-sig-full-but-hit":  "skipped-duplicate: tracking issue for Unclassifiable tracker",
	}
	for _, c := range trackerLimitCases() {
		t.Run(c.name, func(t *testing.T) {
			r := runGoCase(t, c)
			if strings.Contains(r.Stderr, "the --limit cap") {
				t.Errorf("a lookup with a hit was refused as truncated:\n%s", r.Stderr)
			}
			if w := want[c.name]; !strings.Contains(r.Stdout+r.Stderr, w) {
				t.Errorf("expected %q:\nstdout:\n%s\nstderr:\n%s", w, r.Stdout, r.Stderr)
			}
		})
	}
}
