package envelope_test

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/envelope"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/state"
)

func here(t *testing.T) string {
	t.Helper()
	_, file, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("runtime.Caller failed")
	}
	return filepath.Dir(file)
}

func readFile(t *testing.T, parts ...string) []byte {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(parts...))
	if err != nil {
		t.Fatalf("fixture must exist: %v", err)
	}
	return b
}

// decodeOrdered parses JSON keeping object key order. Objects become envelope.Object, arrays []any,
// numbers int64 (the envelope carries integers only).
func decodeOrdered(t *testing.T, d *json.Decoder) any {
	t.Helper()
	tok, err := d.Token()
	if err != nil {
		t.Fatal(err)
	}
	switch x := tok.(type) {
	case json.Delim:
		if x == '{' {
			obj := envelope.Object{}
			for d.More() {
				k, err := d.Token()
				if err != nil {
					t.Fatal(err)
				}
				obj = append(obj, envelope.Field{Key: k.(string), Value: decodeOrdered(t, d)})
			}
			if _, err := d.Token(); err != nil {
				t.Fatal(err)
			}
			return obj
		}
		arr := []any{}
		for d.More() {
			arr = append(arr, decodeOrdered(t, d))
		}
		if _, err := d.Token(); err != nil {
			t.Fatal(err)
		}
		return arr
	case json.Number:
		n, err := x.Int64()
		if err != nil {
			t.Fatalf("non-integer number %s", x)
		}
		return n
	default:
		return tok
	}
}

func get(o envelope.Object, key string) (any, bool) {
	for _, f := range o {
		if f.Key == key {
			return f.Value, true
		}
	}
	return nil, false
}

// fromGolden rebuilds a typed Envelope from a golden file, checking the golden's own key order on the way.
func fromGolden(t *testing.T, raw []byte) envelope.Envelope {
	t.Helper()
	d := json.NewDecoder(bytes.NewReader(raw))
	d.UseNumber()
	top, ok := decodeOrdered(t, d).(envelope.Object)
	if !ok {
		t.Fatal("golden is not an object")
	}
	var keys []string
	for _, f := range top {
		keys = append(keys, f.Key)
	}
	if got := strings.Join(keys, ","); got != "schema,state,counts,reason,items" {
		t.Fatalf("golden key order = %s", got)
	}
	var e envelope.Envelope
	v, _ := get(top, "schema")
	e.Schema = v.(string)
	v, _ = get(top, "state")
	s, err := state.Parse(v.(string))
	if err != nil {
		t.Fatal(err)
	}
	e.State = s
	v, _ = get(top, "counts")
	e.Counts = v.(envelope.Object)
	v, _ = get(top, "reason")
	if r, ok := v.(string); ok {
		e.Reason = r
	}
	v, _ = get(top, "items")
	for _, it := range v.([]any) {
		e.Items = append(e.Items, it.(envelope.Object))
	}
	return e
}

var goldens = []string{"sweep-retros-ok", "sweep-retros-absent", "verify-registry-ok", "verify-registry-nomatch", "edge"}

func TestPrettyReproducesRealInstrumentGoldens(t *testing.T) {
	for _, name := range goldens {
		t.Run(name, func(t *testing.T) {
			raw := readFile(t, here(t), "testdata", name+".golden")
			e := fromGolden(t, raw)
			if err := e.Validate(); err != nil {
				t.Fatalf("golden does not satisfy the contract: %v", err)
			}
			got, err := e.Pretty()
			if err != nil {
				t.Fatal(err)
			}
			if !bytes.Equal(got, raw) {
				t.Fatalf("bytes differ\n got:\n%s\nwant:\n%s", got, raw)
			}
		})
	}
}

func TestGoldenSetIsComplete(t *testing.T) {
	files, _ := filepath.Glob(filepath.Join(here(t), "testdata", "*.golden"))
	if len(files) != len(goldens) {
		t.Fatalf("%d golden files on disk, %d registered in the test", len(files), len(goldens))
	}
}

