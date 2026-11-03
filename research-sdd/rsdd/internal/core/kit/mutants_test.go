package kit

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

// These tests pin behaviour that only the bash differential tests used to cover, so the mutation run (which drops
// those with -tags nodiff) still has teeth. Each names the boundary or branch it guards.

func TestCLessIsStrict(t *testing.T) {
	if cLess("a", "a") || !cLess("a", "b") || cLess("b", "a") {
		t.Fatal("cLess must be a strict bytewise order")
	}
}

func TestASCIILetterAndAlnumBoundaries(t *testing.T) {
	for _, b := range []byte("AZaz09") {
		if !isAlnum(b) {
			t.Errorf("isAlnum(%q) = false", b)
		}
	}
	for _, b := range []byte("AZaz") {
		if !isASCIILetter(b) {
			t.Errorf("isASCIILetter(%q) = false", b)
		}
	}
	for _, b := range []byte("@[`{/:") {
		if isAlnum(b) {
			t.Errorf("isAlnum(%q) = true", b)
		}
		if isASCIILetter(b) {
			t.Errorf("isASCIILetter(%q) = true", b)
		}
	}
	for _, id := range []string{"0", "9"} {
		if got, ok := InplaceGapID(id); !ok || got != id {
			t.Errorf("InplaceGapID(%q) = %q %v", id, got, ok)
		}
	}
}

func TestAwkFieldIsOneBased(t *testing.T) {
	f := []string{"a", "b", "c"}
	for i, want := range map[int]string{0: "", 1: "a", 3: "c", 4: ""} {
		if got := awkField(f, i); got != want {
			t.Errorf("awkField(f, %d) = %q, want %q", i, got, want)
		}
	}
}

func TestHeaderColumnsSeesTheLastColumn(t *testing.T) {
	hdr, hdrp := headerColumns("| Name | Rango")
	if hdr != 3 || hdrp != 0 {
		t.Fatalf("range header in the last column: hdr=%d hdrp=%d", hdr, hdrp)
	}
	hdr, hdrp = headerColumns("| Name | Block range | Prefix")
	if hdr != 3 || hdrp != 4 {
		t.Fatalf("hdr=%d hdrp=%d, want 3 4", hdr, hdrp)
	}
}

func TestAsciiLowerCoversTheWholeAlphabet(t *testing.T) {
	if got := asciiLower("AZ@[Mz"); got != "az@[mz" {
		t.Fatalf("got %q", got)
	}
}

func TestScanDiagnosticsNoWarnWhenNothingExistsOutside(t *testing.T) {
	if got := scanDiagnostics("B1–B3", RangeScan{}); len(got) != 0 {
		t.Fatalf("empty scan with nothing outside the range: %v", got)
	}
	got := scanDiagnostics("B1–B3", RangeScan{Outside: 2})
	if len(got) != 1 || got[0].Kind != "WARN" {
		t.Fatalf("files outside an empty range must WARN once: %v", got)
	}
}

func TestScanFocusRangeListsTenMissingIDs(t *testing.T) {
	s, err := ScanFocusRange(t.TempDir(), 1, 30, "")
	if err != nil {
		t.Fatal(err)
	}
	want := []float64{1, 2, 3, 4, 5, 6, 7, 8, 9, 10}
	if !reflect.DeepEqual(s.First, want) {
		t.Fatalf("First = %v, want %v", s.First, want)
	}
}

// Past 2^53 a double cannot count: v+1 == v, so the missing-id walk stops instead of repeating one id forever.
func TestScanFocusRangeStopsWhereDoublesStopCounting(t *testing.T) {
	big := float64(1 << 53)
	s, err := ScanFocusRange(t.TempDir(), big, big, "")
	if err != nil {
		t.Fatal(err)
	}
	if len(s.First) != 0 {
		t.Fatalf("First = %v, want none", s.First)
	}
}

func TestBlockedBulletNameKeepsAnEmptyName(t *testing.T) {
	if got := blockedBulletNames("- needs: x\n"); !reflect.DeepEqual(got, []string{""}) {
		t.Fatalf("got %q", got)
	}
}

func TestTrimDashRunConsumesAWholeDashString(t *testing.T) {
	for _, in := range []string{"", "-", "---", "-\xe2\x80\x93"} {
		if got := trimDashRun(in); got != "" {
			t.Errorf("trimDashRun(%q) = %q", in, got)
		}
	}
	if got := trimDashRun("ab -"); got != "ab " {
		t.Errorf("got %q", got)
	}
	// a bullet that is only a dash run before needs: counts nothing and must not panic
	if n := InplaceBlockedCount("- -- needs: x\n", "low\tg1\tblocked\n"); n != 1 {
		t.Errorf("InplaceBlockedCount = %d, want 1", n)
	}
}

func TestDirOfCutsAtTheLastSlash(t *testing.T) {
	for in, want := range map[string]string{"/x": "", "a/b": "a", "/a/b": "/a", "b": "b"} {
		if got := dirOf(in); got != want {
			t.Errorf("dirOf(%q) = %q, want %q", in, got, want)
		}
	}
}

// find lists its start point when that is itself named like a state file, whatever its type.
func TestListStateFilesListsAStartPointNamedLikeAStateFile(t *testing.T) {
	for _, name := range []string{"RESEARCH-STATE.md", "RESEARCH-STATE-x.md"} {
		dir := filepath.Join(physical(t, t.TempDir()), "p", name)
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
		got, err := ListStateFiles(dir)
		if err != nil || !reflect.DeepEqual(got, []string{dir}) {
			t.Errorf("ListStateFiles(%s) = %v, %v", dir, got, err)
		}
	}
}

func TestDeriveFindsEveryResearchHomeTokenOnARow(t *testing.T) {
	src := "| 1 | a | `$RESEARCH_HOME/one` `${RESEARCH_HOME}/two` |\n"
	pairs, reading := Derive(src, envOf(map[string]string{"RESEARCH_HOME": "/rh"}))
	want := []Pair{{"$RESEARCH_HOME/one", "/rh/one"}, {"${RESEARCH_HOME}/two", "/rh/two"}}
	if reading != ReadTokens || !reflect.DeepEqual(pairs, want) {
		t.Fatalf("pairs=%v reading=%v", pairs, reading)
	}
}

// With nested targets the innermost ancestor wins even when it sorts before the outer one ('$' < '/').
func TestNameForRetroInnermostAncestorWinsAtFirstIndex(t *testing.T) {
	e := newNameEnv(t)
	outer := filepath.Join(e.root, "outer")
	retro := e.retro("outer/inner")
	tg := e.targets(
		"| 1 | Outer | `"+outer+"` |",
		"| 2 | Inner | `$RESEARCH_HOME/inner` |",
	)
	r, err := NameForRetro(tg, retro, e.root, rhEnv(outer))
	if err != nil || r.Name != "Inner" {
		t.Fatalf("name=%q err=%v, want Inner", r.Name, err)
	}
}

// A row ending right after the path cell has exactly four pipe fields; its name is still read.
func TestNameForRetroReadsARowWithoutATrailingPipe(t *testing.T) {
	e := newNameEnv(t)
	dir := filepath.Join(e.root, "dirbase")
	retro := e.retro("dirbase")
	tg := e.file("# t\n\n| # | Target | Path |\n|---|---|---|\n| 1 | Label | `" + dir + "`\n")
	r, err := NameForRetro(tg, retro, e.root, rhEnv(e.root))
	if err != nil || r.Name != "Label" {
		t.Fatalf("name=%q err=%v, want Label", r.Name, err)
	}
}
