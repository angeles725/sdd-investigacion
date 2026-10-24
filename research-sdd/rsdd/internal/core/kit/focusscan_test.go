package kit

import (
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strconv"
	"testing"
)

// Ports of toolbelt/tests/focus-prefix-range.test.sh sections 6h, 7h-7j (kit #906): the range count, its claims
// and the typed report.

// scanCorpus is one focus_range_stat / focus_range_report scenario: a FOCUSES.md and the block files beside it.
type scanCorpus struct {
	label, table string
	files        []string
	lo, hi       float64
	count, nFile int
	report       []Diagnostic
}

func clTable(rootCell string) string {
	return niagaraHeader + rootRow("x", rootCell) +
		"| ops | active | `RESEARCH-STATE-ops.md` | y | ops- |\n| rng | stopped | `RESEARCH-STATE-rng.md` | z | B5–B5 |\n"
}

func numbered(prefix string, from, to int) []string {
	var out []string
	for i := from; i <= to; i++ {
		out = append(out, prefix+strconv.Itoa(i)+".md")
	}
	return out
}

var clFiles = []string{"m-bloque1.md", "m-bloque2.md", "m-bloque3.md", "m-bloque6.md", "m-bloque9.md", "n-block1.md", "n-block3.md", "ops-block4.md", "r-bloque5.md"}

// scanCorpora is shared with the differential test.
var scanCorpora = []scanCorpus{
	{"7h two files with one number count once", niagaraHeader + rootRow("x", "B2–B4"), []string{"a-bloque2.md", "b-block2.md", "a-bloque3.md", "a-bloque9.md", "z-block3.md/not-a-file"}, 2, 4, 2, 3,
		[]Diagnostic{{"WARN", "B2–B4 mixes 2 block families that no other FOCUSES.md row claims (file counts: a=2 b=1) — all are counted as distinct block numbers; give a foreign family its own row (prefix or range) to exclude it"},
			{"NOTE", "B2–B4 spans 3 block ids, 2 present, 1 missing (span - distinct): 4"}}},
	{"7i claims, families and missing numbers", clTable("B1–B6"), clFiles, 1, 6, 4, 6,
		[]Diagnostic{{"WARN", "B1–B6 mixes 2 block families that no other FOCUSES.md row claims (file counts: m=4 n=2) — all are counted as distinct block numbers; give a foreign family its own row (prefix or range) to exclude it"},
			{"NOTE", "B1–B6 spans 6 block ids, 4 present, 2 missing (span - distinct): 4,5"}}},
	{"7i.6 the missing list is bounded", niagaraHeader + rootRow("x", "B1–B30"), numbered("q-bloque", 1, 5), 1, 30, 5, 5,
		[]Diagnostic{{"NOTE", "B1–B30 spans 30 block ids, 5 present, 25 missing (span - distinct): 6,7,8,9,10,11,12,13,14,15, … (first 10 of 25)"}}},
	{"7i.7 cannot-see", clTable("B50–B60"), numbered("q-bloque", 1, 3), 50, 60, 0, 0,
		[]Diagnostic{{"WARN", "no block file is numbered within B50–B60 while 3 block file(s) exist outside it — the range may be wrong (cannot-see: the count is 0, not a measured zero)"}}},
	{"7j COB-IM2 layout is clean", "| Focus | Status | State file | Block prefix | Blocks | Summary |\n|---|---|---|---|---|---|\n" +
		"| hvac | stopped | RESEARCH-STATE.md | cob-block | B1–B38 | HVAC |\n| architecture | stopped | RESEARCH-STATE-architecture.md | cob-block | B39–B50 | shell |\n",
		numbered("cob-block", 1, 50), 1, 38, 38, 38, nil},
	{"7j.4 Blocked-by header", "| Focus | Estado | State file | Blocked by | Notes |\n|---|---|---|---|---|\n" + rootRow("none", "B5–B9"), numbered("k-block", 5, 9), 5, 9, 5, 5, nil},
	{"7j.6 fallback WARN", "| Focus | Estado | State file | Blocks | Notes |\n|---|---|---|---|---|\n" + rootRow("see notes", "B2–B4"), numbered("k-block", 2, 4), 2, 4, 3, 3,
		[]Diagnostic{{"WARN", "FOCUSES.md range column cell is not range-shaped; read the range-shaped cell [B2–B4] found elsewhere in the root row — put the range under the Blocks/Bloques header"}}},
	{"6h two range-shaped cells", niagaraHeader + rootRow("B7–B8", "B1–B3"), numbered("k-block", 1, 3), 1, 3, 3, 3,
		[]Diagnostic{{"WARN", "FOCUSES.md root row holds 2 range-shaped cells — only the header-named (else first) one is read; keep exactly one B<a>–B<b> cell"}}},
	{"malformed cell", niagaraHeader + rootRow("x", "B9–B3"), nil, 0, 0, 0, 0,
		[]Diagnostic{{"WARN", "FOCUSES.md block-scope cell [B9–B3] is range-shaped but not the exact grammar B<a>–B<b> (en dash or hyphen, a <= b) — it scopes nothing (METHODOLOGY §16 Block-scope cell grammar)"}}},
	{"no range cell", niagaraHeader + rootRow("x", "y"), numbered("k-block", 1, 3), 0, 0, 0, 0, nil},
	{"claims: a range-header prefix, a prefix-header prefix, malformed and tab-cut claims",
		"| Focus | Estado | State | Block prefix | Bloques |\n|---|---|---|---|---|\n" + rootRow("", "B1-B9") +
			"| a | s | RESEARCH-STATE-a.md | x | `p-blockN.md` |\n| b | s | RESEARCH-STATE-b.md | q- | B9-B1 |\n| c | s | RESEARCH-STATE-c.md | r-\tz- | x |\n| d | s | NOTES.md | s- | B2-B2 |\n",
		[]string{"p-block1.md", "q-block2.md", "r-block3.md", "s-block4.md", "t-block5.md", "pp-block6.md", "p-blocks7.md", "README.md", "u-block8.txt"}, 1, 9, 4, 4,
		[]Diagnostic{{"WARN", "B1–B9 mixes 4 block families that no other FOCUSES.md row claims (file counts: pp=1 q=1 s=1 t=1) — all are counted as distinct block numbers; give a foreign family its own row (prefix or range) to exclude it"},
			{"NOTE", "B1–B9 spans 9 block ids, 4 present, 5 missing (span - distinct): 1,3,7,8,9"}}},
	{"11 missing numbers carry the bound suffix", niagaraHeader + rootRow("x", "B1-B12"), []string{"q-bloque1.md"}, 1, 12, 1, 1,
		[]Diagnostic{{"NOTE", "B1–B12 spans 12 block ids, 1 present, 11 missing (span - distinct): 2,3,4,5,6,7,8,9,10,11, … (first 10 of 11)"}}},
	{"10 missing numbers carry none", niagaraHeader + rootRow("x", "B1-B11"), []string{"q-bloque1.md"}, 1, 11, 1, 1,
		[]Diagnostic{{"NOTE", "B1–B11 spans 11 block ids, 1 present, 10 missing (span - distinct): 2,3,4,5,6,7,8,9,10,11"}}},
	{"a claim reads the PREFIX column before the RANGE one", "| F | S | State | Bloques | Block prefix |\n|---|---|---|---|---|\n" + rootRow("B1-B3", "") +
		"| a | s | RESEARCH-STATE-a.md | other- | own- |\n", []string{"own-block1.md", "other-block2.md"}, 1, 3, 1, 1,
		[]Diagnostic{{"NOTE", "B1–B3 spans 3 block ids, 1 present, 2 missing (span - distinct): 1,3"}}},
	{"a family sorts with its count", niagaraHeader + rootRow("x", "B1-B2"), []string{"a-b-block1.md", "a-block2.md", "a-block1.md"}, 1, 2, 2, 3,
		[]Diagnostic{{"WARN", "B1–B2 mixes 2 block families that no other FOCUSES.md row claims (file counts: a-b=1 a=2) — all are counted as distinct block numbers; give a foreign family its own row (prefix or range) to exclude it"}}},
}

