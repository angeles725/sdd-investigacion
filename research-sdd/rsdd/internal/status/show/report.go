package show

import (
	"fmt"
	"path"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/hookwiring"
)

// Port of the default report of research-sdd-status.sh (lines 2456-2642 of the frozen script). It prints the figures
// of the picked state file, the contradictions ledger, saturation, the campaign block, the remote-visibility
// block and the aggregate next step, then the consistency lines of verify-state, and always exits 0: a stale-mirror
// FAIL is REPORTED in the consistency lines and never becomes our exit code.
//
// Declared differences from the script (tool-registry.d/research-sdd-status.md):
//   - a state-file listing that fails refuses the run before any output (exit 1), as --next does;
//   - blocked_open_count rc 3 (an awk or grep that could not run) has no counterpart, so the per-file degraded
//     probe only ever names the head state, and only for rc 2;
//   - awk's own diagnostics for an unreadable ledger or state file are not reproduced;
//   - verify-state that cannot be started prints no consistency lines (the shell's error text went through the
//     same filter and never matched it).

func (c *ctx) report() int {
	if !c.listable() {
		return 1
	}
	out := c.s.Out
	doc := c.docModeOf()
	rel := strings.TrimPrefix(strings.TrimPrefix(c.corpus, c.target), "/")
	if rel == "" {
		rel = "(flat)"
	}
	metric := orDefault(c.covRatioOf(), "<none>")
	covered := orDefault(c.coveredBlocks(), "<none>")
	ondisk := c.onDisk()
	inv := orDefault(c.invCount(), "?")
	req := orDefault(c.reqProse(), "?")
	blkN, blkRC := c.blockedOpen()
	blk := fmt.Sprint(blkN)
	if blkRC != 0 { // BO-DEGRADED-DISPLAY (#2017): a failed derivation is shown as DEGRADED, never as a count
		blk, inv = "DEGRADED", "DEGRADED"
		fmt.Fprintf(c.s.Err, "research-sdd-status: blocked_open derivation degraded (blocked_open_count rc %d on %s)\n", blkRC, c.state)
	}
	ph := c.pendingByPriority()
	degraded := false // _RC_DEGRADED_PRINTED

	fmt.Fprintf(out, "== research-sdd-status: %s  ·  corpus: %s ==\n", path.Base(c.target), rel)
	if blkRC != 0 {
		degraded = true
		fmt.Fprintf(out, "degraded: blocked_open: blocked_open_count rc %d — blocked/investigable/next step not derived (CLAUDE.md §7: not a zero)\n", blkRC)
	}
	fmt.Fprintf(out, "  Stop hook       : %s (checked: %s)\n", hookwiring.WiringState(hookwiring.EnvFrom(c.s), c.target), path.Clean(c.abs(c.target)))
	fmt.Fprintf(out, "  coverage metric : %s\n", metric)
	fmt.Fprintf(out, "  covered blocks  : %s claimed · %d on disk\n", covered, ondisk)
	fmt.Fprintf(out, "  pending backlog : %s\n", ph)
	fmt.Fprintf(out, "  stop-control    : investigable=%s · requires-execution=%s · blocked=%s\n", inv, req, blk)
	if n := c.countRetyped(); n > 0 { // RETYPED-VISIBLE (#1638)
		fmt.Fprintf(out, "  re-typed in table : %d — row(s) carry the literal 're-typed' Status — use 'blocked (requires-<what>)' (METHODOLOGY §8b); counted in no bucket\n", n)
	}
	switch doc {
	case docOutline:
		fmt.Fprintln(out, c.outlineLine())
	case docNoHeading:
		fmt.Fprintln(out, "  outline         : (no ## Outline section — gap-centric verdicts kept)")
	}
	c.contradictionsLine()
	if doc == docOutline { // DOC-SAT-BRANCH
		fmt.Fprintln(out, "  saturation      : n/a (method: document-cycle — gap saturation does not apply; the ## Outline decides)")
	} else {
		fmt.Fprintln(out, c.saturationLine())
	}
	c.campaign()
	// DISPLAY-DEGRADED-GATE (kit #2024): every state file the walk reads must be readable. Only the head state can
	// degrade here (see the declared differences above).
	dgNames := ""
	if blkRC != 0 {
		dgNames = c.relState(c.state)
		degraded = true // RC-FLAG-NONHEAD
	}
	degraded = c.remoteVisibility() || degraded
	if degraded { // RC-FOOTER
		fmt.Fprintf(out, "  reason codes    : each typed degraded state in this report (remote-visibility, blocked_open, blocked-rows next step) has one continuation in %s/reason-codes.v1.md\n", c.toolbeltDir())
	}
	c.nextStepLine(doc, dgNames)
	c.consistency()
	return 0
}

// contradictionsLine is the contradictions line (and its WARN) of the report.
func (c *ctx) contradictionsLine() {
	ledgers := c.contraLedgers()
	if len(ledgers) == 0 {
		fmt.Fprintln(c.s.Out, "  contradictions  : (no ledger)")
		return
	}
	if len(ledgers) > 1 {
		fmt.Fprintf(c.s.Err, "WARN: multiple CONTRADICTIONS*.md ledgers under %s — counting all %d\n", c.corpus, len(ledgers))
	}
	if n := c.countOpenContra(ledgers); n > 0 {
		fmt.Fprintf(c.s.Out, "  contradictions  : %d open\n", n)
	} else {
		fmt.Fprintln(c.s.Out, "  contradictions  : (none)")
	}
}
