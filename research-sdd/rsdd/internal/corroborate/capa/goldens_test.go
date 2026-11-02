package capa

// Golden replay. The legacy Python tool is the oracle, but it is only run by the differential tests (build tag
// !nodiff, goldens_update_linux_test.go), which also prove these files are not stale. This test has no tag and
// runs no Python: it replays every recorded oracle answer through the Go code, so the mutation run (which
// builds with -tags nodiff) still has something that checks the logic the oracle used to check alone.
//
// Files under testdata/goldens/ (regenerate with RSDD_UPDATE_GOLDENS=1 go test -run TestGoldensMatchOracle):
//   usage.json      help and usage text per $COLUMNS value
//   args.json       argv -> parsed values, argparse error message or help
//   jsonread.json   capa stdout document -> value / malformed-JSON message / crash
//   inventory.json  parsed capa document + cap -> bounded inventory, limitations / crash

import (
	"encoding/hex"
	"encoding/json"
	"errors"
	"math"
	"math/big"
	"os"
	"strings"
	"testing"
	"unicode/utf8"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/jsonout"
)

const goldenDir = "testdata/goldens/"

type usageGolden struct {
	Cols  string `json:"cols"`
	Usage string `json:"usage"`
	Help  string `json:"help"`
}

type argsGolden struct {
	Argv []string          `json:"argv"`
	Kind string            `json:"kind"` // ok | error | help
	Msg  string            `json:"msg,omitempty"`
	NS   map[string]string `json:"ns,omitempty"`
}

// docGolden is a capa stdout document (Doc, or Hex when it is not valid UTF-8) and what the oracle did with it.
type docGolden struct {
	Doc   string   `json:"doc,omitempty"`
	Hex   string   `json:"hex,omitempty"`
	Max   string   `json:"max,omitempty"` // decimal: the cap may exceed int64
	OK    bool     `json:"ok"`
	Value string   `json:"value,omitempty"`
	Err   *string  `json:"err,omitempty"`
	Lims  []string `json:"lims,omitempty"`
	Lone  bool     `json:"lone,omitempty"` // the document holds a lone surrogate, which the port reports as an internal error
}

