package show

import (
	"fmt"
	"strconv"
	"time"
)

// _campaign_age_min of research-sdd-status.sh: the age of last_iteration_ts in whole minutes.
//
// Declared difference from the script: `date -d` accepted any phrase GNU date understands ("yesterday", "10:00",
// "@123", a bare "now"), so a mistyped field could silently become an age. The port reads the ISO-8601 forms the
// kit writes (a date, or a date and time with an optional fraction and a Z or numeric offset) and answers
// `unknown` for the rest. A timestamp without a zone is local time, as date's is.

// nowEpochHook is the test hook of the script: a fixed "now" in epoch seconds.
const nowEpochHook = "_RSDD_NOW_EPOCH"

var zonedLayouts = []string{
	"2006-01-02T15:04:05Z07:00", "2006-01-02T15:04:05.999999999Z07:00",
	"2006-01-02T15:04:05-0700", "2006-01-02T15:04:05.999999999-0700",
	"2006-01-02T15:04Z07:00", "2006-01-02T15:04-0700",
}

var localLayouts = []string{"2006-01-02T15:04:05", "2006-01-02T15:04", "2006-01-02"}

// parseISO is the epoch of ts, or false when it is not one of the accepted forms.
func parseISO(ts string) (int64, bool) {
	for _, l := range zonedLayouts {
		if t, err := time.Parse(l, ts); err == nil {
			return t.Unix(), true
		}
	}
	for _, l := range localLayouts {
		if t, err := time.ParseInLocation(l, ts, time.Local); err == nil {
			return t.Unix(), true
		}
	}
	return 0, false
}

// campaignAgeMin prints the age in minutes, or "unknown" for a timestamp it cannot read or one in the future (the
// latter with a WARN: a silent negative would look like "no stall").
func (c *ctx) campaignAgeMin(ts string) string {
	at, ok := parseISO(ts)
	if !ok {
		return "unknown"
	}
	now := c.s.Clock().Unix()
	if v := c.s.Env(nowEpochHook); v != "" {
		if n, err := strconv.ParseInt(v, 10, 64); err == nil {
			now = n
		}
	}
	age := (now - at) / 60
	if age < 0 { // CQ-NEG-AGE-ANCHOR
		fmt.Fprintf(c.s.Err, "WARN: campaign: last_iteration_ts %s is in the future relative to now (age %d min) — reporting unknown\n", ts, age)
		return "unknown"
	}
	return strconv.FormatInt(age, 10)
}
