package show

import (
	"bytes"
	"fmt"
	"path"
	"strings"
)

// The tail of the default report: the aggregate next step across every focus, and the consistency lines.

const nextPad = "  next step       : "

// nextStepLine prints the next step. A document-cycle NEXT / BOOTSTRAP is final; its STOP yields to any gap-centric
// verdict that is not itself a STOP (DOC-STOP-GUARD). dgNames lists the state files whose blocked-rows derivation
// is unreadable: the verdict is then not derived at all (NEXT-STEP-DEGRADED-GUARD).
// It reports whether the line it printed is a DEGRADED verdict, so the report can add its reason-codes footer.
func (c *ctx) nextStepLine(doc docMode, dgNames string) (degraded bool) {
	nsDoc := ""
	if doc == docOutline {
		nsDoc = c.outlineNextStep()
	}
	if strings.HasPrefix(nsDoc, "NEXT") || strings.HasPrefix(nsDoc, "BOOTSTRAP") {
		fmt.Fprintf(c.s.Out, "%s%s\n", nextPad, nsDoc)
		return false
	}
	if dgNames != "" {
		fmt.Fprintf(c.s.Out, "%sDEGRADED (blocked-rows derivation unreadable for %s — a next gap or a paused-focus count derived from it would be inflated)\n", nextPad, dgNames)
		return true
	}
	gap := c.gapRun()
	if nsDoc != "" && strings.HasPrefix(gap, "STOP") {
		gap = nsDoc
	}
	fmt.Fprintf(c.s.Out, "%s%s\n", nextPad, gap)
	return strings.HasPrefix(gap, "DEGRADED")
}

// gapRun is _ns_gap_run: the gap-centric verdict across EVERY focus (not just the picked one). A stopped or paused
// focus is skipped, but counted when it still has open gaps.
func (c *ctx) gapRun() string {
	saved := c.state
	defer func() { c.state = saved }()
	states := c.listStates()
	skipGaps := 0
	for _, st := range states {
		c.state = st
		if tok, skip := c.focusStopped(st); skip {
			slug := strings.TrimPrefix(strings.TrimSuffix(path.Base(st), ".md"), "RESEARCH-STATE-")
			fmt.Fprintf(c.s.Err, "INFO: skipped %s (focus-status: %s in FOCUSES.md)\n", slug, tok)
			if !c.readable(st) {
				fmt.Fprintf(c.s.Err, "WARN: cannot read state file %s\n", st)
			}
			q := c.quiet()
			n, rc := q.countInvestigableWith(q.blocker())
			if rc != 0 {
				return fmt.Sprintf("DEGRADED | blocked-rows read failed while counting the paused/stopped focus %s — the no-active-focus count would be inflated; fix the failure named on stderr, then re-run", c.relState(st))
			}
			if n != 0 {
				skipGaps++
			}
			continue
		}
		if r, _ := c.resolveNextWith(c.blocker()); strings.HasPrefix(r, "NEXT ") || strings.HasPrefix(r, "DEGRADED ") {
			return r
		}
	}
	c.buCompute(states) // BU-REPORT (kit #1959 S1)
	if skipGaps > 0 {
		return fmt.Sprintf("STOP | no active focus (%d declared stopped/paused in FOCUSES.md with open gaps)%s", skipGaps, c.buSuffix)
	}
	return stopExhausted + c.buSuffix
}

// consistency is `verify-state.sh "$corpus" 2>&1 | sed -n '/summary\|FAIL\|WARN\|ok /p' | sed 's/^/  /'`: the
// report lines that carry a verdict, indented. A last line without a newline stays without one, as sed leaves it.
// A verify-state that could not run (126, 127) gets a typed DEGRADED line instead of an empty block (#2736);
// the report still exits 0, as it always has.
func (c *ctx) consistency() {
	fmt.Fprintln(c.s.Out, "  --- consistency (verify-state.sh) ---")
	var buf bytes.Buffer
	s := c.s
	s.Out, s.Err = &buf, &buf
	rc := verifyState([]string{c.corpus}, s)
	if c.noteVerifyRC(rc); (rc == 126 || rc == 127) && c.verifyDown != "" {
		fmt.Fprintf(c.s.Out, "  consistency: DEGRADED — verify state could not run (%s)\n", c.verifyDown)
	}
	for _, l := range strings.SplitAfter(buf.String(), "\n") {
		for _, key := range [...]string{"summary", "FAIL", "WARN", "ok "} {
			if strings.Contains(l, key) {
				fmt.Fprint(c.s.Out, "  "+l)
				break
			}
		}
	}
}
