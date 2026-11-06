package show

import (
	"fmt"
	"path"
	"strings"
)

// Port of campaign_status_block of research-sdd-status.sh: the §8c campaign queue lines of the default report.
//
// Every active focus is evaluated, not just the alphabetically first: the focuses FOCUSES.md declares stopped or
// paused are skipped (they would mislead a multi-focus scan), except that --focus <slug> reports exactly that focus
// and never skips it. A target where no active focus has a queue collapses to ONE summary line instead of one per
// focus, and per-focus lines carry a [slug] label only when more than one focus has a queue.

// campaignLine is one `  %-16s: value` line of the block.
func (c *ctx) campaignLine(label, value string) {
	fmt.Fprintf(c.s.Out, "  %-16s: %s\n", label, value)
}

// campaignActive is the states the block evaluates and how many FOCUSES.md skipped.
func (c *ctx) campaignActive() (active []string, skipped int) {
	if c.opts.focus != "" { // B1-FOCUS-ACTIVE-ANCHOR
		return []string{c.state}, 0
	}
	for _, st := range c.listStates() {
		if _, skip := c.focusStopped(st); skip {
			skipped++
			continue
		}
		active = append(active, st)
	}
	return active, skipped
}

// campaign is the block. c.state is restored when it returns.
func (c *ctx) campaign() {
	saved := c.state
	defer func() { c.state = saved }()
	active, skipped := c.campaignActive()
	if len(active) == 0 {
		c.campaignLine("campaign", fmt.Sprintf("no active focus (%d declared stopped/paused in FOCUSES.md)", skipped))
		return
	}
	var queued []string // pass 1: which active focuses actually have a queue
	for _, st := range active {
		c.state = st
		if c.campaignQueuePresent() {
			queued = append(queued, st)
		}
	}
	if len(queued) == 0 { // W1-COLLAPSE-ANCHOR
		c.campaignNone(active)
		return
	}
	multi := len(queued) > 1
	allStopped := true
	for _, st := range queued {
		c.state = st
		allStopped = c.campaignFocus(multi) && allStopped
	}
	// Aggregate STOP: only when EVERY queue-bearing focus reached its own, counted over the queue-bearing focuses
	// (a focus without a queue was never terminal).
	if multi && allStopped {
		c.campaignLine("campaign_stop", fmt.Sprintf("STOP reached — all %d queue-bearing focuses terminal", len(queued))) // W3-WORDING-ANCHOR
	}
}

// campaignNone is the single summary line of a target with no queue, and for a single-focus corpus the
// last_iteration_ts line the report always carried.
func (c *ctx) campaignNone(active []string) {
	word := "focuses"
	if len(active) == 1 {
		word = "focus"
	}
	c.campaignLine("campaign", fmt.Sprintf("none (%d active %s, 0 with a queue)", len(active), word)) // CQ-NONE-ANCHOR
	if len(active) != 1 {
		return
	}
	c.state = active[0]
	if ts, _ := c.envGet("last_iteration_ts"); ts == "" {
		c.campaignLine("last_iteration_ts", "absent")
	} else {
		c.campaignLine("last_iteration_ts", fmt.Sprintf("%s  (age: %s min)", ts, c.campaignAgeMin(ts)))
	}
}

// campaignFocus prints the lines of the focus c.state and reports whether it reached its own STOP.
func (c *ctx) campaignFocus(multi bool) (stopped bool) {
	flabel, wlabel := "", ""
	if multi {
		slug := strings.TrimPrefix(strings.TrimSuffix(path.Base(c.state), ".md"), "RESEARCH-STATE-")
		flabel, wlabel = "["+slug+"]", " ["+slug+"]"
	}
	ts, _ := c.envGet("last_iteration_ts")
	section := c.campaignSection()
	n := c.campaignRowCounts(wlabel, section)
	c.campaignLine("campaign"+flabel, fmt.Sprintf("pending=%d active=%d done=%d bound-stopped=%d rejected=%d", n.pending, n.active, n.done, n.boundStopped, n.rejected))
	audit := sectionField(section, "last_audit")
	if audit != "" {
		c.campaignLine("last_audit"+flabel, audit)
	} else {
		c.campaignLine("last_audit"+flabel, "not yet audited")
	}
	stop := campaignStopText(n, audit, section)
	if stop != "" {
		c.campaignLine("campaign_stop"+flabel, stop)
	}
	if bounds := sectionField(section, "campaign_bounds"); bounds != "" {
		c.campaignLine("campaign_bounds"+flabel, bounds)
		c.checkBounds(wlabel, bounds)
	}
	c.campaignTimestamp(ts, flabel, wlabel, n.pending > 0 || n.active > 0)
	return stop != ""
}

// campaignTimestamp is the last_iteration_ts line with its age, and the stall WARN when this focus's campaign is
// pending or active and the age passes --stall-minutes.
func (c *ctx) campaignTimestamp(ts, flabel, wlabel string, live bool) {
	if ts == "" {
		c.campaignLine("last_iteration_ts"+flabel, "absent")
		return
	}
	age := c.campaignAgeMin(ts)
	c.campaignLine("last_iteration_ts"+flabel, fmt.Sprintf("%s  (age: %s min)", ts, age))
	if n, ok := intOf(age); ok && live && n > c.opts.stallMinutes {
		fmt.Fprintf(c.s.Err, "WARN: campaign stall%s — last_iteration_ts age %s min exceeds threshold %d min\n", wlabel, age, c.opts.stallMinutes) // CQ-STALL-WARN-ANCHOR
	}
}
