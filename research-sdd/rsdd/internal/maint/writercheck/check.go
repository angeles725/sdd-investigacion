package writercheck

import "strings"

// check is the default mode: the requirement the change creates, the teeth evidence for each required suite, the
// waivers, and the name-kill scan, reported as text or JSON. Findings are in the order they were raised: no-suite,
// bad-waiver, teeth, name-kill.
func (c *ctx) check(r rangeSpec, d diffSet, header, script string) int {
	imp, why := c.runImpact(script, r)
	if why != "" {
		return degrade(c.s, why)
	}
	q := c.require(r, d.changes, imp)
	w := c.loadWaivers(r)
	res := result{suites: q.suites, notes: q.notes, full: imp.fullReason != ""}
	res.findings = append(append(res.findings, q.findings...), w.findings...)
	for _, s := range q.suites {
		if !strings.HasSuffix(s, ".test.sh") { // a node suite takes no --prove-teeth
			res.notes = append(res.notes, "teeth-na "+s)
			continue
		}
		if why, waived := w.reasons[s]; waived {
			res.notes = append(res.notes, "teeth-waived "+s+" ("+why+")")
			continue
		}
		if kind, why := checkLog(c.o.logDir, s, header); kind != "" {
			res.findings = append(res.findings, finding{kind, s, why})
		}
	}
	res.findings = append(res.findings, scanNameKills(d.added)...)
	if c.o.format == "json" {
		writeJSON(c.s.Out, res)
	} else {
		writeReport(c.s.Out, res)
	}
	if len(res.findings) > 0 {
		return exitFindings
	}
	return exitOK
}
