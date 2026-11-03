package sweep

import (
	"encoding/json"
	"strings"
	"testing"
)

// The hook of `sweep audits --hook`. Cases of the pre-port sweep-audits-hook.test.sh and where they live now:
// 1-2 (the hook exists, is executable) are the shim suite; 3 TestAuditsHookContextFailure; 4
// TestAuditsHookContextHeader; 5 TestAuditsSummaryFilterAbsentCollapse; 6 TestAuditsHookFullIsUnfiltered; 7
// TestAuditsSummaryFilterEmptyCollapse; 8 TestAuditsHookFullIsUnfiltered; 9 TestAuditsSummaryFilterEmptyCollapse
// (single); 10 TestAuditsSummaryFilterEmptyCollapse (early and late). The five hand mutants of its --prove-teeth
// (rc check, absent print, --full guard, empty count, empty emit) are the cases named in the table of
// audits_unit_test.go.

const (
	stubAbsent = "INFO: corpus not found (absent-input): /fake/path1\nINFO: corpus not found (absent-input): /fake/path2\n" +
		"INFO: corpus not found (absent-input): /fake/path3\n\nSummary: 0 pending / 0 audits across targets.\n" +
		"INFO: 3 target(s) not traversed (absent-input) — corpus directory not found; see INFO lines above.\nNothing to review."
	stubEmpty = "INFO: corpus exists, no audits found (empty-input): /fake/empty1\nINFO: corpus exists, no audits found (empty-input): /fake/empty2\n" +
		"INFO: corpus exists, no audits found (empty-input): /fake/empty3\n\nSummary: 0 pending / 0 audits across targets.\nNothing to review."
)

func TestAuditsHookContextFailure(t *testing.T) {
	out := "sweep-audits: cannot find /k/TARGETS.md"
	got := auditsHookContext(out, 1, false)
	want := "Research-SDD audits sweep could not run (exit 1 — check TARGETS.md and lib/ helper):\n" + out
	if got != want {
		t.Errorf("got %q\nwant %q", got, want)
	}
	// A failed sweep is reported unfiltered, whatever the mode: its lines are the diagnosis.
	if g := auditsHookContext(stubAbsent, 2, false); g != "Research-SDD audits sweep could not run (exit 2 — check TARGETS.md and lib/ helper):\n"+stubAbsent {
		t.Errorf("failure output was filtered: %q", g)
	}
	if g := auditsHookContext(out, 1, true); !strings.HasPrefix(g, "Research-SDD audits sweep could not run (exit 1") {
		t.Errorf("--full does not turn the failure banner into the success one: %q", g)
	}
}

func TestAuditsHookContextHeader(t *testing.T) {
	if g := auditsHookContext("a", 0, true); g != "Research-SDD pending audits (per-target §13):\na" {
		t.Errorf("success header: %q", g)
	}
	if g := auditsHookContext("a\n\n", 0, false); g != "Research-SDD pending audits (per-target §13):\na" {
		t.Errorf("the filtered output is trimmed: %q", g)
	}
	if g := auditsHookContext("", 0, false); g != "Research-SDD pending audits (per-target §13):\n" {
		t.Errorf("an empty sweep output: %q", g)
	}
}

func TestAuditsSummaryFilterAbsentCollapse(t *testing.T) {
	got := auditsSummaryFilter(stubAbsent)
	if strings.Contains(got, "corpus not found") {
		t.Errorf("a per-target absent line survived: %q", got)
	}
	if !strings.Contains(got, "INFO: 3 target(s) not traversed (absent-input) — corpus directory not found; run --full to list them.\n") {
		t.Errorf("the aggregate line does not point at --full: %q", got)
	}
	if strings.Contains(got, "see INFO lines above") {
		t.Errorf("the pointer to lines that are gone survived: %q", got)
	}
	if !strings.Contains(got, "\nSummary: 0 pending / 0 audits across targets.\n") || !strings.HasSuffix(got, "Nothing to review.\n") {
		t.Errorf("the other lines must pass through: %q", got)
	}
	// the pointer is replaced once, with or without its trailing dot
	if g := auditsSummaryFilter("INFO: 1 target(s) not traversed (absent-input) — see INFO lines above"); g != "INFO: 1 target(s) not traversed (absent-input) — run --full to list them.\n" {
		t.Errorf("no trailing dot: %q", g)
	}
	if g := auditsSummaryFilter("INFO: 1 target(s) not traversed (absent-input) — x"); g != "INFO: 1 target(s) not traversed (absent-input) — x\n" {
		t.Errorf("an aggregate line without the pointer is kept as it is: %q", g)
	}
}

