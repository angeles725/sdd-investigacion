package lint

import (
	"encoding/json"
	"reflect"
	"sort"
	"testing"
	"unicode/utf8"
)

// The packs carry about twenty regex lookarounds (and as many Unicode `\b`) that Go's regexp lacks. Each was rewritten
// as explicit code or as a consuming construct (see packs.go). These tests pin every rewrite on inputs whose expected
// answers are the FROZEN Python's (testdata/legacy/oracle.py, run once to produce lookaround_cases_test.go): matches,
// non-matches and the edges (Unicode word chars, the nbsp / ideographic space, the start and end of the text, the
// pos/endpos window). oracle_test.go additionally checks random inputs against live Python.

type tableCase struct{ in, want string }

func runeAt(s string, byteIdx int) int { return utf8.RuneCountInString(s[:byteIdx]) }

func byteAt(s string, runeIdx int) int {
	if runeIdx < 0 {
		return 0
	}
	n := 0
	for i := range s {
		if n == runeIdx {
			return i
		}
		n++
	}
	return len(s)
}

func nz(s []string) []string {
	if s == nil {
		return []string{}
	}
	return s
}

func spansJSON(in string, fine bool) any {
	out := [][]any{}
	for _, sp := range r8Spans(in, fine) {
		out = append(out, []any{runeAt(in, sp.start), runeAt(in, sp.end), sp.question})
	}
	return out
}

// goOracle is the Go counterpart of every oracle.py function, keyed by the same name.
var goOracle = map[string]func(in string) any{
	"clauses":               func(in string) any { return nz(clauses(in)) },
	"jvm.r1_feature":        func(in string) any { return jvmR1Feature(in) },
	"jvm.r1_verb":           func(in string) any { return jvmR1Verb(in) },
	"jvm.r1_evidence":       func(in string) any { return jvmR1Evidence(in) },
	"jvm.access_ctx":        func(in string) any { return jvmAccessCtx(in) },
	"jvm.access_scrub":      func(in string) any { return jvmAccessScrub(in) },
	"jvm.r5_consequence":    func(in string) any { return jvmR5Consequence(in) },
	"jvm.r5_perm_context":   func(in string) any { return jvmR5PermContext(in) },
	"jvm.r5_cleared":        func(in string) any { return jvmR5Cleared(in) },
	"jvm.r5_gap_ref":        func(in string) any { return jvmR5GapRef(in) },
	"jvm.r7_trigger":        func(in string) any { return jvmR7Trigger(in) },
	"jvm.r7_evidence":       func(in string) any { return jvmR7Evidence(in) },
	"mv.baseline":           func(in string) any { return r8Baseline(in) },
	"mv.surface":            func(in string) any { return r8Surface(in) },
	"mv.negation":           func(in string) any { return r8Negation(in) },
	"mv.whether":            func(in string) any { return r8Whether(in) },
	"mv.question_open":      func(in string) any { return r8QuestionOpen(in) },
	"mv.sentence_spans":     func(in string) any { return spansJSON(in, false) },
	"mv.question_spans":     func(in string) any { return spansJSON(in, true) },
	"mv.is_claim":           func(in string) any { return isR8Claim(in) },
	"nb.native":             func(in string) any { return r9Native(in) },
	"nb.sha256":             func(in string) any { return r9Sha256(in) },
	"nb.anchor":             func(in string) any { return r9Anchor(in) },
	"nb.instruments":        func(in string) any { return nz(r9Instruments(in)) },
	"cg.section":            func(in string) any { return cgSection(in) },
	"cg.excluded_title":     func(in string) any { return cgExcludedTitle(in) },
	"cg.placeholder":        func(in string) any { return cgPlaceholder(in) },
	"cg.result_placeholder": func(in string) any { return cgResultPlaceholder(in) },
	"cg.prose_placeholder":  func(in string) any { return cgProsePlaceholder(in) },
	"cg.ref_mask":           func(in string) any { return cgRefMask(in) },
	"cg.label":              func(in string) any { return cgLabel(in) },
	"cg.sentence_end": func(in string) any {
		var a []json.RawMessage
		if err := json.Unmarshal([]byte(in), &a); err != nil || len(a) != 3 {
			panic("bad cg.sentence_end input " + in)
		}
		var text string
		var pos, end int
		_ = json.Unmarshal(a[0], &text)
		_ = json.Unmarshal(a[1], &pos)
		_ = json.Unmarshal(a[2], &end)
		i := cgSentenceEnd(text, byteAt(text, pos), byteAt(text, end))
		if i < 0 {
			return nil
		}
		return runeAt(text, i)
	},
	"cg.number": func(in string) any {
		if n, ok := cgStatedNumber(in); ok {
			return n
		}
		return nil
	},
	"cg.bullet": func(in string) any {
		if ind, id, ok := cgBullet(in); ok {
			return []any{ind, id}
		}
		return nil
	},
	"cg.coverage_problem": func(in string) any {
		if p := cgCoverageProblem(in); p != "" {
			return p
		}
		return nil
	},
	"cg.judge": func(in string) any {
		out := [][]string{}
		for _, f := range cgJudgeBullet(in) {
			out = append(out, []string{f.kind, f.detail})
		}
		return out
	},
}

