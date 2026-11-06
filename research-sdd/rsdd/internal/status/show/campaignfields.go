package show

import (
	"fmt"
	"regexp"
	"strings"
)

// The key: value fields of the campaign section (last_audit, campaign_stop, campaign_bounds) and the checks the
// block makes on them.

// sectionField is `grep -m1 '^<key>:' <<<section | sed 's/^<key>:[[:space:]]*//'`: the first line starting with the
// key, with the key and the blanks after it removed.
func sectionField(section, key string) string {
	for _, line := range splitLines(section) {
		if rest, ok := strings.CutPrefix(line, key+":"); ok {
			return strings.TrimLeft(rest, cSpace)
		}
	}
	return ""
}

var enqueued = regexp.MustCompile(`enqueued=[0-9]+`)

// campaignStopText is _campaign_stop_text: an explicit campaign_stop: field, or the computed STOP condition (every
// entry terminal and last_audit carrying enqueued=0 exactly once; an absent last_audit never satisfies it). "" when
// neither applies.
func campaignStopText(c campaignCounts, lastAudit, section string) string {
	if f := sectionField(section, "campaign_stop"); f != "" {
		return f
	}
	if c.pending == 0 && c.active == 0 && lastAudit != "" {
		if m := enqueued.FindAllString(lastAudit, -1); len(m) == 1 && strings.TrimPrefix(m[0], "enqueued=") == "0" {
			return "STOP reached — all entries terminal, last_audit enqueued=0"
		}
	}
	return ""
}

var wallClock = regexp.MustCompile(`^[0-9]+(\.[0-9]+)?h$`)

// checkBounds validates each key=value token of a campaign_bounds field, one WARN per bad one.
func (c *ctx) checkBounds(wlabel, field string) {
	for _, tok := range strings.Split(field, " ") {
		if tok == "" {
			continue
		}
		key, val, found := strings.Cut(tok, "=")
		if !found { // cut -d= -f2- prints a line without the delimiter whole
			val = tok
		}
		switch key {
		case "max-depth", "iterations":
			if !isDigits(val) {
				fmt.Fprintf(c.s.Err, "WARN: campaign_bounds%s: bad %s value '%s'\n", wlabel, key, val)
			}
		case "wall-clock":
			if !wallClock.MatchString(val) {
				fmt.Fprintf(c.s.Err, "WARN: campaign_bounds%s: bad wall-clock value '%s'\n", wlabel, val)
			}
		default:
			fmt.Fprintf(c.s.Err, "WARN: campaign_bounds%s: unknown key '%s'\n", wlabel, key)
		}
	}
}

// isDigits is `grep -qE '^[0-9]+$'`.
func isDigits(s string) bool { return s != "" && strings.Trim(s, "0123456789") == "" }
