package scoreloop

import (
	"strings"
	"time"
)

// timestampLayouts are the ISO-8601 forms a transcript timestamp may take (GNU `date -d` read all of them). The
// unpadded fields also parse padded input, a fractional second is accepted after the seconds, and a form without a
// zone is UTC. Free text ("yesterday", a bare number, "@epoch") is not a timestamp.
var timestampLayouts = []string{
	"2006-1-2T15:4:5Z07:00", "2006-1-2T15:4:5Z0700", "2006-1-2T15:4:5Z07",
	"2006-1-2 15:4:5Z07:00", "2006-1-2 15:4:5Z0700", "2006-1-2 15:4:5Z07",
	"2006-1-2T15:4:5", "2006-1-2 15:4:5", "2006-1-2T15:4", "2006-1-2 15:4", "2006-1-2",
}

// parseTimestamp parses one timestamp; ok is false when no layout fits.
func parseTimestamp(s string) (time.Time, bool) {
	s = foldISOLetters(s)
	for _, layout := range timestampLayouts {
		if t, err := time.Parse(layout, s); err == nil {
			return t, true
		}
	}
	return time.Time{}, false
}

// foldISOLetters upper-cases the date/time separator and a trailing zone letter ("2026-06-01t00:10:00z").
func foldISOLetters(s string) string {
	if len(s) > 10 && s[10] == 't' {
		s = s[:10] + "T" + s[11:]
	}
	if strings.HasSuffix(s, "z") {
		s = s[:len(s)-1] + "Z"
	}
	return s
}
