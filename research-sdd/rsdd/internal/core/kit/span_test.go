package kit

import (
	"reflect"
	"testing"
	"time"
)

// R3-scan-unbounded-span: the missing-number count is arithmetic (span - distinct) and only the first 10 missing
// numbers are listed, so a huge range must cost O(files + 10), not O(span). Output is unchanged (the bash-faithful
// small-range cases are covered by the differential scan tests).
func TestScanRangeCostIsIndependentOfSpan(t *testing.T) {
	dir := t.TempDir()
	mkfiles(t, dir, "a-block1.md", "a-block2.md", "a-block5.md")
	start := time.Now()
	got, err := ScanRange(dir, 1, 3_000_000_000, "")
	if err != nil {
		t.Fatal(err)
	}
	if el := time.Since(start); el > 500*time.Millisecond {
		t.Errorf("scan took %v for a 3e9 span: the missing numbers are being enumerated", el)
	}
	if got.Count != 3 || got.Span != 3_000_000_000 || got.MissingCount != 3_000_000_000-3 {
		t.Errorf("counts: %+v", got)
	}
	if !reflect.DeepEqual(got.MissingFirst, []int{3, 4, 6, 7, 8, 9, 10, 11, 12, 13}) {
		t.Errorf("first missing: %v", got.MissingFirst)
	}
}

func TestScanRangeMissingListEdges(t *testing.T) { // first, middle and last number of the range present; a single-number range
	dir := t.TempDir()
	mkfiles(t, dir, "a-block1.md", "a-block3.md", "a-block5.md")
	got, _ := ScanRange(dir, 1, 5, "")
	if got.MissingCount != 2 || !reflect.DeepEqual(got.MissingFirst, []int{2, 4}) {
		t.Errorf("%+v", got)
	}
	one, _ := ScanRange(dir, 3, 3, "")
	if one.MissingCount != 0 || len(one.MissingFirst) != 0 || one.Count != 1 {
		t.Errorf("single: %+v", one)
	}
}
