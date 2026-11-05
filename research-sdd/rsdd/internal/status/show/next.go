package show

import (
	"fmt"
	"io"
	"os"
	"path"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/kit"
)

// Port of the `--next` block of research-sdd-status.sh: the STALE gate, the RETRO-DUE check, the DEGRADED refusal
// and the NEXT / STOP verdict, scoped to the picked state file (--root / --focus) or aggregated over every state
// file. The retro-coverage derivation behind RETRO-DUE (retrodue.go) and issues_due_gate, which prints the exhausted
// STOP and may turn it into ISSUES-DUE (issuesdue.go), are reached through seams a test can replace.

// retroThreshold is the §18 cadence: more blocks than this since the last retro is RETRO-DUE.
const retroThreshold = 10

// seams are the two sections of the --next block a test may stand in for: the retro-coverage derivation behind
// RETRO-DUE and the terminal gate of an exhausted walk.
type seams struct {
	// coversDerive is _rd_covers_derive: the retro-coverage view of a counter that would fire, as the effective
	// counter and the RETRO-DUE suffix.
	coversDerive func(c *ctx, state, declared string) (eff, note string)
	// issuesGate is issues_due_gate: it prints the terminal verdict of an exhausted walk (STOP, or ISSUES-DUE).
	issuesGate func(c *ctx)
}

// liveSeams are the production sections.
var liveSeams = seams{
	coversDerive: (*ctx).coversDerive,
	issuesGate:   (*ctx).issuesDueGate,
}

// nextOr answers --next and leaves every other mode to rest.
func nextOr(sm seams, rest tail) tail {
	return func(c *ctx) int {
		if c.opts.mode == modeNext {
			return c.next(sm)
		}
		return rest(c)
	}
}

// listStateFiles is kit.ListStateFiles; a test replaces it to make the listing fail.
var listStateFiles = kit.ListStateFiles

// listable refuses a run whose state-file listing fails, instead of walking a partial list (the script ignored the
// failure; an intended divergence, tool-registry.d/research-sdd-status.md): a typed line on stderr and exit 1, the
// code the state-file pick failure uses. It answers true when the run may go on.
func (c *ctx) listable() bool {
	_, err := listStateFiles(c.abs(c.target))
	if err != nil {
		fmt.Fprintf(c.s.Err, "research-sdd-status: degraded: cannot list the state files under %s: %v\n", c.target, err)
	}
	return err == nil
}

// listStates is `mapfile -t < <(list_state_files "$target")`, shown with the target as the caller wrote it. The
// run has already passed listable.
func (c *ctx) listStates() []string {
	all, _ := listStateFiles(c.abs(c.target))
	out := make([]string, len(all))
	for i, p := range all {
		out[i] = c.show(p)
	}
	return out
}

// readable is `[ -r path ]`.
func (c *ctx) readable(p string) bool {
	f, err := os.Open(c.abs(p))
	if err != nil {
		return false
	}
	_ = f.Close()
	return true
}

// quiet is a copy of the context whose stderr is dropped: a call written `2>/dev/null`.
func (c *ctx) quiet() *ctx {
	q := *c
	q.s.Err = io.Discard
	return &q
}

// retroFires is `grep -qE '^[0-9]+$' <<<"$v" && [ "$v" -gt 10 ]`: a decimal counter past the threshold.
func retroFires(v string) bool {
	n, ok := intOf(v)
	return ok && n > retroThreshold
}

// focusStopped reports whether FOCUSES.md declares the state file stopped or paused, and the token.
func (c *ctx) focusStopped(state string) (tok string, skip bool) {
	tok = c.focusTokCached(dirname(state)+"/FOCUSES.md", path.Base(state))
	return tok, tok == "stopped" || tok == "paused"
}

