package gh

import (
	"strconv"
	"strings"
)

// DefaultKnob is the variable the bound is read from unless the caller names another (GHV_BOUND_ENV).
const DefaultKnob = "RSDD_GH_TIMEOUT"

// DefaultBound is the bound in seconds when the caller gives no default (GHV_DEFAULT_BOUND unset).
const DefaultBound = 20

// Bound is the resolved bound: Seconds is what was applied; Bad reports a knob that was set but unusable.
type Bound struct {
	Seconds int
	Bad     bool
}

// ResolveBound reads knob (DefaultKnob when "") from environ ("KEY=value" entries, the last one wins) and
// returns its value when it is a positive integer of at most 9 significant digits, leading zeros allowed.
// Unset, it returns dflt (DefaultBound when <= 0); set but unusable (empty included), dflt with Bad.
func ResolveBound(environ []string, knob string, dflt int) Bound {
	if knob == "" {
		knob = DefaultKnob
	}
	if dflt <= 0 {
		dflt = DefaultBound
	}
	v, set := lookup(environ, knob)
	if !set {
		return Bound{Seconds: dflt}
	}
	if n, ok := parseSeconds(v); ok {
		return Bound{Seconds: n}
	}
	return Bound{Seconds: dflt, Bad: true}
}

// parseSeconds accepts ASCII digits only, at most 9 of them once the leading zeros are cut, and not zero.
func parseSeconds(v string) (int, bool) {
	if v == "" || strings.Trim(v, "0123456789") != "" {
		return 0, false
	}
	v = strings.TrimLeft(v, "0")
	if v == "" || len(v) > 9 {
		return 0, false
	}
	n, err := strconv.Atoi(v)
	return n, err == nil
}

// lookup returns the value of the last key entry of environ and whether there is one.
func lookup(environ []string, key string) (string, bool) {
	for i := len(environ) - 1; i >= 0; i-- {
		if v, ok := strings.CutPrefix(environ[i], key+"="); ok {
			return v, true
		}
	}
	return "", false
}