func TestTypedConstructionMatchesGoldens(t *testing.T) {
	absent := envelope.Envelope{
		Schema: "research-sdd.sweep-retros/v1",
		State:  state.AbsentInput,
		Reason: "every target corpus directory is absent",
		Counts: envelope.Object{{"targets", 1}, {"targets_absent", 1}, {"targets_skipped", 0}, {"retros", 0}, {"pending", 0}, {"missing_retro", 0}},
	}
	got, err := absent.Pretty()
	if err != nil {
		t.Fatal(err)
	}
	if want := readFile(t, here(t), "testdata", "sweep-retros-absent.golden"); !bytes.Equal(got, want) {
		t.Fatalf("typed absent-input envelope differs:\n%s", got)
	}

	ok := envelope.Envelope{
		Schema: "research-sdd.sweep-retros/v1",
		State:  state.OK,
		Counts: envelope.Object{{"targets", 2}, {"targets_absent", 1}, {"targets_skipped", 0}, {"retros", 3}, {"pending", 2}, {"missing_retro", 0}},
		Items: []envelope.Object{
			{{"kind", "pending-retro"}, {"file", "@KIT@/targetA/retros/p1.md"}, {"target", "@KIT@/targetA"}, {"deltas", 3},
				{"deltas_state", "counted"}, {"status", "pending"}, {"age_days", 0}, {"age_state", "counted"},
				{"escalated", false}, {"warning", nil}},
			{{"kind", "pending-retro"}, {"file", "@KIT@/targetA/retros/n1.md"}, {"target", "@KIT@/targetA"}, {"deltas", 1},
				{"deltas_state", "counted"}, {"status", "none"}, {"age_days", 0}, {"age_state", "counted"},
				{"escalated", false}, {"warning", nil}},
		},
	}
	got, err = ok.Pretty()
	if err != nil {
		t.Fatal(err)
	}
	if want := readFile(t, here(t), "testdata", "sweep-retros-ok.golden"); !bytes.Equal(got, want) {
		t.Fatalf("typed ok envelope differs:\n%s", got)
	}
}

func TestCompactIsTheHandBuiltDegradedLine(t *testing.T) {
	// Literal copied from verify-registry.sh / sweep-retros.sh (the printf used when jq is missing).
	cases := map[string]string{
		"research-sdd.verify-registry/v1": `{"schema":"research-sdd.verify-registry/v1","state":"degraded","reason":"jq not found on PATH","counts":{},"items":[]}` + "\n",
		"research-sdd.sweep-retros/v1":    `{"schema":"research-sdd.sweep-retros/v1","state":"degraded","reason":"jq not found on PATH","counts":{},"items":[]}` + "\n",
	}
	for schema, want := range cases {
		e := envelope.Degraded(schema, "jq not found on PATH")
		if err := e.Validate(); err != nil {
			t.Fatal(err)
		}
		got, err := e.Compact()
		if err != nil || string(got) != want {
			t.Errorf("Compact() = %q, %v; want %q", got, err, want)
		}
		if code, err := e.ExitCode(); err != nil || code != 3 {
			t.Errorf("degraded ExitCode = %d, %v; want 3", code, err)
		}
	}
	// The degraded envelope pretty-prints with empty containers inline.
	p, err := envelope.Degraded("research-sdd.x/v1", "r").Pretty()
	if err != nil {
		t.Fatal(err)
	}
	if want := "{\n  \"schema\": \"research-sdd.x/v1\",\n  \"state\": \"degraded\",\n  \"counts\": {},\n  \"reason\": \"r\",\n  \"items\": []\n}\n"; string(p) != want {
		t.Errorf("Pretty degraded = %q", p)
	}
}

func okItems() []envelope.Object { return []envelope.Object{{{"kind", "k"}}} }

func TestValidateAcceptsEveryStateShape(t *testing.T) {
	good := []envelope.Envelope{
		{Schema: "research-sdd.a/v1", State: state.OK, Items: okItems()},
		{Schema: "research-sdd.a/v1", State: state.AbsentInput, Reason: "r"},
		{Schema: "research-sdd.a/v1", State: state.EmptyInput, Reason: "r"},
		{Schema: "research-sdd.a/v1", State: state.NoMatch, Reason: "r"},
		{Schema: "research-sdd.a/v1", State: state.Degraded, Reason: "r"},
	}
	for _, e := range good {
		if err := e.Validate(); err != nil {
			t.Errorf("%v: %v", e.State, err)
		}
		if code, err := e.ExitCode(); err != nil || (e.State == state.Degraded) != (code == 3) {
			t.Errorf("%v: exit %d, %v", e.State, code, err)
		}
	}
}

