package scoreloop

import (
	"errors"
	"testing"
	"time"
)

// Guard-to-test table (each guard is also pinned black-box by the golden cases in cases_*_test.go):
//   parseTimestamp layouts and letter folding .... TestParseTimestamp
//   lastParagraph blank/whitespace/empty ......... TestLastParagraph
//   jqJoinPart scalar rendering and refusals ..... TestJQJoinPart, TestLastParagraphOfShapes
//   BOM, concatenated values, invalid JSON ....... TestDecodeValues
//   operator and compaction built-in tests ....... TestBuiltinVerdict
//   buildRows skips, drops and overrides ......... TestBuildRows
//   anyOrigin scan ............................... TestAnyOrigin

func TestParseTimestamp(t *testing.T) {
	want := time.Date(2026, 6, 1, 0, 10, 0, 0, time.UTC)
	for _, in := range []string{
		"2026-06-01T00:10:00Z", "2026-06-01T00:10:00.25Z", "2026-06-01T02:10:00+02:00", "2026-06-01T02:10:00+0200",
		"2026-06-01T02:10:00+02", "2026-06-01 00:10:00Z", "2026-06-01 02:10:00+0200", "2026-06-01 02:10:00+02",
		"2026-06-01T00:10:00", "2026-06-01 00:10:00", "2026-06-01T00:10", "2026-06-01 00:10", "2026-6-1T0:10:00Z",
		"2026-06-01t00:10:00z", "2026-06-01T00:10:00,5Z",
	} {
		got, ok := parseTimestamp(in)
		if !ok || !got.Truncate(time.Second).Equal(want) {
			t.Errorf("parseTimestamp(%q) = %v, %v; want %v", in, got, ok, want)
		}
	}
	if got, ok := parseTimestamp("2026-06-01"); !ok || !got.Equal(time.Date(2026, 6, 1, 0, 0, 0, 0, time.UTC)) {
		t.Errorf("date only: %v %v", got, ok)
	}
	for _, in := range []string{"", "yesterday", "5", "@100", "2026-06-01T24:00:00Z", "2026-13-01T00:00:00Z", "20260601T001000Z", "2026-06-01T00:10:00 UTC"} {
		if got, ok := parseTimestamp(in); ok {
			t.Errorf("parseTimestamp(%q) = %v, want no parse", in, got)
		}
	}
	// A short string must not trip the separator fold (it indexes position 10).
	if _, ok := parseTimestamp("2026-06-01t"); ok {
		t.Error("a dangling separator parsed")
	}
	if got, ok := parseTimestamp("2026-06-01t00:10:00Z"); !ok || !got.Equal(want) {
		t.Errorf("lowercase separator alone: %v %v", got, ok)
	}
	if got, ok := parseTimestamp("2026-06-01T00:10:00z"); !ok || !got.Equal(want) {
		t.Errorf("lowercase zone alone: %v %v", got, ok)
	}
}

