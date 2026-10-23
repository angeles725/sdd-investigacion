package envelope_test

import (
	"bytes"
	"encoding/hex"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"unicode/utf8"

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

// fromGolden rebuilds a typed Envelope from a golden file. The golden's own key order is not asserted here:
// each instrument's order is pinned by the byte comparison against Pretty/Compact with that instrument's order.
func fromGolden(t *testing.T, raw []byte) envelope.Envelope {
	t.Helper()
	d := json.NewDecoder(bytes.NewReader(raw))
	d.UseNumber()
	top, ok := decodeOrdered(t, d).(envelope.Object)
	if !ok {
		t.Fatal("golden is not an object")
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

// goldens lists every recorded instrument output with the key order that instrument really prints
// (retro-gate.sh:422-426 and resume-state.sh:163-173 put reason before counts; sweep-retros.sh:579-590 and
// verify-registry.sh:83-91 put counts before reason; edge.golden is jq rendering of edge.in.json).
var goldens = []struct {
	name    string
	order   envelope.KeyOrder
	compact bool
}{
	{"sweep-retros-ok", envelope.CountsBeforeReason, false},
	{"sweep-retros-absent", envelope.CountsBeforeReason, false},
	{"verify-registry-ok", envelope.CountsBeforeReason, false},
	{"verify-registry-nomatch", envelope.CountsBeforeReason, false},
	{"resume-state-ok", envelope.ReasonBeforeCounts, false},
	{"retro-gate-block", envelope.ReasonBeforeCounts, false},
	{"retro-gate-none", envelope.ReasonBeforeCounts, false},
	{"edge", envelope.CountsBeforeReason, false},
	{"sweep-retros-degraded.compact", envelope.ReasonBeforeCounts, true},
	{"verify-registry-degraded.compact", envelope.ReasonBeforeCounts, true},
	{"resume-state-degraded.compact", envelope.ReasonBeforeCounts, true},
}

func render(e envelope.Envelope, order envelope.KeyOrder, compact bool) ([]byte, error) {
	if compact {
		return e.Compact(order)
	}
	return e.Pretty(order)
}

func TestRendererReproducesRealInstrumentGoldens(t *testing.T) {
	for _, g := range goldens {
		t.Run(g.name, func(t *testing.T) {
			raw := readFile(t, here(t), "testdata", g.name+".golden")
			e := fromGolden(t, raw)
			if err := e.Validate(); err != nil {
				t.Fatalf("golden does not satisfy the contract: %v", err)
			}
			got, err := render(e, g.order, g.compact)
			if err != nil {
				t.Fatal(err)
			}
			if !bytes.Equal(got, raw) {
				t.Fatalf("bytes differ\n got:\n%s\nwant:\n%s", got, raw)
			}
			// The order is a real input: the other order must NOT reproduce the golden.
			other := envelope.ReasonBeforeCounts
			if g.order == envelope.ReasonBeforeCounts {
				other = envelope.CountsBeforeReason
			}
			if alt, err := render(e, other, g.compact); err != nil || bytes.Equal(alt, raw) {
				t.Fatalf("the other key order also reproduces %s (err=%v); the order parameter is not exercised", g.name, err)
			}
		})
	}
}

func TestEveryGoldenIsRegistered(t *testing.T) {
	want := map[string]bool{"utf8-replace.golden": true}
	for _, g := range goldens {
		want[g.name+".golden"] = true
	}
	files, _ := filepath.Glob(filepath.Join(here(t), "testdata", "*.golden"))
	got := map[string]bool{}
	for _, f := range files {
		got[filepath.Base(f)] = true
	}
	for n := range want {
		if !got[n] {
			t.Errorf("registered golden %s is missing on disk (run testdata/regen.sh)", n)
		}
	}
	for n := range got {
		if !want[n] {
			t.Errorf("golden %s on disk is not registered in the test", n)
		}
	}
}

func TestTypedConstructionMatchesGoldens(t *testing.T) {
	absent := envelope.Envelope{
		Schema: "research-sdd.sweep-retros/v1",
		State:  state.AbsentInput,
		Reason: "every target corpus directory is absent",
		Counts: envelope.Object{{"targets", 1}, {"targets_absent", 1}, {"targets_skipped", 0}, {"retros", 0}, {"pending", 0}, {"missing_retro", 0}},
	}
	got, err := absent.Pretty(envelope.CountsBeforeReason)
	if err != nil {
		t.Fatal(err)
	}
	if want := readFile(t, here(t), "testdata", "sweep-retros-absent.golden"); !bytes.Equal(got, want) {
		t.Fatalf("typed absent-input envelope differs:\n%s", got)
	}

	allow := envelope.Envelope{
		Schema: "research-sdd.retro-gate/v1",
		State:  state.OK,
		Counts: envelope.Object{{"blocked", 0}, {"degraded_check", 0}, {"unverified", 0}},
		Items: []envelope.Object{{{"kind", "verdict"}, {"verdict", "allow"}, {"branch", "no-change"}, {"target", "target"},
			{"session_id", "j1-sess"}, {"check_mode", "session-sha"}, {"newest_retro", nil}, {"reason", nil}}},
	}
	got, err = allow.Pretty(envelope.ReasonBeforeCounts)
	if err != nil {
		t.Fatal(err)
	}
	if want := readFile(t, here(t), "testdata", "retro-gate-none.golden"); !bytes.Equal(got, want) {
		t.Fatalf("typed retro-gate allow envelope differs:\n%s", got)
	}
}

func TestDegradedMatchesTheHandBuiltLinesOfEveryInstrument(t *testing.T) {
	// The reasons are the ones the scripts print when jq is missing (real runs are in the *.compact.golden files).
	cases := map[string]struct{ schema, reason string }{
		"sweep-retros-degraded.compact":    {"research-sdd.sweep-retros/v1", "jq not found on PATH"},
		"verify-registry-degraded.compact": {"research-sdd.verify-registry/v1", "jq not found on PATH"},
		"resume-state-degraded.compact":    {"research-sdd.resume-state/v1", "jq not found; cannot build the JSON document"},
	}
	for name, c := range cases {
		e := envelope.Degraded(c.schema, c.reason)
		if err := e.Validate(); err != nil {
			t.Fatal(err)
		}
		got, err := e.Compact(envelope.ReasonBeforeCounts)
		want := readFile(t, here(t), "testdata", name+".golden")
		if err != nil || !bytes.Equal(got, want) {
			t.Errorf("%s: Compact() = %q, %v; want %q", name, got, err, want)
		}
		if code, err := e.ExitCode(); err != nil || code != 3 {
			t.Errorf("degraded ExitCode = %d, %v; want 3", code, err)
		}
	}
	p, err := envelope.Degraded("research-sdd.x/v1", "r").Pretty(envelope.ReasonBeforeCounts)
	if err != nil {
		t.Fatal(err)
	}
	if want := "{\n  \"schema\": \"research-sdd.x/v1\",\n  \"state\": \"degraded\",\n  \"reason\": \"r\",\n  \"counts\": {},\n  \"items\": []\n}\n"; string(p) != want {
		t.Errorf("Pretty degraded = %q", p)
	}
}

func TestKeyOrderMustBeChosen(t *testing.T) {
	e := envelope.Degraded("research-sdd.x/v1", "r")
	for _, o := range []envelope.KeyOrder{envelope.OrderInvalid, envelope.KeyOrder(99), envelope.KeyOrder(-1)} {
		if b, err := e.Pretty(o); err == nil {
			t.Errorf("Pretty(%d) rendered %q instead of failing", o, b)
		}
		if b, err := e.Compact(o); err == nil {
			t.Errorf("Compact(%d) rendered %q instead of failing", o, b)
		}
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
		"zero value":                     {},
		"bad schema":                     {Schema: "sweep-retros", State: state.OK, Items: okItems()},
		"v-less schema":                  {Schema: "research-sdd.a", State: state.OK, Items: okItems()},
		"invalid state":                  {Schema: "research-sdd.a/v1", State: state.Invalid, Reason: "r"},
		"ok without items":               {Schema: "research-sdd.a/v1", State: state.OK},
		"ok with reason":                 {Schema: "research-sdd.a/v1", State: state.OK, Reason: "r", Items: okItems()},
		"no-match with items":            {Schema: "research-sdd.a/v1", State: state.NoMatch, Reason: "r", Items: okItems()},
		"absent without reason":          {Schema: "research-sdd.a/v1", State: state.AbsentInput},
		"degraded without reason":        {Schema: "research-sdd.a/v1", State: state.Degraded},
		"item without kind":              {Schema: "research-sdd.a/v1", State: state.OK, Items: []envelope.Object{{{"x", 1}}}},
		"item kind not string":           {Schema: "research-sdd.a/v1", State: state.OK, Items: []envelope.Object{{{"kind", 1}}}},
		"count not integer":              {Schema: "research-sdd.a/v1", State: state.OK, Items: okItems(), Counts: envelope.Object{{"n", "3"}}},
		"count float":                    {Schema: "research-sdd.a/v1", State: state.OK, Items: okItems(), Counts: envelope.Object{{"n", 1.5}}},
		"duplicate count key":            {Schema: "research-sdd.a/v1", State: state.OK, Items: okItems(), Counts: envelope.Object{{"n", 1}, {"n", 2}}},
		"duplicate item key":             {Schema: "research-sdd.a/v1", State: state.OK, Items: []envelope.Object{{{"kind", "k"}, {"kind", "j"}}}},
		"kind later, other string first": {Schema: "research-sdd.a/v1", State: state.OK, Items: []envelope.Object{{{"x", "s"}, {"kind", "k"}}}},
		"kind not leading":               {Schema: "research-sdd.a/v1", State: state.OK, Items: []envelope.Object{{{"x", 1}, {"kind", "k"}}}},
		"nested duplicate key":           {Schema: "research-sdd.a/v1", State: state.OK, Items: []envelope.Object{{{"kind", "k"}, {"o", envelope.Object{{"a", 1}, {"a", 2}}}}}},
		"nested empty key":               {Schema: "research-sdd.a/v1", State: state.OK, Items: []envelope.Object{{{"kind", "k"}, {"o", envelope.Object{{"", 1}}}}}},
		"duplicate in object list":       {Schema: "research-sdd.a/v1", State: state.OK, Items: []envelope.Object{{{"kind", "k"}, {"l", []envelope.Object{{{"a", 1}, {"a", 2}}}}}}},
		"duplicate in any list":          {Schema: "research-sdd.a/v1", State: state.OK, Items: []envelope.Object{{{"kind", "k"}, {"l", []any{1, envelope.Object{{"a", 1}, {"a", 2}}}}}}},
		"deeply nested duplicate":        {Schema: "research-sdd.a/v1", State: state.OK, Items: []envelope.Object{{{"kind", "k"}, {"o", envelope.Object{{"p", []any{envelope.Object{{"q", envelope.Object{{"a", 1}, {"a", 2}}}}}}}}}}},
		"empty count key":                {Schema: "research-sdd.a/v1", State: state.OK, Items: okItems(), Counts: envelope.Object{{"", 1}}},
	}
	for name, e := range bad {
		t.Run(name, func(t *testing.T) {
			if err := e.Validate(); err == nil {
				t.Error("Validate accepted it")
			}
			if b, err := e.Pretty(envelope.ReasonBeforeCounts); err == nil {
				t.Errorf("Pretty rendered an invalid envelope: %s", b)
			}
			if b, err := e.Compact(envelope.ReasonBeforeCounts); err == nil {
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
	got, err := e.Pretty(envelope.CountsBeforeReason)
	if err != nil {
		t.Fatal(err)
	}
	want := `"v": "a\"b\\c\n\t\r\b\f\u0001\u007f é 😀 <>&/"`
	if !strings.Contains(string(got), want) {
		t.Errorf("got:\n%s\nwant substring %s", got, want)
	}
	if _, err := (envelope.Envelope{Schema: "research-sdd.a/v1", State: state.OK,
		Items: []envelope.Object{{{"kind", "k"}, {"v", "a\xffb"}}}}).Pretty(envelope.CountsBeforeReason); err == nil {
		t.Error("invalid UTF-8 must be an error")
	}
	if _, err := (envelope.Envelope{Schema: "research-sdd.a/v1", State: state.OK,
		Items: []envelope.Object{{{"kind", "k"}, {"v", struct{}{}}}}}).Pretty(envelope.CountsBeforeReason); err == nil {
		t.Error("an unsupported value type must be an error")
	}
}

// invalidUTF8Cases reads testdata/utf8-replace.golden: <hex bytes> TAB <what `jq -Rs .` printed for them>.
func invalidUTF8Cases(t *testing.T) (inputs [][]byte, want []string) {
	t.Helper()
	raw := readFile(t, here(t), "testdata", "utf8-replace.golden")
	for _, line := range strings.Split(strings.TrimRight(string(raw), "\n"), "\n") {
		hexIn, jqOut, ok := strings.Cut(line, "\t")
		if !ok {
			t.Fatalf("malformed utf8-replace.golden line %q", line)
		}
		b, err := hex.DecodeString(hexIn)
		if err != nil {
			t.Fatal(err)
		}
		var w string
		if err := json.Unmarshal([]byte(jqOut), &w); err != nil {
			t.Fatalf("jq output %q is not a JSON string: %v", jqOut, err)
		}
		inputs, want = append(inputs, b), append(want, w)
	}
	if len(inputs) < 10 {
		t.Fatalf("only %d utf-8 cases", len(inputs))
	}
	return inputs, want
}

func verdictWithReason(reason any) envelope.Envelope {
	return envelope.Envelope{Schema: "research-sdd.retro-gate/v1", State: state.OK,
		Counts: envelope.Object{{"blocked", 1}},
		Items:  []envelope.Object{{{"kind", "verdict"}, {"verdict", "block"}, {"reason", reason}}}}
}

// json-envelope.v1.md (retro-gate verdict item): the block reason equals the default decision's reason
// "except that bytes that are not valid UTF-8 become U+FFFD in the envelope". The replacement must be what
// jq -Rs produces, byte for byte, for every kind of invalid sequence.
func TestVerdictReasonInvalidUTF8BecomesReplacementCharacterLikeJq(t *testing.T) {
	inputs, want := invalidUTF8Cases(t)
	for i, in := range inputs {
		t.Run(hex.EncodeToString(in), func(t *testing.T) {
			out, err := verdictWithReason(string(in)).Pretty(envelope.ReasonBeforeCounts)
			if err != nil {
				t.Fatalf("contract-specified replacement must not be an error: %v", err)
			}
			var doc struct {
				Items []struct {
					Reason string `json:"reason"`
				} `json:"items"`
			}
			if err := json.Unmarshal(out, &doc); err != nil {
				t.Fatalf("output is not valid JSON: %v\n%s", err, out)
			}
			if got := doc.Items[0].Reason; got != want[i] {
				t.Fatalf("reason = %q, jq gives %q", got, want[i])
			}
			if !utf8.Valid(out) {
				t.Fatal("rendered envelope is not valid UTF-8")
			}
		})
	}
}

func TestInvalidUTF8OutsideTheVerdictReasonStaysAnError(t *testing.T) {
	bad := "a\xffb"
	cases := map[string]envelope.Envelope{
		"envelope reason":           {Schema: "research-sdd.a/v1", State: state.Degraded, Reason: bad},
		"verdict branch":            {Schema: "research-sdd.a/v1", State: state.OK, Items: []envelope.Object{{{"kind", "verdict"}, {"branch", bad}}}},
		"non-verdict item reason":   {Schema: "research-sdd.a/v1", State: state.OK, Items: []envelope.Object{{{"kind", "other"}, {"reason", bad}}}},
		"verdict reason in a list":  {Schema: "research-sdd.a/v1", State: state.OK, Items: []envelope.Object{{{"kind", "verdict"}, {"reasons", []any{bad}}}}},
		"verdict reason not string": {Schema: "research-sdd.a/v1", State: state.OK, Items: []envelope.Object{{{"kind", "verdict"}, {"reason", []byte(bad)}}}},
		"count key":                 {Schema: "research-sdd.a/v1", State: state.OK, Counts: envelope.Object{{bad, 1}}, Items: []envelope.Object{{{"kind", "k"}}}},
		"item key":                  {Schema: "research-sdd.a/v1", State: state.OK, Items: []envelope.Object{{{"kind", "k"}, {bad, 1}}}},
	}
	for name, e := range cases {
		if b, err := e.Pretty(envelope.ReasonBeforeCounts); err == nil {
			t.Errorf("%s: rendered %q, want an error", name, b)
		}
	}
	// A valid reason is untouched.
	b, err := verdictWithReason("héllo 😀").Pretty(envelope.ReasonBeforeCounts)
	if err != nil || !strings.Contains(string(b), `"reason": "héllo 😀"`) {
		t.Errorf("valid reason changed: %q, %v", b, err)
	}
}

// TestRegenIsReproducible runs the golden generator in --verify mode: two hermetic runs of the real
// instruments must be byte-identical to each other and to the committed goldens. A missing tool is a
// failure with a clear message, never a skip; only -short skips (the run builds repositories and corpora).
func TestRegenIsReproducible(t *testing.T) {
	if testing.Short() {
		t.Skip("regen.sh --verify runs the shell instruments twice; skipped under -short")
	}
	for _, tool := range []string{"bash", "jq", "git"} {
		if _, err := exec.LookPath(tool); err != nil {
			t.Fatalf("regen.sh --verify needs %q on PATH and it is missing (%v); install it, the golden drift check cannot run without it", tool, err)
		}
	}
	cmd := exec.Command("bash", filepath.Join("testdata", "regen.sh"), "--verify")
	cmd.Dir = here(t)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("golden drift: regen.sh --verify failed: %v\n%s\nfix: bash testdata/regen.sh (in %s) and review the diff", err, out, cmd.Dir)
	}
}
