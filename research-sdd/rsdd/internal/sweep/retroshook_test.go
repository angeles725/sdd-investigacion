package sweep

import (
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"unicode/utf8"
)

// The hook of `sweep retros --hook`. Guard-to-test table (each guard was mutated by hand once: the mutant of the
// guard turns the named test red):
//
//	rc != 0 selects the failure header and skips the filter        TestHookContextFailure
//	failure wording "retro sweep could not run" (singular)         TestHookContextFailure
//	the absent-input aggregate points at --full                    TestSummaryFilterAbsentCollapse
//	per-target absent lines are dropped in summary mode            TestSummaryFilterAbsentCollapse
//	at most five PENDING blocks, the rest counted                  TestSummaryFilterLimit
//	Summary: line byte-identical in both modes                     TestSummaryLineIdentical
//	WARN / MISSING-RETRO / waived dropped in summary mode only     TestSummaryFilterDropsFindings
//	a hook never fails the session (exit 0 on a failed sweep)      TestHookCommandAlwaysExitsZero
//	the decoded additionalContext stays under 8,000 characters     TestHookBudget

// sweepOut is what the old suite's stub printed: absent targets, n PENDING blocks, the Summary and the aggregate.
func sweepOut(n int) string {
	var b strings.Builder
	b.WriteString("INFO: corpus not found (absent-input): /targets/absent-a\nINFO: corpus not found (absent-input): /targets/absent-b\n")
	for i := 1; i <= n; i++ {
		fmt.Fprintf(&b, "PENDING  /targets/t/retros/retro%d.md\n         target: /targets/t  ·  ~%d proposed deltas  ·  status: pending  ·  age: %dd\n", i, i, i)
	}
	fmt.Fprintf(&b, "\nSummary: %d pending / %d retros across targets.\n", n, n+3)
	b.WriteString("INFO: 2 target(s) not traversed (absent-input) — corpus directory not found; see INFO lines above.\n")
	return strings.TrimRight(b.String(), "\n")
}

func TestHookContextFailure(t *testing.T) {
	out := "sweep-retros: cannot find /k/TARGETS.md"
	got := hookContext(out, 1, false)
	want := "Research-SDD retro sweep could not run (exit 1 — check TARGETS.md and lib/ helper):\n" + out
	if got != want {
		t.Errorf("got %q\nwant %q", got, want)
	}
	if strings.Contains(got, "retros sweep") || strings.Contains(got, "(supervisor project)") {
		t.Errorf("the failure banner must keep its own wording: %q", got)
	}
	// A failed sweep is reported unfiltered, whatever the mode: its lines are the diagnosis.
	if g := hookContext("WARN: x", 2, false); g != "Research-SDD retro sweep could not run (exit 2 — check TARGETS.md and lib/ helper):\nWARN: x" {
		t.Errorf("failure output was filtered: %q", g)
	}
	if g := hookContext("a", 0, true); g != "Research-SDD retro sweep (supervisor project):\na" {
		t.Errorf("success header: %q", g)
	}
}

func TestSummaryFilterAbsentCollapse(t *testing.T) {
	got := summaryFilter(sweepOut(0))
	if strings.Contains(got, "corpus not found") {
		t.Errorf("a per-target absent line survived: %q", got)
	}
	if !strings.Contains(got, "INFO: 2 target(s) not traversed (absent-input) — corpus directory not found; run --full to list them.\n") {
		t.Errorf("collapse line missing or not pointing at --full: %q", got)
	}
	if strings.Contains(got, "see INFO lines above") {
		t.Errorf("the pointer to the dropped INFO lines survived: %q", got)
	}
	if !strings.Contains(got, "Summary: 0 pending / 3 retros across targets.\n") {
		t.Errorf("no clean-run Summary: %q", got)
	}
	// awk's sub() replaces the first match only.
	two := "INFO: 1 target(s) not traversed (absent-input) see INFO lines above. see INFO lines above."
	if g := summaryFilter(two); g != "INFO: 1 target(s) not traversed (absent-input) run --full to list them. see INFO lines above.\n" {
		t.Errorf("sub() replaced more than the first match: %q", g)
	}
}

func TestSummaryFilterLimit(t *testing.T) {
	got := summaryFilter(sweepOut(8))
	if n := strings.Count(got, "\nPENDING  ") + strings.Count(got[:9], "PENDING  "); n != 5 {
		t.Errorf("%d PENDING blocks shown, want 5\n%s", n, got)
	}
	if !strings.Contains(got, "retro5.md") || strings.Contains(got, "retro6.md") {
		t.Errorf("the OLDEST five must be shown (the sweep sorts oldest first)\n%s", got)
	}
	if strings.Count(got, "         target: ") != 5 {
		t.Errorf("continuation lines of dropped blocks leaked\n%s", got)
	}
	if !strings.Contains(got, "… and 3 more — run sweep-retros.sh --full\nSummary: 8 pending / 11 retros across targets.\n") {
		t.Errorf("the 'N more' line must precede the Summary:\n%s", got)
	}
	// Exactly five: no 'more' line.
	if g := summaryFilter(sweepOut(5)); strings.Contains(g, "more") {
		t.Errorf("a 'more' line with nothing hidden: %q", g)
	}
}

func TestSummaryLineIdentical(t *testing.T) {
	out := sweepOut(7)
	pick := func(s string) string {
		for _, l := range strings.Split(s, "\n") {
			if strings.HasPrefix(l, "Summary:") {
				return l
			}
		}
		return ""
	}
	summ, full := pick(hookContext(out, 0, false)), pick(hookContext(out, 0, true))
	if summ == "" || summ != full {
		t.Errorf("Summary: lines differ: summary=%q full=%q", summ, full)
	}
	if hookContext(out, 0, true) != hookHeader+"\n"+out {
		t.Errorf("--full must pass the sweep output through unchanged")
	}
}

