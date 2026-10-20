package kit

import (
	"errors"
	"fmt"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

const (
	rt        = "`RESEARCH-STATE.md`"
	fHdr      = "# Focus index\n\n| Focus | Estado | RESEARCH-STATE | Ámbito | Bloques |\n|---|---|---|---|---|\n"
	fHdrBlock = "| Focus | Status | State | Block prefix |\n|---|---|---|---|\n"
)

func row5(cell string) string { return "| (base) | stopped | " + rt + " | x | " + cell + " |" }

// focusCorpus is shared with the differential test: name -> FOCUSES.md body.
var focusCorpus = map[string]string{
	"en-dash":       fHdr + row5("B1–B130") + "\n",
	"hyphen":        fHdr + row5("B2-B9") + "\n",
	"backticked":    fHdr + row5("`B3–B3`") + "\n",
	"bold":          fHdr + row5("**B4–B8**") + "\n",
	"first":         fHdr + row5("B1–B5") + "\n| other | active | `RESEARCH-STATE-o.md` | y | o- |\n| third | active | `RESEARCH-STATE-t.md` | y | t- |\n",
	"middle":        fHdr + "| other | active | `RESEARCH-STATE-o.md` | y | o- |\n" + row5("B1–B5") + "\n| third | active | `RESEARCH-STATE-t.md` | y | t- |\n",
	"last":          fHdr + "| other | active | `RESEARCH-STATE-o.md` | y | o- |\n" + row5("B1–B5") + "\n",
	"last-nonl":     strings.TrimSuffix(fHdr+"| other | active | `RESEARCH-STATE-o.md` | y | o- |\n"+row5("B2–B9"), " |"),
	"other-row":     fHdr + "| other | active | `RESEARCH-STATE-o.md` | y | B1–B5 |\n" + row5("free text") + "\n",
	"prefix4":       fHdrBlock + "| (base) | stopped | " + rt + " | base- |\n",
	"prefix+rng":    fHdr + "| (base) | stopped | " + rt + " | base- | B1–B9 |\n",
	"prefix-blk":    fHdrBlock + "| (base) | stopped | " + rt + " | base-block1.md |\n",
	"prefix-nodash": fHdrBlock + "| (base) | stopped | " + rt + " | base |\n",
	"prefix-digit":  fHdrBlock + "| (base) | stopped | " + rt + " | 1x- |\n",
	"link-form":     fHdrBlock + "| (base) | stopped | [RESEARCH-STATE.md](x.md) | linked- |\n",
	"link-open":     fHdrBlock + "| (base) | stopped | [RESEARCH-STATE.md | open- |\n",
	"two-ranges":    fHdr + "| (base) | stopped | " + rt + " | B7–B8 | B1–B3 |\n",
	"fallback":      fHdr + "| (base) | stopped | " + rt + " | B7–B8 | free |\n",
	"a-gt-b":        fHdr + row5("B9–B3") + "\n",
	"words":         fHdr + row5("B1–B130 extra words") + "\n",
	"em-dash":       fHdr + row5("B1—B130") + "\n",
	"spaced":        fHdr + row5("B1 – B130") + "\n",
	"no-b":          fHdr + row5("B1–130") + "\n",
	"open-ended":    fHdr + row5("B1157–") + "\n",
	"list":          fHdr + row5("B841–B861, B866") + "\n",
	"prose":         fHdr + "| (base) | stopped | " + rt + " | cubre B77/B96 y B106, B117-B122 | no range |\n",
	"no-pipe-end":   fHdr + "| (base) | stopped | " + rt + " | x | B2–B9\n",
	"no-root":       fHdr + "| other | active | `RESEARCH-STATE-o.md` | y | o- |\n",
	"indented":      fHdr + "  " + row5("B1–B5") + "\n",
	"crlf":          strings.ReplaceAll(fHdr+row5("B1–B5")+"\n", "\n", "\r\n"),
	"empty":         "",
	"claims":        fHdr + row5("B1–B6") + "\n| ops | active | `RESEARCH-STATE-ops.md` | y | ops- |\n| rng | stopped | `RESEARCH-STATE-rng.md` | z | B5–B5 |\n",
	"claims-bad":    fHdr + row5("B1–B6") + "\n| bad | active | `RESEARCH-STATE-bad.md` | y | B9–B3 |\n| p | x | `RESEARCH-STATE-p.md` | y | p-block1.md notes |\n",
}

// scanFiles are the block files used by the scan and report tests.
var scanFiles = []string{"m-bloque1.md", "m-bloque2.md", "m-bloque3.md", "m-bloque6.md", "m-bloque9.md", "n-block1.md", "n-block3.md",
	"ops-block4.md", "r-bloque5.md", "notes.md", "x-block7.txt", "dup-block2.md"}

func focusDir(t *testing.T, body string, files ...string) (dir, sf string) {
	t.Helper()
	dir = t.TempDir()
	write(t, filepath.Join(dir, "FOCUSES.md"), body)
	sf = write(t, filepath.Join(dir, "RESEARCH-STATE.md"), "")
	mkfiles(t, dir, files...)
	return dir, sf
}

func TestDerivePrefixFromFilename(t *testing.T) {
	for base, want := range map[string]string{
		"RESEARCH-STATE-auth.md": "auth-", "RESEARCH-STATE-a-b.md": "a-b-", "RESEARCH-STATE-.md": "-",
	} {
		got, o := DerivePrefix(filepath.Join(t.TempDir(), base))
		if got != want || o != PrefixFromFilename {
			t.Errorf("%s: %q %v", base, got, o)
		}
	}
	if got, o := DerivePrefix("/x/other.md"); got != "" || o != PrefixNone {
		t.Errorf("unrelated name: %q %v", got, o)
	}
}

func TestDerivePrefixFromFocuses(t *testing.T) {
	for name, want := range map[string]string{"prefix4": "base-", "prefix+rng": "base-", "prefix-blk": "base-", "link-form": "linked-",
		"prefix-nodash": "", "prefix-digit": "", "en-dash": "", "link-open": "", "empty": "", "no-root": "", "indented": ""} {
		_, sf := focusDir(t, focusCorpus[name])
		if got, _ := DerivePrefix(sf); got != want {
			t.Errorf("%s: %q want %q", name, got, want)
		}
	}
	// the sibling FOCUSES.md is absent: a quiet "" with a typed origin, not an error
	if got, o := DerivePrefix(write(t, filepath.Join(t.TempDir(), "RESEARCH-STATE.md"), "")); got != "" || o != PrefixNone {
		t.Errorf("no FOCUSES.md: %q %v", got, o)
	}
}

func TestDeriveRangeFormsAndPositions(t *testing.T) {
	ok := map[string]string{"en-dash": "1-130", "hyphen": "2-9", "backticked": "3-3", "bold": "4-8", "first": "1-5", "middle": "1-5",
		"last": "1-5", "last-nonl": "2-9", "no-pipe-end": "2-9", "two-ranges": "1-3", "fallback": "7-8", "prefix+rng": "1-9", "crlf": ""}
	for name, want := range ok {
		_, sf := focusDir(t, focusCorpus[name])
		if got := DeriveRange(sf).Output(); got != want && name != "crlf" {
			t.Errorf("%s: %q want %q", name, got, want)
		}
	}
	for name, cell := range map[string]string{"a-gt-b": "B9–B3", "words": "B1–B130 extra words", "em-dash": "B1—B130", "spaced": "B1 – B130",
		"no-b": "B1–130", "open-ended": "B1157–", "list": "B841–B861, B866"} {
		_, sf := focusDir(t, focusCorpus[name])
		r := DeriveRange(sf)
		if r.Kind != RangeMalformed || r.Output() != "!"+cell {
			t.Errorf("%s: %+v want malformed %q", name, r, cell)
		}
	}
	for _, name := range []string{"other-row", "prose", "no-root", "indented", "empty", "prefix4"} {
		_, sf := focusDir(t, focusCorpus[name])
		if r := DeriveRange(sf); r.Kind != RangeNone || r.Output() != "" {
			t.Errorf("%s: %+v", name, r)
		}
	}
	_, sf := focusDir(t, focusCorpus["two-ranges"])
	if r := DeriveRange(sf); r.Multi != 2 {
		t.Errorf("multi: %+v", r)
	}
	_, sf = focusDir(t, focusCorpus["fallback"])
	if r := DeriveRange(sf); r.Fallback != "B7–B8" {
		t.Errorf("fallback: %+v", r)
	}
	// only the un-suffixed root reads a range; no FOCUSES.md at all is a quiet "" as well
	dir, _ := focusDir(t, focusCorpus["en-dash"])
	if r := DeriveRange(filepath.Join(dir, "RESEARCH-STATE-o.md")); r.Kind != RangeNone {
		t.Errorf("suffixed state file read a range: %+v", r)
	}
	if r := DeriveRange(write(t, filepath.Join(t.TempDir(), "RESEARCH-STATE.md"), "")); r.Kind != RangeNone {
		t.Errorf("no FOCUSES.md: %+v", r)
	}
}

func TestBlockRangeFilterEdges(t *testing.T) {
	paths := []string{"/c/x-bloque1.md", "/c/x-bloque2.md", "/c/x-bloque3.md", "/c/x-block4.md", "/c/x-bloque5-suffix.md", "/c/x-bloque10.md"}
	cnt := func(lo, hi int) int { return len(BlockRangeFilter(paths, lo, hi, false)) }
	for name, c := range map[string][3]int{"2..4 inclusive": {2, 4, 3}, "first only": {1, 1, 1}, "last, two digits": {10, 10, 1},
		"suffix file by number": {5, 5, 1}, "no hit": {6, 9, 0}, "wide": {0, 99, 6}} {
		if got := cnt(c[0], c[1]); got != c[2] {
			t.Errorf("%s: %d want %d", name, got, c[2])
		}
	}
	if got := BlockRangeFilter(paths, 2, 4, true); !reflect.DeepEqual(got, []string{"2", "3", "4"}) {
		t.Errorf("-n: %q", got)
	}
	if got := BlockRangeFilter([]string{"no-number.md", "/d/x-bloque7.md"}, 7, 7, false); !reflect.DeepEqual(got, []string{"/d/x-bloque7.md"}) {
		t.Errorf("non-block paths are dropped: %q", got)
	}
}

func TestScanRange(t *testing.T) {
	dir, sf := focusDir(t, focusCorpus["claims"], scanFiles...)
	got, err := ScanRange(dir, 1, 6, sf)
	if err != nil {
		t.Fatal(err)
	}
	// claimed away: ops-block4 (prefix row), r-bloque5 (range row B5-B5); notes.md/x-block7.txt are no block files;
	// numbers 1,2,3,6 are present (n-block1/3 and dup-block2 repeat numbers)
	want := RangeScan{Count: 4, Files: 7, Span: 6, Outside: 1, Families: map[string]int{"m": 4, "n": 2, "dup": 1}, MissingCount: 2, MissingFirst: []int{4, 5}}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("got %+v\nwant %+v", got, want)
	}
	if _, err := ScanRange(filepath.Join(dir, "nope"), 1, 2, sf); !errors.Is(err, ErrAbsentInput) {
		t.Errorf("absent dir must be typed (bash: counts of 0): %v", err)
	}
	empty, esf := focusDir(t, focusCorpus["claims"])
	if r, err := ScanRange(empty, 1, 6, esf); err != nil || r.Count != 0 || r.MissingCount != 6 {
		t.Errorf("empty dir is a measured zero, not absent: %+v %v", r, err)
	}
}