func TestLastParagraph(t *testing.T) {
	cases := []struct{ in, want string }{
		{"", ""}, {"\n\n", ""}, {"a", "a"}, {"a\nb", "a\nb"}, {"a\n\nb", "b"}, {"a\n\nb\n\n", "b"}, {"a\n  \nb", "a\n  \nb"},
		{"x\n\na\nb\nc\n", "a\nb\nc"}, {"\n\nonly", "only"}, {"first\n\n\n\nlast one\nline two", "last one\nline two"},
		{"a\r\nb\r\n", "a\r\nb\r"}, {"\nb", "b"},
	}
	for _, c := range cases {
		if got := lastParagraph(c.in); got != c.want {
			t.Errorf("lastParagraph(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestJQJoinPart(t *testing.T) {
	for _, c := range []struct {
		in   any
		want string
	}{{nil, ""}, {"s", "s"}, {5.0, "5"}, {1.5, "1.5"}, {true, "true"}, {false, "false"}} {
		if got, err := jqJoinPart(c.in); err != nil || got != c.want {
			t.Errorf("jqJoinPart(%v) = %q, %v; want %q", c.in, got, err, c.want)
		}
	}
	for _, bad := range []any{[]any{1.0}, map[string]any{"a": 1.0}} {
		if _, err := jqJoinPart(bad); !errors.Is(err, errShape) {
			t.Errorf("jqJoinPart(%v) err = %v, want errShape", bad, err)
		}
	}
}

func TestLastParagraphOfShapes(t *testing.T) {
	obj := func(msg any) map[string]any { return map[string]any{"message": msg} }
	text := func(s string) map[string]any { return map[string]any{"type": "text", "text": s} }
	for _, c := range []struct {
		name string
		in   map[string]any
		want string
		fail bool
	}{
		{"no message", map[string]any{}, "", false},
		{"null message", obj(nil), "", false},
		{"string content", obj(map[string]any{"content": "a\n\nb"}), "b", false},
		{"blocks joined", obj(map[string]any{"content": []any{text("a"), map[string]any{"type": "tool_use"}, nil, text("b")}}), "a\nb", false},
		{"content number", obj(map[string]any{"content": 5.0}), "", false},
		{"content null", obj(map[string]any{"content": nil}), "", false},
		{"message string", obj("x"), "", true},
		{"message array", obj([]any{}), "", true},
		{"element string", obj(map[string]any{"content": []any{"x"}}), "", true},
		{"text array", obj(map[string]any{"content": []any{map[string]any{"type": "text", "text": []any{}}}}), "", true},
		{"text missing is empty", obj(map[string]any{"content": []any{map[string]any{"type": "text"}, text("z")}}), "z", false},
	} {
		got, err := lastParagraphOf(c.in)
		if (err != nil) != c.fail || got != c.want {
			t.Errorf("%s: got %q, %v; want %q, fail=%v", c.name, got, err, c.want, c.fail)
		}
	}
}

func TestDecodeValues(t *testing.T) {
	vals, err := decodeValues([]byte("\xEF\xBB\xBF{\"a\":1} {\"b\":2}\n\n[3] null"))
	if err != nil || len(vals) != 4 {
		t.Fatalf("got %v, %v", vals, err)
	}
	if vals, err := decodeValues([]byte("")); err != nil || len(vals) != 0 {
		t.Errorf("empty input: %v, %v", vals, err)
	}
	if _, err := decodeValues([]byte("{\"a\":1}\nnot json")); err == nil {
		t.Error("invalid JSON accepted")
	}
	if _, err := decodeValues([]byte(`{"a":`)); err == nil {
		t.Error("truncated JSON accepted")
	}
}

func TestBuiltinVerdict(t *testing.T) {
	human := map[string]any{"kind": "human"}
	for _, c := range []struct {
		name     string
		obj      map[string]any
		op, comp bool
		fail     bool
	}{
		{"human turn", map[string]any{"type": "user", "origin": human}, true, false, false},
		{"tool result", map[string]any{"type": "user"}, false, false, false},
		{"null origin", map[string]any{"type": "user", "origin": nil}, false, false, false},
		{"peer origin", map[string]any{"type": "user", "origin": map[string]any{"kind": "peer"}}, false, false, false},
		{"kind number", map[string]any{"type": "user", "origin": map[string]any{"kind": 5.0}}, false, false, false},
		{"empty origin", map[string]any{"type": "user", "origin": map[string]any{}}, false, false, false},
		{"assistant with human origin", map[string]any{"type": "assistant", "origin": human}, false, false, false},
		{"assistant string origin skips the check", map[string]any{"type": "assistant", "origin": "x"}, false, false, false},
		{"user string origin", map[string]any{"type": "user", "origin": "x"}, false, false, true},
		{"user false origin", map[string]any{"type": "user", "origin": false}, false, false, true},
		{"boundary", map[string]any{"type": "system", "subtype": "compact_boundary"}, false, true, false},
		{"other subtype", map[string]any{"type": "system", "subtype": "x"}, false, false, false},
		{"boundary subtype on user", map[string]any{"type": "user", "subtype": "compact_boundary"}, false, false, false},
		{"summary true", map[string]any{"type": "user", "isCompactSummary": true}, false, true, false},
		{"summary zero is truthy", map[string]any{"type": "assistant", "isCompactSummary": 0.0}, false, true, false},
		{"summary false", map[string]any{"type": "user", "isCompactSummary": false}, false, false, false},
		{"summary null", map[string]any{"type": "user", "isCompactSummary": nil}, false, false, false},
	} {
		v, err := builtinVerdict(c.obj)
		if (err != nil) != c.fail || v.operator != c.op || v.compact != c.comp {
			t.Errorf("%s: got %+v, %v; want op=%v compact=%v fail=%v", c.name, v, err, c.op, c.comp, c.fail)
		}
	}
}

func TestBuildRows(t *testing.T) {
	rec := func(ts, typ string) map[string]any { return map[string]any{"timestamp": ts, "type": typ} }
	vals := []any{nil, rec("2026-06-01T00:20:00Z", "assistant"), rec("2026-06-01T00:10:00Z", "user"),
		map[string]any{"type": "user"}, map[string]any{"timestamp": "2026-06-01T00:30:00Z"}, rec("", "user"),
		rec("not a date", "user"), map[string]any{"timestamp": 5.0, "type": "user"}, rec("2026-06-01T00:10:00Z", "other")}
	rows, err := buildRows(vals, nil)
	if err != nil || len(rows) != 3 {
		t.Fatalf("rows = %+v, err %v", rows, err)
	}
	if rows[0].typ != "user" || rows[1].typ != "other" || rows[2].typ != "assistant" {
		t.Errorf("order (instant, then file order): %+v", rows)
	}
	if _, err := buildRows([]any{"scalar"}, nil); !errors.Is(err, errShape) {
		t.Errorf("non-object record: %v", err)
	}
	override := map[int]verdict{1: {operator: true}, 2: {compact: true}}
	rows, err = buildRows(vals, override)
	if err != nil || len(rows) != 2 || !rows[0].compact || !rows[1].operator {
		t.Errorf("override rows = %+v, err %v", rows, err)
	}
	bad := []any{map[string]any{"timestamp": "2026-06-01T00:10:00Z", "type": "user", "message": "x"}}
	if _, err := buildRows(bad, nil); !errors.Is(err, errShape) {
		t.Errorf("bad message: %v", err)
	}
}

func TestAnyOrigin(t *testing.T) {
	withOrigin := map[string]any{"origin": map[string]any{}}
	for _, c := range []struct {
		name string
		in   []any
		want bool
	}{
		{"empty", nil, false}, {"none", []any{map[string]any{"a": 1.0}}, false}, {"null origin", []any{map[string]any{"origin": nil}}, false},
		{"present", []any{withOrigin}, true}, {"after others", []any{nil, "x", map[string]any{}, withOrigin}, true},
		{"non-object only", []any{5.0, "x", nil}, false},
	} {
		if got := anyOrigin(c.in); got != c.want {
			t.Errorf("%s: anyOrigin = %v, want %v", c.name, got, c.want)
		}
	}
}