func TestFocusRangeScanAndReport(t *testing.T) {
	for _, c := range scanCorpora {
		t.Run(c.label, func(t *testing.T) {
			d := t.TempDir()
			sf := focusCorpus(t, d, c.table)
			mkfiles(t, d, c.files...)
			if c.hi > 0 {
				s, err := ScanFocusRange(d, c.lo, c.hi, sf)
				if err != nil || s.Count != c.count || s.Files != c.nFile || s.Span != c.hi-c.lo+1 {
					t.Fatalf("scan %+v (%v), want count=%d files=%d", s, err, c.count, c.nFile)
				}
			}
			rep, err := FocusRangeReport(sf)
			if err != nil || !reflect.DeepEqual(rep, c.report) {
				t.Fatalf("report\n got %q (%v)\nwant %q", rep, err, c.report)
			}
		})
	}
}

func TestFocusRangeScanWithoutClaims(t *testing.T) {
	d := t.TempDir()
	focusCorpus(t, d, clTable("B1–B6"))
	mkfiles(t, d, clFiles...)
	if s, err := ScanFocusRange(d, 1, 6, ""); err != nil || s.Count != 6 {
		t.Fatalf("without the claims 4 and 5 leak in: %+v %v", s, err)
	}
}

func TestFocusRangeScanTypedInputs(t *testing.T) {
	d := t.TempDir()
	if _, err := ScanFocusRange(d+"/missing", 1, 2, ""); !errors.Is(err, ErrAbsentInput) {
		t.Errorf("missing dir: %v", err)
	}
	if rep, err := FocusRangeReport(d + "/RESEARCH-STATE-x.md"); rep != nil || err != nil {
		t.Errorf("a suffixed state file has no report: %q %v", rep, err)
	}
	if os.Geteuid() == 0 {
		t.Skip("running as root: chmod 000 stays readable, premise unavailable (NOT a pass)")
	}
	locked := filepath.Join(d, "locked")
	mkfiles(t, locked, "a-block1.md")
	if err := os.Chmod(locked, 0o300); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(locked, 0o755) })
	if _, err := ScanFocusRange(locked, 1, 2, ""); !errors.Is(err, ErrUnreadable) {
		t.Errorf("unlistable dir: %v", err)
	}
}