func TestValidateRejectsContractViolations(t *testing.T) {
	bad := map[string]envelope.Envelope{
		"zero value":              {},
		"bad schema":              {Schema: "sweep-retros", State: state.OK, Items: okItems()},
		"v-less schema":           {Schema: "research-sdd.a", State: state.OK, Items: okItems()},
		"invalid state":           {Schema: "research-sdd.a/v1", State: state.Invalid, Reason: "r"},
		"ok without items":        {Schema: "research-sdd.a/v1", State: state.OK},
		"ok with reason":          {Schema: "research-sdd.a/v1", State: state.OK, Reason: "r", Items: okItems()},
		"no-match with items":     {Schema: "research-sdd.a/v1", State: state.NoMatch, Reason: "r", Items: okItems()},
		"absent without reason":   {Schema: "research-sdd.a/v1", State: state.AbsentInput},
		"degraded without reason": {Schema: "research-sdd.a/v1", State: state.Degraded},
		"item without kind":       {Schema: "research-sdd.a/v1", State: state.OK, Items: []envelope.Object{{{"x", 1}}}},
		"item kind not string":    {Schema: "research-sdd.a/v1", State: state.OK, Items: []envelope.Object{{{"kind", 1}}}},
		"count not integer":       {Schema: "research-sdd.a/v1", State: state.OK, Items: okItems(), Counts: envelope.Object{{"n", "3"}}},
		"count float":             {Schema: "research-sdd.a/v1", State: state.OK, Items: okItems(), Counts: envelope.Object{{"n", 1.5}}},
		"duplicate count key":     {Schema: "research-sdd.a/v1", State: state.OK, Items: okItems(), Counts: envelope.Object{{"n", 1}, {"n", 2}}},
		"duplicate item key":      {Schema: "research-sdd.a/v1", State: state.OK, Items: []envelope.Object{{{"kind", "k"}, {"kind", "j"}}}},
		"empty count key":         {Schema: "research-sdd.a/v1", State: state.OK, Items: okItems(), Counts: envelope.Object{{"", 1}}},
	}
	for name, e := range bad {
		t.Run(name, func(t *testing.T) {
			if err := e.Validate(); err == nil {
				t.Error("Validate accepted it")
			}
			if b, err := e.Pretty(); err == nil {
				t.Errorf("Pretty rendered an invalid envelope: %s", b)
			}
			if b, err := e.Compact(); err == nil {
				t.Errorf("Compact rendered an invalid envelope: %s", b)
			}
		})
	}
}

func TestExitCodeMatchesStatePackage(t *testing.T) {
	for _, s := range state.All() {
		e := envelope.Envelope{Schema: "research-sdd.a/v1", State: s, Reason: "r", Items: okItems()}
		want, _ := s.ExitCode()
		got, err := e.ExitCode()
		if err != nil || got != want {
			t.Errorf("%v: ExitCode %d, %v; want %d", s, got, err, want)
		}
	}
	if _, err := (envelope.Envelope{}).ExitCode(); err == nil {
		t.Error("zero envelope must not have an exit code")
	}
}

func TestStringEscapingMatchesJq(t *testing.T) {
	e := envelope.Envelope{Schema: "research-sdd.a/v1", State: state.OK,
		Items: []envelope.Object{{{"kind", "k"}, {"v", "a\"b\\c\n\t\r\b\f\x01\x7f é 😀 <>&/"}}}}
	got, err := e.Pretty()
	if err != nil {
		t.Fatal(err)
	}
	want := `"v": "a\"b\\c\n\t\r\b\f\u0001\u007f é 😀 <>&/"`
	if !strings.Contains(string(got), want) {
		t.Errorf("got:\n%s\nwant substring %s", got, want)
	}
	if _, err := (envelope.Envelope{Schema: "research-sdd.a/v1", State: state.OK,
		Items: []envelope.Object{{{"kind", "k"}, {"v", "a\xffb"}}}}).Pretty(); err == nil {
		t.Error("invalid UTF-8 must be an error")
	}
	if _, err := (envelope.Envelope{Schema: "research-sdd.a/v1", State: state.OK,
		Items: []envelope.Object{{{"kind", "k"}, {"v", struct{}{}}}}}).Pretty(); err == nil {
		t.Error("an unsupported value type must be an error")
	}
}

// TestResumeStateIsOutOfEnvelopeScope documents a contract gap: `resume-state.sh --json` is NOT an envelope
// of this renderer. Its recorded document has worktrees/base_ref at the top level and no state, counts or
// items, so core/envelope deliberately does not map it. Whoever ports resume-state needs its own shape.
func TestResumeStateIsOutOfEnvelopeScope(t *testing.T) {
	p := filepath.Join(here(t), "..", "..", "..", "..", "toolbelt", "tests", "fixtures", "resume-state", "json-envelope", "default-output.golden")
	raw := readFile(t, p)
	var doc map[string]json.RawMessage
	if err := json.Unmarshal(raw, &doc); err != nil {
		t.Fatalf("resume-state golden is not JSON: %v", err)
	}
	for _, k := range []string{"schema", "worktrees", "base_ref"} {
		if _, ok := doc[k]; !ok {
			t.Errorf("resume-state document lacks %q", k)
		}
	}
	for _, k := range []string{"state", "counts", "items"} {
		if _, ok := doc[k]; ok {
			t.Errorf("resume-state document unexpectedly carries envelope key %q", k)
		}
	}
	var schema string
	_ = json.Unmarshal(doc["schema"], &schema)
	if schema != "research-sdd.resume-state/v1" {
		t.Errorf("schema = %q", schema)
	}
	// It does not decode into an Envelope either: no state means no valid envelope.
	e := envelope.Envelope{Schema: schema}
	if err := e.Validate(); err == nil {
		t.Error("an envelope built from the resume-state document must not validate")
	}
}
