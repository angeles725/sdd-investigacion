package floss

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"reflect"
	"strings"
	"testing"
)

func caps(maxStrings, maxLen int64) invCaps { return newInvCaps(maxStrings, maxLen) }

func decode(t *testing.T, s string) any {
	t.Helper()
	v, err := decodePyJSON([]byte(s))
	if err != nil {
		t.Fatalf("fixture JSON: %v", err)
	}
	return v
}

func digest(s string) string {
	h := sha256.Sum256([]byte(s))
	return "sha256:" + hex.EncodeToString(h[:])
}

func cat(t *testing.T, inv map[string]any, name string) map[string]any {
	t.Helper()
	c, ok := inv[name].(map[string]any)
	if !ok {
		t.Fatalf("category %s missing in %v", name, inv)
	}
	return c
}

func strs(c map[string]any) []map[string]any { return c["strings"].([]map[string]any) }

func TestBuildInventoryWithoutOutputIsAnEmptyCompleteInventory(t *testing.T) {
	inv, lims, err := buildInventory(nil, caps(2000, 256))
	if err != nil || len(lims) != 0 {
		t.Fatalf("err=%v limitations=%v", err, lims)
	}
	want := map[string]any{"count": 0, "sampled": 0, "strings": []map[string]any{}, "truncated": false}
	for _, name := range []string{"static_strings", "stack_strings", "tight_strings", "decoded_strings"} {
		if got := cat(t, inv, name); !reflect.DeepEqual(got, want) {
			t.Errorf("%s: got %#v", name, got)
		}
	}
	if inv["total_count"] != 0 || inv["total_sampled"] != 0 || inv["truncated"] != false || len(inv) != 7 {
		t.Errorf("totals: %v", inv)
	}
}

func TestBuildInventorySortsEachCategoryByOffsetThenValue(t *testing.T) {
	fl := decode(t, `{"strings":{"static_strings":[
		{"string":"b","offset":10,"encoding":"ASCII"},{"string":"z","offset":2.5},{"string":"a","offset":10},
		{"string":"m","offset":2},{"string":"n"}],"decoded_strings":[{"string":"d","offset":1}]}}`)
	inv, _, err := buildInventory(fl, caps(100, 100))
	if err != nil {
		t.Fatal(err)
	}
	var order []string
	for _, e := range strs(cat(t, inv, "static_strings")) {
		order = append(order, e["value"].(string))
	}
	if got := strings.Join(order, ""); got != "nmzab" {
		t.Errorf("order = %s, want nmzab (offset 0, 2, 2.5, then 10 by value)", got)
	}
	first := strs(cat(t, inv, "static_strings"))[0]
	if first["encoding"] != nil || fmt.Sprint(first["offset"]) != "0" {
		t.Errorf("missing encoding must be null and missing offset 0: %v", first)
	}
	if got := cat(t, inv, "static_strings")["count"]; got != 5 {
		t.Errorf("count = %v", got)
	}
	if got := cat(t, inv, "stack_strings")["count"]; got != 0 {
		t.Errorf("an absent category has count 0, got %v", got)
	}
}

func TestBuildInventoryDigestsTheSampledValue(t *testing.T) {
	fl := decode(t, `{"strings":{"static_strings":[{"string":"café","offset":4,"encoding":"UTF-8"}]}}`)
	inv, _, _ := buildInventory(fl, caps(100, 100))
	e := strs(cat(t, inv, "static_strings"))[0]
	if e["sha256"] != digest("café") || e["value"] != "café" || e["encoding"] != "UTF-8" {
		t.Errorf("entry: %v", e)
	}
	// The digest covers the value as sampled (after the length cap), not the original.
	inv, _, _ = buildInventory(decode(t, `{"strings":{"static_strings":[{"string":"abcdef"}]}}`), caps(100, 3))
	if e := strs(cat(t, inv, "static_strings"))[0]; e["sha256"] != digest("abc") {
		t.Errorf("digest of a capped value: %v", e)
	}
}

func TestBuildInventoryStringLengthCap(t *testing.T) {
	fl := decode(t, `{"strings":{"static_strings":[{"string":"AAAAAAAAAAAAAAAAAAAA","offset":0},{"string":"BBBBBBBBBB","offset":1},{"string":"ok","offset":2}]}}`)
	inv, lims, err := buildInventory(fl, caps(100, 5))
	if err != nil {
		t.Fatal(err)
	}
	got := strs(cat(t, inv, "static_strings"))
	if got[0]["value"] != "AAAAA" || got[1]["value"] != "BBBBB" || got[2]["value"] != "ok" {
		t.Errorf("values: %v", got)
	}
	if inv["truncated"] != true || cat(t, inv, "static_strings")["truncated"] != false {
		t.Errorf("only the overall flag is set by the length cap: %v", inv)
	}
	if !reflect.DeepEqual(lims, []string{"inventory truncated: string-length cap 5 reached"}) {
		t.Errorf("limitations: %v", lims)
	}
}