func TestAuditsSummaryFilterEmptyCollapse(t *testing.T) {
	got := auditsSummaryFilter(stubEmpty)
	if strings.Contains(got, "corpus exists, no audits found") {
		t.Errorf("a per-target empty-input line survived: %q", got)
	}
	if want := "\nSummary: 0 pending / 0 audits across targets.\nNothing to review.\nINFO: 3 corpus(es) empty-input — run --full to list them\n"; !strings.HasSuffix(got, want) {
		t.Errorf("the count goes after everything else:\n%q", got)
	}
	single := auditsSummaryFilter("INFO: corpus exists, no audits found (empty-input): /fake/only\n\nSummary: 0 pending / 0 audits across targets.\nNothing to review.")
	if !strings.Contains(single, "INFO: 1 corpus(es) empty-input — run --full to list them\n") {
		t.Errorf("a single empty-input target: %q", single)
	}
	// ordering: one before and one after the absent aggregate line; the TOTAL is emitted once, at the end
	mixed := "INFO: corpus not found (absent-input): /fake/absent1\nINFO: corpus exists, no audits found (empty-input): /fake/early\n\n" +
		"Summary: 0 pending / 0 audits across targets.\nINFO: 1 target(s) not traversed (absent-input) — corpus directory not found; see INFO lines above.\n" +
		"INFO: corpus exists, no audits found (empty-input): /fake/late\nNothing to review."
	got = auditsSummaryFilter(mixed)
	if strings.Count(got, "corpus(es) empty-input") != 1 || !strings.HasSuffix(got, "INFO: 2 corpus(es) empty-input — run --full to list them\n") {
		t.Errorf("early and late empty-input lines must add up to one summary of 2:\n%q", got)
	}
	// no empty-input line, no summary line (the anti-silent-zero count is never printed as 0)
	if g := auditsSummaryFilter(stubAbsent); strings.Contains(g, "empty-input") {
		t.Errorf("no empty-input target, no empty-input line: %q", g)
	}
	// a line that merely mentions the phrase in the middle is not a per-target line
	if g := auditsSummaryFilter("see: INFO: corpus exists, no audits found (empty-input): x"); !strings.Contains(g, "see: INFO") || strings.Contains(g, "corpus(es)") {
		t.Errorf("only lines that open with the phrase are collapsed: %q", g)
	}
	if g := auditsSummaryFilter("see: INFO: corpus not found (absent-input): x"); !strings.Contains(g, "see: INFO") {
		t.Errorf("only lines that open with the phrase are dropped: %q", g)
	}
}

func TestAuditsSummaryFilterKeepsPendingBlocks(t *testing.T) {
	in := "PENDING  /t/audits/a.md\n         target: /t  ·  ~2 audited claims  ·  status: none  ·  age: 1d\n\nSummary: 1 pending / 1 audits across targets.\nWARN: 1 target(s) skipped — x\nFor each PENDING audit: y"
	if got := auditsSummaryFilter(in); got != in+"\n" {
		t.Errorf("pending blocks, WARN and the guidance are never filtered:\n%q", got)
	}
}

// hookCtx is the additionalContext of a hook run, decoded.
func hookCtx(t *testing.T, out string) string {
	t.Helper()
	var env struct {
		H struct {
			Event string `json:"hookEventName"`
			Ctx   string `json:"additionalContext"`
		} `json:"hookSpecificOutput"`
	}
	if err := json.Unmarshal([]byte(out), &env); err != nil {
		t.Fatalf("the hook printed no JSON envelope: %v\n%s", err, out)
	}
	if env.H.Event != "SessionStart" {
		t.Errorf("hookEventName = %q", env.H.Event)
	}
	return env.H.Ctx
}

func TestAuditsHookFullIsUnfiltered(t *testing.T) {
	w := newWorld(t)
	a, e := w.tgt("targetA"), w.tgt("emptyCorpus")
	w.audit(a, "a1.md", auditPending, 2)
	w.targets(a, e, w.root+"/gone1", w.root+"/gone2")
	full := hookCtx(t, w.runAuditsHook("--full").out)
	def := hookCtx(t, w.runAuditsHook().out)
	sweep := w.runAudits().out
	if full != "Research-SDD pending audits (per-target §13):\n"+strings.TrimRight(sweep, "\n") {
		t.Errorf("--full is the sweep output unchanged:\n%s\nsweep:\n%s", full, sweep)
	}
	for _, line := range []string{"corpus not found (absent-input): " + w.root + "/gone1", "corpus exists, no audits found (empty-input): " + e} {
		if !strings.Contains(full, line) {
			t.Errorf("--full lacks %q", line)
		}
		if strings.Contains(def, line) {
			t.Errorf("the default mode kept %q", line)
		}
	}
	if !strings.Contains(def, "INFO: 2 target(s) not traversed (absent-input) — corpus directory not found; run --full to list them.\n") ||
		!strings.Contains(def, "INFO: 1 corpus(es) empty-input — run --full to list them") || !strings.Contains(def, "PENDING  "+a+"/audits/a1.md") {
		t.Errorf("default mode:\n%s", def)
	}
}

func TestAuditsHookCommandAlwaysExitsZero(t *testing.T) {
	w := newWorld(t) // no TARGETS.md: the sweep cannot run
	r := w.runAuditsHook()
	if r.rc != 0 || r.err != "" {
		t.Errorf("a hook never fails the session: rc=%d stderr=%q", r.rc, r.err)
	}
	if want := "Research-SDD audits sweep could not run (exit 1 — check TARGETS.md and lib/ helper):\nsweep-audits: cannot find " + w.kit + "/TARGETS.md"; hookCtx(t, r.out) != want {
		t.Errorf("failure banner:\n%s\nwant:\n%s", hookCtx(t, r.out), want)
	}
	for _, args := range [][]string{nil, {"--full"}} {
		if r := w.runAuditsHook(args...); r.rc != 0 {
			t.Errorf("exit %d with %v", r.rc, args)
		}
	}
}

func TestAuditsHookEnvelopeBytes(t *testing.T) {
	w := newWorld(t)
	a := w.tgt("targetA")
	w.audit(a, "a1.md", auditPending, 1)
	w.targets(a)
	r := w.runAuditsHook()
	want := "{\n  \"hookSpecificOutput\": {\n    \"hookEventName\": \"SessionStart\",\n    \"additionalContext\": \"Research-SDD pending audits (per-target §13):\\nPENDING  "
	if !strings.HasPrefix(r.out, want) || !strings.HasSuffix(r.out, "\"\n  }\n}\n") {
		t.Errorf("the envelope is jq's bytes:\n%s", r.out)
	}
}