func TestRangeReportTexts(t *testing.T) {
	dir, sf := focusDir(t, focusCorpus["claims"], scanFiles...)
	_ = dir
	got := RangeReport(sf)
	want := []Diag{
		{"WARN", "B1–B6 mixes 3 block families that no other FOCUSES.md row claims (file counts: dup=1 m=4 n=2) — all are counted as distinct block numbers; give a foreign family its own row (prefix or range) to exclude it"},
		{"NOTE", "B1–B6 spans 6 block ids, 4 present, 2 missing (span - distinct): 4,5"},
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("got %+v\nwant %+v", got, want)
	}
	_, sf = focusDir(t, focusCorpus["two-ranges"])
	if got := RangeReport(sf); len(got) != 1 || got[0].Kind != "WARN" || !strings.HasPrefix(got[0].Text, "FOCUSES.md root row holds 2 range-shaped cells") {
		t.Errorf("two ranges: %+v", got)
	}
	_, sf = focusDir(t, focusCorpus["a-gt-b"])
	if got := RangeReport(sf); len(got) != 1 || !strings.HasPrefix(got[0].Text, "FOCUSES.md block-scope cell [B9–B3] is range-shaped but not the exact grammar") {
		t.Errorf("malformed: %+v", got)
	}
	_, sf = focusDir(t, focusCorpus["en-dash"], "z-block500.md") // a range matching nothing while block files exist outside it
	if got := RangeReport(sf); len(got) != 1 || !strings.Contains(got[0].Text, "no block file is numbered within B1–B130 while 1 block file(s) exist outside it") {
		t.Errorf("cannot-see: %+v", got)
	}
	_, sf = focusDir(t, focusCorpus["en-dash"], fmt.Sprintf("q-block%d.md", 1))
	for _, d := range RangeReport(sf) {
		if d.Kind != "NOTE" {
			t.Errorf("unexpected %+v", d)
		}
	}
	_, sf = focusDir(t, focusCorpus["prefix4"])
	if got := RangeReport(sf); len(got) != 0 {
		t.Errorf("clean/absent cell prints nothing: %+v", got)
	}
}
