package sweep

import (
	"fmt"
	"regexp"
	"strconv"
	"time"
)

// defaultSweepTimeout is the per-script bound when RSDD_SWEEP_TIMEOUT is unset or empty, mirroring the 15-30 s
// timeouts of the Claude SessionStart hooks.
const defaultSweepTimeout = 30 * time.Second

// maxSweepTimeoutSeconds caps a configured timeout at one year, far below what a time.Duration holds.
const maxSweepTimeoutSeconds = 365 * 24 * 3600

// reSeconds is a plain decimal count of seconds: "30", "0.5", ".5". GNU timeout also took suffixes ("2m"),
// exponents and "inf"; the script reported them as "timed out after 2ms" or ran unbounded.
var reSeconds = regexp.MustCompile(`^([0-9]+(\.[0-9]+)?|\.[0-9]+)$`)

// sweepTimeout is the bound of one script run and the text its banner shows ("timed out after <shown>s").
type sweepTimeout struct {
	d     time.Duration
	shown string
}

// parseSweepTimeout reads RSDD_SWEEP_TIMEOUT. An empty value is the default. A value that is not a positive
// number of seconds (at most one year) is also the default, never an unbounded run, and comes with the typed
// degraded line to print: the script handed such a value to `timeout`, which failed every script with exit 125
// (or, for 0, ran each one without any bound).
func parseSweepTimeout(raw string) (sweepTimeout, string) {
	def := sweepTimeout{defaultSweepTimeout, strconv.Itoa(int(defaultSweepTimeout / time.Second))}
	if raw == "" {
		return def, ""
	}
	if reSeconds.MatchString(raw) {
		secs, err := strconv.ParseFloat(raw, 64)
		if err == nil && secs <= maxSweepTimeoutSeconds {
			if d := time.Duration(secs * float64(time.Second)); d > 0 {
				return sweepTimeout{d, strconv.FormatFloat(secs, 'f', -1, 64)}, ""
			}
		}
	}
	return def, fmt.Sprintf("sweep-all: degraded: RSDD_SWEEP_TIMEOUT %q is not a positive number of seconds (at most one year) — using %s", raw, def.shown)
}
