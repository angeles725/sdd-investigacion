package grammar

import (
	"reflect"
	"testing"
)

func TestDeltaIDAndTableIDSkip(t *testing.T) {
	for tok, want := range map[string][2]bool{ // {DeltaID, TableIDSkip}
		"A": {true, false}, "R1": {true, false}, "SO2": {true, false}, "SPKI-A": {true, false}, "D-1": {true, false},
		"ID": {false, true}, "DELTA": {false, true}, "ITEM-ID": {true, false}, "ABCDEFGH1": {false, false},
		"ABCDEFG1": {true, false}, "a": {false, true}, "d1": {false, false}, "1": {false, false}, "B12": {true, false},
		"#": {false, true}, "---": {false, true}, ":-:": {false, true}, "": {false, false}, "A-": {false, true},
		"A-B-C": {false, true}, "Total": {false, true}, "x\xff": {false, true}, "#3": {false, false}, "Ab1": {false, false},
	} {
		if got := [2]bool{DeltaID(tok), TableIDSkip(tok)}; got != want {
			t.Errorf("%q: DeltaID/TableIDSkip = %v, want %v", tok, got, want)
		}
	}
}

func TestIDSignatureSafe(t *testing.T) {
	for id, want := range map[string]bool{
		"D1": true, "a_b-C9": true, "": false, "D.1": false, "D|1": false, "D 1": false, `D\1`: false, "é": false,
	} {
		if got := IDSignatureSafe(id); got != want {
			t.Errorf("IDSignatureSafe(%q) = %v, want %v", id, got, want)
		}
	}
}

func TestDupIDs(t *testing.T) {
	got := DupIDs([]string{"2", "1", "b", "1", "", "2", "1", "B", ""})
	if want := []string{"", "1", "2"}; !reflect.DeepEqual(got, want) {
		t.Errorf("DupIDs = %q, want %q", got, want)
	}
	if got := DupIDs([]string{"x"}); len(got) != 0 {
		t.Errorf("DupIDs(no dup) = %q", got)
	}
}
