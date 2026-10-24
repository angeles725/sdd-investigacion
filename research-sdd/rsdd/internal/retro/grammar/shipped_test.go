package grammar

import (
	"errors"
	"reflect"
	"testing"
)

func TestMarkerIsPartial(t *testing.T) {
	for line, want := range map[string]bool{
		"<!-- review-status: applied · abc · PARTIAL — shipped: #1 -->":                true,
		"<!-- review-status: dismissed — (P1 partial) -->":                             false,
		"<!-- review-status: applied · sha · shipped: #1, #2 -->":                      true,
		"<!-- review-status: applied · kit abc — all done; nothing shipped: later -->": false,
		"<!-- review-status: applied (PARTIAL) -->":                                    false,
		"<!-- review-status: applied · Partial -->":                                    false,
		"<!-- review-status: applied · xPARTIAL -->":                                   false,
		"<!-- review-status: applied ·PARTIAL1 -->":                                    true,
		"PARTIAL no marker":                          true,
		"<!-- review-status: applied --> PARTIAL":    false,
		"<!-- review-status: x shipped: (y) PARTIAL": true,
		"<!-- review-status: x Shipped: y":           false,
		"<!-- review-status:(PARTIAL) -->":           false, "<!-- review-status:— PARTIAL -->": false,
		"": false,
	} {
		if got := MarkerIsPartial(line); got != want {
			t.Errorf("MarkerIsPartial(%q) = %v, want %v", line, got, want)
		}
	}
}

func TestShippedRaw(t *testing.T) {
	for line, want := range map[string]string{
		"<!-- review-status: applied · PARTIAL — shipped: #1, #2; DISMISSED: #3 -->": "#1, #2",
		"Shipped:  D1 (x) > y":  "D1 (x) ",
		"SHIPPED: x":            "SHIPPED: x",
		"no keyword":            "",
		"a shipped:b shipped:c": "b shipped:c",
		"shipped:;x":            "",
		"x\nShipped: a; b":      "a",
		"\u017fhipped: a":       "",
		"":                      "",
	} {
		if got := ShippedRaw(line); got != want {
			t.Errorf("ShippedRaw(%q) = %q, want %q", line, got, want)
		}
	}
}

func TestShippedIDs(t *testing.T) {
	for raw, want := range map[string][]string{
		"#1, #2": {"1", "2"}, "Δ1 (#549), D1 (§20)": {"Δ1", "D1"}, "P1-P3": {"P1", "P2", "P3"},
		"P08-P10": {"P8", "P9", "P10"}, "P3-P1": nil, "A1-B3": {"A1-B3"}, "1-3": {"1", "2", "3"}, "##5": {"#5"},
		"#": nil, "": nil, "a\vb": {"a\vb"}, "x (unclosed": {"x", "(unclosed"}, "a,,b\tc": {"a", "b", "c"},
		"(c) a": {"a"}, "08": {"08"}, "a\nb": {"a"}, "P99999999999999999999-P99999999999999999999": {"P7766279631452241919"},
	} {
		got, err := ShippedIDs(raw)
		if err != nil || !reflect.DeepEqual(got, want) {
			t.Errorf("ShippedIDs(%q) = %q %v, want %q", raw, got, err, want)
		}
	}
	if _, err := ShippedIDs("P1-P100001"); !errors.Is(err, ErrRangeTooLarge) {
		t.Errorf("ShippedIDs(P1-P100001) = %v, want ErrRangeTooLarge", err)
	}
	if got, err := ShippedIDs("P9223372036854775806-P9223372036854775807"); err != nil || len(got) != 2 {
		t.Errorf("a range ending at the int64 maximum must terminate: %q %v", got, err)
	}
	if got, err := ShippedIDs("P1-P100000"); err != nil || len(got) != 100000 {
		t.Errorf("a 100000-id range is allowed: %d %v", len(got), err)
	}
}