func normJSON(t testing.TB, v any) any {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatalf("marshal %v: %v", v, err)
	}
	var out any
	if err := json.Unmarshal(b, &out); err != nil {
		t.Fatalf("unmarshal %s: %v", b, err)
	}
	return out
}

func runTable(t *testing.T, fns ...string) {
	t.Helper()
	for _, fn := range fns {
		cases, ok := oracleTables[fn]
		g := goOracle[fn]
		if !ok || g == nil || len(cases) < 10 {
			t.Fatalf("absent-input: oracle table or Go function for %q (cases=%d)", fn, len(cases))
		}
		bad := 0
		for _, c := range cases {
			var want any
			if err := json.Unmarshal([]byte(c.want), &want); err != nil {
				t.Fatalf("%s: bad table entry %q: %v", fn, c.want, err)
			}
			got := normJSON(t, g(c.in))
			if !reflect.DeepEqual(got, want) {
				bad++
				if bad <= 12 {
					t.Errorf("%s(%q) = %v, Python says %v", fn, c.in, got, want)
				}
			}
		}
		if bad > 12 {
			t.Errorf("%s: %d of %d cases differ", fn, bad, len(cases))
		}
	}
}

func TestLintPackLookaroundClauseSplit(t *testing.T)  { runTable(t, "clauses") }
func TestLintPackLookaroundAccessAction(t *testing.T) { runTable(t, "jvm.access_scrub") }
func TestLintPackLookaroundAccessBlock(t *testing.T)  { runTable(t, "jvm.access_ctx") }
func TestLintPackLookaroundCleared(t *testing.T)      { runTable(t, "jvm.r5_cleared") }
func TestLintPackLookaroundR8Baseline(t *testing.T)   { runTable(t, "mv.baseline") }
func TestLintPackLookaroundR8Negation(t *testing.T)   { runTable(t, "mv.negation") }
func TestLintPackLookaroundR8Whether(t *testing.T)    { runTable(t, "mv.whether") }
func TestLintPackLookaroundR8Spans(t *testing.T) {
	runTable(t, "mv.sentence_spans", "mv.question_spans")
}
func TestLintPackLookaroundR9Native(t *testing.T)      { runTable(t, "nb.native") }
func TestLintPackLookaroundR9Sha256(t *testing.T)      { runTable(t, "nb.sha256") }
func TestLintPackLookaroundR9Anchor(t *testing.T)      { runTable(t, "nb.anchor") }
func TestLintPackLookaroundR9Instruments(t *testing.T) { runTable(t, "nb.instruments") }
func TestLintPackLookaroundExcludedTitle(t *testing.T) { runTable(t, "cg.excluded_title") }
func TestLintPackLookaroundSentenceEnd(t *testing.T)   { runTable(t, "cg.sentence_end") }
func TestLintPackLookaroundProsePlaceholder(t *testing.T) {
	runTable(t, "cg.prose_placeholder")
}
func TestLintPackLookaroundNumber(t *testing.T) { runTable(t, "cg.number") }

// The Unicode `\b` / `\w` / `\s` / `\d` rewrites of the regexes that carry no lookaround.
func TestLintPackBoundaryJvm(t *testing.T) {
	runTable(t, "jvm.r1_feature", "jvm.r1_verb", "jvm.r1_evidence", "jvm.r5_consequence", "jvm.r5_perm_context",
		"jvm.r5_gap_ref", "jvm.r7_trigger", "jvm.r7_evidence")
}

// The `gap G<n>` alternative of R5_GAP_REF is the only one that matches mid-sentence without a colon (found by a
// hand mutant that dropped it); expected values are the frozen Python's.
func TestLintPackBoundaryJvmGapWord(t *testing.T) {
	for in, want := range map[string]bool{
		"the gap G7 was fixed": true, "the gapG7 was": false, "the gap G was": false, "the gap  g12 x": true, "logap G7": false,
	} {
		if got := jvmR5GapRef(in); got != want {
			t.Errorf("jvmR5GapRef(%q) = %v, Python says %v", in, got, want)
		}
	}
}

func TestLintPackBoundaryMultiVersion(t *testing.T) {
	runTable(t, "mv.surface", "mv.question_open", "mv.is_claim")
}

func TestLintPackBoundaryChildGap(t *testing.T) {
	runTable(t, "cg.section", "cg.placeholder", "cg.result_placeholder", "cg.label", "cg.ref_mask", "cg.bullet", "cg.coverage_problem", "cg.judge")
}

// Every oracle function must have a Go counterpart and a table (a function with neither is a silent gap).
func TestLintPackOracleCoverage(t *testing.T) {
	var a, b []string
	for k := range goOracle {
		a = append(a, k)
	}
	for k := range oracleTables {
		b = append(b, k)
	}
	sort.Strings(a)
	sort.Strings(b)
	for _, k := range a {
		if _, ok := oracleTables[k]; !ok {
			t.Errorf("Go function %q has no table", k)
		}
	}
	for _, k := range b {
		if goOracle[k] == nil {
			t.Errorf("table %q has no Go function", k)
		}
	}
}