// buCompute is _bu_compute: the ` [backlog-unreadable: N rows]` qualifier of the files the verdict covers. A file
// that cannot be read is NOT zero: it makes the qualifier `unverified`.
func (c *ctx) buCompute(files []string) {
	saved := c.state
	defer func() { c.state = saved }()
	total, unverified := 0, false
	for _, f := range files {
		c.state = f
		if !c.readable(f) { // BU-UNREADABLE-FILE
			unverified = true
			continue
		}
		total += c.countUncountedRows() // BU-SUM
	}
	switch {
	case unverified:
		c.buSuffix = " [backlog-unreadable: unverified]"
	case total > 0:
		c.buSuffix = fmt.Sprintf(" [backlog-unreadable: %d rows]", total)
	default:
		c.buSuffix = ""
	}
}

// next is the whole block. Every verdict path ends in exit 0 except the DEGRADED refusals (exit 3).
func (c *ctx) next(sm seams) int {
	out := c.s.Out
	pick := c.state // _ns_pick: the loops below reassign the global state
	if !c.listable() {
		return 1
	}
	if c.staleGate() {
		if c.verifyDown != "" {
			fmt.Fprintf(c.s.Err, "research-sdd-status: degraded: verify-state unavailable (%s)\n", c.verifyDown)
			return 1
		}
		return 0
	}
	scoped := c.opts.focus != "" || c.opts.root
	rdStates := []string{pick}
	if !scoped {
		rdStates = c.listStates()
	}
	for _, st := range rdStates {
		c.state = st
		if _, skip := c.focusStopped(st); skip {
			continue
		}
		bsr, _ := c.envGet("blocks_since_retro")
		note := ""
		if retroFires(bsr) { // RD-COVERS-THROUGH: only a counter that would fire is cross-checked
			bsr, note = sm.coversDerive(c, st, bsr)
		}
		if retroFires(bsr) { // RD-THRESHOLD-CHECK
			fmt.Fprintf(out, "RETRO-DUE | %s blocks since last retro (§18 threshold: %d)%s\n", bsr, retroThreshold, note)
			return 0
		}
	}
	// The NEXT-DEGRADED-GATE (_blocked_degraded_files over every file the verdict reads) has no counterpart: it fires
	// on blocked_open_count rc 3, an awk or grep that could not run, which nothing in this port can hit.
	if scoped {
		r, rc := c.resolveNextQ()
		switch {
		case r == stopExhausted:
			c.buCompute([]string{pick}) // BU-SCOPE
			sm.issuesGate(c)            // IDG-FOCUS-GATE
		case rc == 3:
			fmt.Fprintln(out, r)
			return 3
		default:
			fmt.Fprintln(out, r)
		}
		return 0
	}
	states := c.listStates()
	skipGaps := 0
	for _, st := range states {
		c.state = st
		if tok, skip := c.focusStopped(st); skip {
			fmt.Fprintf(c.s.Err, "INFO: skipped %s (focus-status: %s in FOCUSES.md)\n", strings.TrimPrefix(strings.TrimSuffix(path.Base(st), ".md"), "RESEARCH-STATE-"), tok)
			if !c.readable(st) {
				fmt.Fprintf(c.s.Err, "WARN: cannot read state file %s\n", st)
			}
			q := c.quiet()
			n, rc := q.countInvestigableWith(q.blocker())
			if rc != 0 { // COUNT-DEGRADED-EXIT
				fmt.Fprintf(out, "DEGRADED | blocked-rows read failed while counting the paused/stopped focus %s — the no-active-focus count would be inflated; fix the failure named on stderr, then re-run\n", c.relState(st))
				return 3
			}
			if n != 0 {
				skipGaps++
			}
			continue
		}
		r, rc := c.resolveNextQ()
		if strings.HasPrefix(r, "NEXT ") {
			fmt.Fprintln(out, r)
			return 0
		}
		if rc == 3 { // RESOLVE-DEGRADED-EXIT
			fmt.Fprintln(out, r)
			return 3
		}
	}
	// kit #1959 W1: the qualifier counts EVERY state file, skipped (stopped/paused) ones included.
	c.buCompute(states) // BU-WALKED
	if skipGaps > 0 {
		fmt.Fprintf(out, "STOP | no active focus (%d declared stopped/paused in FOCUSES.md with open gaps)%s\n", skipGaps, c.buSuffix)
		return 0
	}
	sm.issuesGate(c)
	return 0
}
