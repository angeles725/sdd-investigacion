package show

import (
	"fmt"
	"strconv"
	"strings"
)

// ownedCounters is _OWNED_COUNTERS: the counters --sync-state may rewrite (and --only may name).
const ownedCounters = "covered_blocks gaps_closed known_gaps investigable_open requires_execution_open blocked_open deferred_open undocumented_findings"

const (
	modeStatus = "status"
	modeNext   = "--next"
	modeSync   = "--sync-state"
)

// cSpace is the [[:space:]] class of the C locale.
const cSpace = " \t\n\v\f\r"

// options is the parsed command line of research-sdd-status.sh (everything after <target-dir>).
type options struct {
	mode         string
	focus        string
	emitToken    bool
	all          bool
	queue        bool
	root         bool
	onlyList     string
	onlySet      bool
	stallMinutes int64
}

const usageFlags = "usage: research-sdd-status.sh <target-dir> [--next [--all] [--queue] [--emit-token]|--sync-state [--only <counters>]] [--focus <slug>|--root] [--stall-minutes N]"

// parseArgs is the argument loop and the cross-flag checks of the script. rest is the command line after
// <target-dir>. A non-empty usage is the message the script prints on stderr before exiting 2.
func parseArgs(rest []string) (o options, usage string) {
	o = options{mode: modeStatus, stallMinutes: 15}
	for i := 0; i < len(rest); {
		a := rest[i]
		val := "" // "${2-}": empty when the flag is last
		if i+1 < len(rest) {
			val = rest[i+1]
		}
		switch a {
		case modeNext, modeSync:
			o.mode = a
			i++
		case "--root":
			o.root = true
			i++
		case "--all":
			o.all = true
			i++
		case "--emit-token":
			o.emitToken = true
			i++
		case "--queue":
			o.queue = true
			i++
		case "--only":
			o.onlyList, o.onlySet = val, true
			if msg := checkOnly(val); msg != "" {
				return o, msg
			}
			i += 2
		case "--focus":
			o.focus = val
			if val == "" {
				return o, "usage: --focus requires a focus slug"
			}
			i += 2
		case "--stall-minutes":
			n, ok := positiveInt(val)
			if !ok {
				return o, "usage: --stall-minutes requires a positive integer"
			}
			o.stallMinutes = n
			i += 2
		default:
			return o, usageFlags
		}
	}
	return o, crossCheck(o)
}

// checkOnly validates a --only counter list the way the script does, in the same order.
func checkOnly(list string) string {
	if strings.ContainsAny(list, cSpace) {
		return "usage: --only: counter list must be comma-separated with no whitespace (e.g. --only covered_blocks,blocked_open)"
	}
	if list == "" || strings.HasPrefix(list, ",") || strings.HasSuffix(list, ",") || strings.Contains(list, ",,") {
		return "usage: --only requires a counter list, e.g. --only covered_blocks,blocked_open (no empty elements)"
	}
	known := strings.Fields(ownedCounters)
	for _, c := range strings.Split(list, ",") {
		found := false
		for _, k := range known {
			found = found || k == c
		}
		if !found {
			return fmt.Sprintf("usage: --only: unknown counter '%s' (valid: %s)", c, ownedCounters)
		}
	}
	return ""
}

// positiveInt is the --stall-minutes test: digits only and not zero. A value past int64 is rejected too, as the
// shell's integer test errors on it.
func positiveInt(s string) (int64, bool) {
	if s == "" || strings.Trim(s, "0123456789") != "" {
		return 0, false
	}
	n, err := strconv.ParseInt(s, 10, 64)
	return n, err == nil && n != 0
}

// crossCheck is the run of one-line flag-combination refusals that follows the argument loop.
func crossCheck(o options) string {
	switch {
	case o.onlySet && o.mode != modeSync:
		return "usage: --only requires --sync-state"
	case o.root && o.focus != "":
		return "usage: --root and --focus are mutually exclusive"
	case o.all && o.mode != modeNext:
		return "usage: --all requires --next"
	case o.all && (o.root || o.focus != ""):
		return "usage: --all is corpus-wide and excludes --focus/--root"
	case o.emitToken && o.mode != modeNext:
		return "usage: --emit-token requires --next"
	case o.queue && o.mode != modeNext:
		return "usage: --queue requires --next"
	}
	return ""
}