func TestBuildInventoryLengthCapCountsCodePoints(t *testing.T) {
	fl := decode(t, `{"strings":{"static_strings":[{"string":"😀😀😀"}]}}`)
	inv, _, _ := buildInventory(fl, caps(100, 2))
	if v := strs(cat(t, inv, "static_strings"))[0]["value"]; v != "\U0001F600\U0001F600" {
		t.Errorf("value = %q", v)
	}
}

func TestBuildInventoryStringCountCap(t *testing.T) {
	fl := decode(t, `{"strings":{"static_strings":[{"string":"a","offset":1},{"string":"b","offset":2},{"string":"c","offset":3}],
		"stack_strings":[{"string":"s","offset":1}],"decoded_strings":[{"string":"d","offset":1}]}}`)
	inv, lims, _ := buildInventory(fl, caps(2, 100))
	if inv["total_count"] != 5 || inv["total_sampled"] != 2 || inv["truncated"] != true {
		t.Fatalf("totals: %v", inv)
	}
	want := map[string][3]any{"static_strings": {3, 2, true}, "stack_strings": {1, 0, true}, "tight_strings": {0, 0, false}, "decoded_strings": {1, 0, true}}
	for name, w := range want {
		c := cat(t, inv, name)
		if c["count"] != w[0] || c["sampled"] != w[1] || c["truncated"] != w[2] {
			t.Errorf("%s: %v, want count/sampled/truncated %v", name, c, w)
		}
	}
	if !reflect.DeepEqual(lims, []string{"inventory truncated: string cap 2 reached"}) {
		t.Errorf("limitations: %v", lims)
	}
}

func TestBuildInventoryCapReachedExactlyIsNotTruncation(t *testing.T) {
	fl := decode(t, `{"strings":{"static_strings":[{"string":"a"},{"string":"b"}],"stack_strings":[]}}`)
	inv, lims, _ := buildInventory(fl, caps(2, 100))
	if inv["truncated"] != false || len(lims) != 0 || inv["total_sampled"] != 2 {
		t.Errorf("a budget spent exactly with nothing left must not read as truncated: %v %v", inv, lims)
	}
}

func TestBuildInventoryReportsHugeCapsVerbatim(t *testing.T) {
	c := newInvCapsText("99999999999999999999999", "88888888888888888888888")
	fl := decode(t, `{"strings":{"static_strings":[{"string":"a"}]}}`)
	inv, lims, _ := buildInventory(fl, c)
	if inv["truncated"] != false || len(lims) != 0 {
		t.Errorf("huge caps never fire: %v %v", inv, lims)
	}
	if c.MaxStringsText != "99999999999999999999999" || c.MaxStringLenText != "88888888888888888888888" {
		t.Errorf("caps text: %+v", c)
	}
}

func TestBuildInventoryRefusesShapesItCannotSampleFaithfully(t *testing.T) {
	for _, in := range []string{
		`[]`, `"x"`, `{"strings":[]}`, `{"strings":{"static_strings":{}}}`, `{"strings":{"static_strings":null}}`,
		`{"strings":{"static_strings":["x"]}}`, `{"strings":{"static_strings":[{"string":1}]}}`,
		`{"strings":{"static_strings":[{"string":"a","offset":"7"}]}}`, `{"strings":{"static_strings":[{"string":"a","offset":null}]}}`,
		`{"strings":{"static_strings":[{"string":"a","offset":true}]}}`, `{"strings":{"static_strings":[{"string":"a","offset":NaN}]}}`,
	} {
		if _, _, err := buildInventory(decode(t, in), caps(10, 10)); err == nil {
			t.Errorf("%s: want a shape error", in)
		}
	}
}

func TestBuildInventoryAcceptsAnEmptyObject(t *testing.T) {
	inv, lims, err := buildInventory(decode(t, `{}`), caps(10, 10))
	if err != nil || len(lims) != 0 || inv["total_count"] != 0 || inv["truncated"] != false {
		t.Errorf("{}: %v %v %v", inv, lims, err)
	}
}