func (g docGolden) bytes(t testing.TB) []byte {
	if g.Hex == "" {
		return []byte(g.Doc)
	}
	b, err := hex.DecodeString(g.Hex)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

// newDocGolden stores a document as text when it is valid UTF-8 and as hex otherwise.
func newDocGolden(doc []byte) docGolden {
	if utf8.Valid(doc) {
		return docGolden{Doc: string(doc)}
	}
	return docGolden{Hex: hex.EncodeToString(doc)}
}

func loadGolden[T any](t testing.TB, name string) []T {
	t.Helper()
	b, err := os.ReadFile(goldenDir + name)
	if err != nil {
		t.Fatalf("golden %s: %v (regenerate with RSDD_UPDATE_GOLDENS=1)", name, err)
	}
	var f struct {
		Cases []T `json:"cases"`
	}
	if err := json.Unmarshal(b, &f); err != nil {
		t.Fatalf("golden %s: %v", name, err)
	}
	if len(f.Cases) == 0 {
		t.Fatalf("golden %s holds no cases", name)
	}
	return f.Cases
}

func TestGoldenUsageAndHelp(t *testing.T) {
	for _, g := range loadGolden[usageGolden](t, "usage.json") {
		w := terminalWidth(g.Cols)
		if got := usageText(w); got != g.Usage {
			t.Errorf("COLUMNS=%q usage:\nwant %q\ngot  %q", g.Cols, g.Usage, got)
		}
		if got := helpText(w); got != g.Help {
			t.Errorf("COLUMNS=%q help:\nwant %q\ngot  %q", g.Cols, g.Help, got)
		}
	}
}

func TestGoldenArgs(t *testing.T) {
	for _, g := range loadGolden[argsGolden](t, "args.json") {
		o, err := parseArgs(g.Argv)
		var ae *argError
		switch {
		case errors.Is(err, errHelp):
			if g.Kind != "help" {
				t.Errorf("%q: got help, want %s %q", g.Argv, g.Kind, g.Msg)
			}
		case errors.As(err, &ae):
			if g.Kind != "error" || ae.msg != g.Msg {
				t.Errorf("%q: got error %q, want %s %q", g.Argv, ae.msg, g.Kind, g.Msg)
			}
		case err != nil:
			t.Errorf("%q: unexpected %v", g.Argv, err)
		default:
			got := map[string]string{"input": o.input, "output": o.output, "rules": o.rules, "manifest_cli": o.manifestCLI,
				"timeout": o.timeout.String(), "max_capabilities": o.maxCapabilities.String()}
			if g.Kind != "ok" || len(got) != len(g.NS) {
				t.Errorf("%q: parsed, want %s %q", g.Argv, g.Kind, g.Msg)
			}
			for k, v := range g.NS {
				if got[k] != v {
					t.Errorf("%q: %s = %q, want %q", g.Argv, k, got[k], v)
				}
			}
		}
	}
}

// canonOrErr is the canonical JSON of v, or "" and false when Python's json.dumps(allow_nan=False) would raise.
func canonOrErr(v any) (string, bool) {
	b, err := jsonout.Canonical(pyFloats(v))
	if err != nil {
		return "", false
	}
	return strings.TrimSuffix(string(b), "\n"), true
}

func TestGoldenJSONRead(t *testing.T) {
	for _, g := range loadGolden[docGolden](t, "jsonread.json") {
		doc := g.bytes(t)
		v, msg, err := parseCapaOutput(doc)
		if !g.OK {
			if err == nil {
				if _, ok := canonOrErr(v); ok {
					t.Errorf("%q: the oracle raised, the port returned %v %q", doc, v, msg)
				}
			}
			continue
		}
		var c *crash
		isCrash := errors.As(err, &c)
		if isCrash && c.msg == msgWideEncoding {
			continue // documented limit of the port: UTF-16/32 documents
		}
		if g.Lone { // documented limit of the port: a string that Python holds but Go cannot
			if !isCrash || c.msg != msgLoneSurrogate {
				t.Errorf("%q: holds a lone surrogate, want the lone-surrogate crash, got %v", doc, err)
			}
			continue
		}
		if err != nil {
			t.Errorf("%q: the oracle returned, the port failed: %v", doc, err)
			continue
		}
		wantErr := ""
		if g.Err != nil {
			wantErr = *g.Err
		}
		if msg != wantErr {
			t.Errorf("%q: message want %q, got %q", doc, wantErr, msg)
		}
		if v != nil || g.Value != "null" {
			if got, ok := canonOrErr(v); !ok || got != g.Value {
				t.Errorf("%q: value want %s, got %s", doc, g.Value, got)
			}
		}
	}
}

type wrapGolden struct {
	Text  string   `json:"text"`
	Width int      `json:"width"`
	Lines []string `json:"lines"`
}

func TestGoldenWrap(t *testing.T) {
	for _, g := range loadGolden[wrapGolden](t, "wrap.json") {
		got := wrapText(g.Text, g.Width)
		if strings.Join(got, "\n") != strings.Join(g.Lines, "\n") || len(got) != len(g.Lines) {
			t.Errorf("wrap(%q, %d):\nwant %q\ngot  %q", g.Text, g.Width, g.Lines, got)
		}
	}
}

// pyFloats rewrites NaN and the infinities the way the oracle does ({"$f": repr}), because json.dumps cannot
// print them with allow_nan=False.
func pyFloats(v any) any {
	switch x := v.(type) {
	case float64:
		switch {
		case math.IsNaN(x):
			return map[string]any{"$f": "nan"}
		case math.IsInf(x, 1):
			return map[string]any{"$f": "inf"}
		case math.IsInf(x, -1):
			return map[string]any{"$f": "-inf"}
		}
	case []any:
		out := make([]any, len(x))
		for i, e := range x {
			out[i] = pyFloats(e)
		}
		return out
	case map[string]any:
		out := make(map[string]any, len(x))
		for k, e := range x {
			out[k] = pyFloats(e)
		}
		return out
	}
	return v
}

func TestGoldenInventory(t *testing.T) {
	for _, g := range loadGolden[docGolden](t, "inventory.json") {
		doc := g.bytes(t)
		limit, _ := new(big.Int).SetString(g.Max, 10)
		if limit == nil {
			t.Fatalf("golden cap %q is not a decimal", g.Max)
		}
		v, derr := decodeJSON(doc)
		var inv inventory
		var lims []string
		err := derr
		if err == nil {
			inv, lims, err = buildInventory(v, limit)
		}
		if !g.OK {
			if err == nil {
				t.Errorf("max=%s %q: the oracle raised, the port returned %+v", g.Max, doc, inv)
			}
			continue
		}
		if err != nil {
			t.Errorf("max=%s %q: the oracle returned, the port failed: %v", g.Max, doc, err)
			continue
		}
		got, _ := canonOrErr(map[string]any{"items": inv.items, "total_count": inv.totalCount, "total_sampled": inv.totalSampled, "truncated": inv.truncated})
		if got != g.Value {
			t.Errorf("max=%s %q:\nwant %s\ngot  %s", g.Max, doc, g.Value, got)
		}
		if strings.Join(lims, "|") != strings.Join(g.Lims, "|") {
			t.Errorf("max=%s %q: limitations want %v, got %v", g.Max, doc, g.Lims, lims)
		}
	}
}