func TestSummaryFilterDropsFindings(t *testing.T) {
	in := "WARN: no review-status marker in a.md — add\nPENDING  /t/retros/a.md\n         target: /t  ·  ~1 proposed deltas  ·  status: none  ·  age: 0d\n         WARN: delta note\n" +
		"\nSummary: 1 pending / 1 retros across targets.\nMISSING-RETRO: /t advanced with no retro for the latest run\nwaived: 1 target(s) — MISSING-RETRO suppressed: /w\n" +
		"WARN: retro-gate not wired in /t/.claude/settings.json\nWiring: 0 wired / 0 wired-off-root / 1 unwired / 0 absent-settings / 0 unreadable — 1 targets checked."
	got := summaryFilter(in)
	want := "PENDING  /t/retros/a.md\n         target: /t  ·  ~1 proposed deltas  ·  status: none  ·  age: 0d\n         WARN: delta note\n\nSummary: 1 pending / 1 retros across targets.\n" +
		"Wiring: 0 wired / 0 wired-off-root / 1 unwired / 0 absent-settings / 0 unreadable — 1 targets checked.\n"
	if got != want {
		t.Errorf("got %q\nwant %q", got, want)
	}
}

func TestHookCommandAlwaysExitsZero(t *testing.T) {
	w := newWorld(t) // no TARGETS.md: the sweep fails with exit 1
	r := w.runHook()
	if r.rc != 0 || r.err != "" {
		t.Fatalf("a hook never fails the session: rc=%d stderr=%q", r.rc, r.err)
	}
	ctx := decodeContext(t, r.out)
	want := "Research-SDD retro sweep could not run (exit 1 — check TARGETS.md and lib/ helper):\nsweep-retros: cannot find " + w.kit + "/TARGETS.md"
	if ctx != want {
		t.Errorf("context %q\nwant %q", ctx, want)
	}
}

// decodeContext checks the envelope is the SessionStart JSON contract and returns its additionalContext.
func decodeContext(t *testing.T, stdout string) string {
	t.Helper()
	var v struct {
		H struct {
			Event string `json:"hookEventName"`
			Ctx   string `json:"additionalContext"`
		} `json:"hookSpecificOutput"`
	}
	if err := json.Unmarshal([]byte(stdout), &v); err != nil || v.H.Event != "SessionStart" {
		t.Fatalf("not a SessionStart envelope (%v): %q", err, stdout)
	}
	return v.H.Ctx
}

func TestHookEnvelopeBytes(t *testing.T) {
	w := newWorld(t)
	a := w.tgt("targetA")
	w.retro(a, "r1.md", pendingMarker, 2)
	w.wire(a)
	w.targets(a)
	r := w.runHook()
	want := "{\n  \"hookSpecificOutput\": {\n    \"hookEventName\": \"SessionStart\",\n    \"additionalContext\": \"Research-SDD retro sweep (supervisor project):\\n" +
		"PENDING  " + a + "/retros/r1.md\\n         target: " + a + "  ·  ~2 proposed deltas  ·  status: pending  ·  age: 0d\\n\\n" +
		"Summary: 1 pending / 1 retros across targets.\\n" +
		"For each PENDING retro: review it, apply or dismiss its deltas in the kit,\\nthen set the top marker to '<!-- review-status: applied <date> · kit <sha> -->'.\\n" +
		"Note: the count above tracks the review-status MARKER, not whether each delta is open work.\\n" +
		"A kit commit may have applied a delta without flipping the marker — an ESCALATED retro is worth\\nverifying against the kit before treating its full delta count as unresolved.\\n" +
		"Wiring: 1 wired / 0 wired-off-root / 0 unwired / 0 absent-settings / 0 unreadable — 1 targets checked.\"\n  }\n}\n"
	if r.out != want || r.rc != 0 {
		t.Errorf("rc=%d\n got %q\nwant %q", r.rc, r.out, want)
	}
}

// TestHookBudget is the SessionStart character budget (openspec/specs/kit-session-cost/spec.md: under 8,000
// characters of decoded additionalContext): a fleet of 17 targets with 60 pending retros is capped by the
// five-block summary, and a full-mode run is NOT capped (documented: --full is the operator's explicit ask).
func TestHookBudget(t *testing.T) {
	w := newWorld(t)
	var tg []string
	for i := 0; i < 17; i++ {
		d := w.tgt(fmt.Sprintf("target%02d", i))
		for j := 0; j < 4; j++ {
			w.retro(d, fmt.Sprintf("r%d.md", j), "", 3)
		}
		w.wire(d)
		tg = append(tg, d)
	}
	for i := 0; i < 5; i++ {
		tg = append(tg, fmt.Sprintf("%s/absent-target-with-a-long-name-%d", w.root, i))
	}
	w.targets(tg...)
	r := w.runHook()
	n := utf8.RuneCountInString(decodeContext(t, r.out))
	if n >= 8000 {
		t.Errorf("summary-mode context is %d characters, the budget is under 8,000", n)
	}
	full := utf8.RuneCountInString(decodeContext(t, w.runHook("--full").out))
	if full <= n {
		t.Errorf("--full (%d) should not be shorter than the summary (%d)", full, n)
	}
	t.Logf("decoded additionalContext: summary %d characters, --full %d characters (68 pending retros, 22 targets)", n, full)
}
