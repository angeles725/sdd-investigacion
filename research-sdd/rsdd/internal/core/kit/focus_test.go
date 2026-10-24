package kit

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Ports of toolbelt/tests/focus-prefix-range.test.sh sections 1-6 (kit #906) and the derive_focus_prefix contract.

const rootState = "`RESEARCH-STATE.md`"

// niagaraHeader is the FOCUSES.md layout of the bash suite: 5 data cells, the block cell last.
const niagaraHeader = "| Focus | Estado | RESEARCH-STATE | Ámbito | Bloques |\n|---|---|---|---|---|\n"

// focusCorpus writes dir/FOCUSES.md (header + rows, exactly as given) and an empty dir/RESEARCH-STATE.md, and
// returns the state file path.
func focusCorpus(t *testing.T, dir, table string) string {
	t.Helper()
	write(t, filepath.Join(dir, "FOCUSES.md"), table)
	return write(t, filepath.Join(dir, "RESEARCH-STATE.md"), "")
}

func rootRow(cell4, cell5 string) string {
	return "| (base) | stopped | " + rootState + " | " + cell4 + " | " + cell5 + " |\n"
}

type rangeCase struct {
	label, table, want string // want is the bash stdout value without its newline
}

// rangeCases is shared with the differential test.
var rangeCases = []rangeCase{
	{"1a en dash", niagaraHeader + rootRow("Framework base", "B1–B130"), "1-130"},
	{"1b hyphen", niagaraHeader + rootRow("x", "B2-B9"), "2-9"},
	{"1c single block, backticked", niagaraHeader + rootRow("x", "`B3–B3`"), "3-3"},
	{"1d bold", niagaraHeader + rootRow("x", "**B4–B8**"), "4-8"},
	{"1e lower-case b and leading zeros", niagaraHeader + rootRow("x", "b007-B10"), "7-10"},
	{"1f huge numbers print like awk", niagaraHeader + rootRow("x", "B1-B99999999999999999999"), "1-100000000000000000000"},
	{"1g past the double range is +inf", niagaraHeader + rootRow("x", "B1-B"+strings.Repeat("9", 400)), "1-+inf"},
	{"1h +inf > 1 is malformed", niagaraHeader + rootRow("x", "B"+strings.Repeat("9", 400)+"-B1"), "!B" + strings.Repeat("9", 400) + "-B1"},
	{"2a root row first", niagaraHeader + rootRow("x", "B1–B5") + "| o | a | `RESEARCH-STATE-o.md` | y | o- |\n", "1-5"},
	{"2b root row last", niagaraHeader + "| o | a | `RESEARCH-STATE-o.md` | y | o- |\n" + rootRow("x", "B1–B5"), "1-5"},
	{"2c only the first root row counts", niagaraHeader + rootRow("x", "B1–B5") + rootRow("x", "B6–B9"), "1-5"},
	{"3 a range on another row", niagaraHeader + "| o | a | `RESEARCH-STATE-o.md` | y | B1–B5 |\n" + rootRow("x", "free text"), ""},
	{"5a a > b is malformed", niagaraHeader + rootRow("x", "B9–B3"), "!B9–B3"},
	{"6b no root row", niagaraHeader + "| o | a | `RESEARCH-STATE-o.md` | y | o- |\n", ""},
	{"6d trailing words", niagaraHeader + rootRow("x", "B1–B130 extra words"), "!B1–B130 extra words"},
	{"6e em dash spaced", niagaraHeader + rootRow("x", "B1 — B130"), "!B1 — B130"},
	{"6e em dash", niagaraHeader + rootRow("x", "B1—B130"), "!B1—B130"},
	{"6e non-breaking hyphen", niagaraHeader + rootRow("x", "B1‑B130"), "!B1‑B130"},
	{"6e minus sign", niagaraHeader + rootRow("x", "B1−B130"), "!B1−B130"},
	{"6e spaced en dash", niagaraHeader + rootRow("x", "B1 – B130"), "!B1 – B130"},
	{"6e bare second number", niagaraHeader + rootRow("x", "B1–130"), "!B1–130"},
	{"6e open ended", niagaraHeader + rootRow("x", "B1157–"), "!B1157–"},
	{"6e list", niagaraHeader + rootRow("x", "B841–B861, B866"), "!B841–B861, B866"},
	{"6f prose mentioning blocks", niagaraHeader + rootRow("cubre B77/B96 y B106, B117-B122", "no range"), ""},
	{"6g the header-named cell wins", niagaraHeader + rootRow("B7–B8", "B1–B3"), "1-3"},
	{"6i last cell without a closing pipe", niagaraHeader + "| (base) | stopped | " + rootState + " | x | B2–B9\n", "2-9"},
	{"7j.1 Block prefix and Blocks columns", "| Focus | Status | State file | Block prefix | Blocks | Summary |\n|---|---|---|---|---|---|\n" +
		"| hvac | stopped | RESEARCH-STATE.md | cob-block | B1–B38 | HVAC |\n", "1-38"},
	{"7j.4 Blocked-by is not the range header", "| Focus | Estado | State file | Blocked by | Notes |\n|---|---|---|---|---|\n" + rootRow("none", "B5–B9"), "5-9"},
	{"7j.5 header cell not range-shaped: fallback", "| Focus | Estado | State file | Blocks | Notes |\n|---|---|---|---|---|\n" + rootRow("see notes", "B2–B4"), "2-4"},
	{"header cell not range-shaped, none other", "| Focus | Estado | State file | Blocks | Notes |\n|---|---|---|---|---|\n" + rootRow("see notes", "x"), ""},
	{"header beyond the row", "| a | b | c | d | e | f | Rango |\n|---|---|---|---|---|---|---|\n" + rootRow("B1-B2", "B3-B4"), "1-2"},
	{"header vocabulary is case-blind and decorated", "| Focus | Estado | State | x | **BLOCK RANGE** |\n|:-|-:|:-:|---|---|\n" + rootRow("B1-B2", "B3-B4"), "3-4"},
	{"the first range header wins", "| F | S | State | Blocks | Rango |\n|---|---|---|---|---|\n" + rootRow("B1-B2", "B3-B4"), "1-2"},
	{"a second separator clears the header", "| F | S | State | x | Bloques |\n|---|---|---|---|---|\n|---|---|---|---|---|\n" + rootRow("B1-B2", "B3-B4"), "1-2"},
	{"header lower-casing is ASCII only (Kelvin sign)", "| F | S | State | x | BLOC\u212a |\n|---|---|---|---|---|\n" + rootRow("B1-B2", "B3-B4"), "1-2"},
	{"bracketed state link", niagaraHeader + "| b | s | [RESEARCH-STATE.md](RESEARCH-STATE.md) | x | B1-B2 |\n", "1-2"},
	{"state cell must start the row at column 0", niagaraHeader + " " + rootRow("x", "B1-B2"), ""},
	{"no table at all", "# just prose B1–B9\n", ""},
	{"empty FOCUSES.md", "", ""},
}

func TestDeriveFocusRange(t *testing.T) {
	for _, c := range rangeCases {
		t.Run(c.label, func(t *testing.T) {
			sf := focusCorpus(t, t.TempDir(), c.table)
			r, err := DeriveFocusRange(sf)
			if err != nil || r.Value() != c.want {
				t.Fatalf("got %q (%v), want %q", r.Value(), err, c.want)
			}
			if (c.want == "") != (r.State == RangeNoCell) || strings.HasPrefix(c.want, "!") != (r.State == RangeMalformed) {
				t.Fatalf("state %v does not type %q", r.State, c.want)
			}
		})
	}
}

func TestDeriveFocusRangeStates(t *testing.T) {
	d := t.TempDir()
	sf := write(t, d+"/RESEARCH-STATE.md", "")
	if r, err := DeriveFocusRange(sf); err != nil || r.State != RangeNoFocuses || r.Value() != "" {
		t.Fatalf("no FOCUSES.md: %+v %v", r, err)
	}
	focusCorpus(t, d, niagaraHeader+rootRow("x", "B1-B9"))
	if r, err := DeriveFocusRange(d + "/RESEARCH-STATE-o.md"); err != nil || r.State != RangeNotRoot {
		t.Fatalf("a suffixed state file never reads a range: %+v %v", r, err)
	}
	if r, _ := DeriveFocusRange(sf); r.State != RangeOK || r.Lo != 1 || r.Hi != 9 {
		t.Fatalf("ok: %+v", r)
	}
	if os.Geteuid() == 0 {
		t.Skip("running as root: chmod 000 stays readable, premise unavailable (NOT a pass)")
	}
	if err := os.Chmod(d+"/FOCUSES.md", 0); err != nil {
		t.Fatal(err)
	}
	if _, err := DeriveFocusRange(sf); !errors.Is(err, ErrUnreadable) {
		t.Fatalf("an unreadable FOCUSES.md is typed: %v", err)
	}
}

type prefixCase struct {
	label, stateBase, table string
	want                    FocusPrefix
}

// prefixCases is shared with the differential test.
var prefixCases = []prefixCase{
	{"suffixed name", "RESEARCH-STATE-auth.md", "", FocusPrefix{"auth-", PrefixFromName}},
	{"suffixed name, empty slug", "RESEARCH-STATE-.md", "", FocusPrefix{"-", PrefixFromName}},
	{"suffixed name wins over FOCUSES.md", "RESEARCH-STATE-a.b.md", niagaraHeader + rootRow("base-", "x"), FocusPrefix{"a.b-", PrefixFromName}},
	{"not a state file", "NOTES.md", niagaraHeader + rootRow("base-", "x"), FocusPrefix{"", PrefixNotState}},
	{"no FOCUSES.md", "RESEARCH-STATE.md", "", FocusPrefix{"", PrefixNoFocuses}},
	{"4a a range cell is no prefix", "RESEARCH-STATE.md", niagaraHeader + rootRow("x", "B1–B130"), FocusPrefix{"", PrefixNoRow}},
	{"4b 4-column layout", "RESEARCH-STATE.md", "| Focus | Status | State | Block prefix |\n|---|---|---|---|\n| (base) | stopped | " + rootState + " | base- |\n", FocusPrefix{"base-", PrefixFromFocuses}},
	{"4c prefix and range on one row", "RESEARCH-STATE.md", niagaraHeader + rootRow("base-", "B1–B9"), FocusPrefix{"base-", PrefixFromFocuses}},
	{"a file-pattern cell is cut at block", "RESEARCH-STATE.md", niagaraHeader + rootRow("`cob-blockN.md` (e.g. cob-block7.md)", "x"), FocusPrefix{"cob-", PrefixFromFocuses}},
	{"an angle-bracket pattern is not cut", "RESEARCH-STATE.md", niagaraHeader + rootRow("cob-block<N>.md", "x"), FocusPrefix{"", PrefixNoRow}},
	{"cell must start with a letter", "RESEARCH-STATE.md", niagaraHeader + rootRow("1x-", "x"), FocusPrefix{"", PrefixNoRow}},
	{"cell must end with a dash", "RESEARCH-STATE.md", niagaraHeader + rootRow("base", "x"), FocusPrefix{"", PrefixNoRow}},
	{"a bold prefix keeps its stars", "RESEARCH-STATE.md", niagaraHeader + rootRow("**base-**", "x"), FocusPrefix{"", PrefixNoRow}},
	{"an indented row is not a row", "RESEARCH-STATE.md", niagaraHeader + " " + rootRow("base-", "x"), FocusPrefix{"", PrefixNoRow}},
	{"first matching root row wins", "RESEARCH-STATE.md", niagaraHeader + rootRow("nope", "x") + rootRow("two-", "x") + rootRow("three-", "x"), FocusPrefix{"two-", PrefixFromFocuses}},
	{"only the root state row", "RESEARCH-STATE.md", niagaraHeader + "| o | a | `RESEARCH-STATE-o.md` | o- | x |\n", FocusPrefix{"", PrefixNoRow}},
	{"bracketed link without a closing bracket", "RESEARCH-STATE.md", niagaraHeader + "| b | s | [RESEARCH-STATE.md | base- | x |\n", FocusPrefix{"", PrefixNoRow}},
}

func TestDeriveFocusPrefix(t *testing.T) {
	for _, c := range prefixCases {
		t.Run(c.label, func(t *testing.T) {
			d := t.TempDir()
			if c.table != "" {
				write(t, d+"/FOCUSES.md", c.table)
			}
			got, err := DeriveFocusPrefix(d + "/" + c.stateBase)
			if err != nil || got != c.want {
				t.Fatalf("got %+v (%v), want %+v", got, err, c.want)
			}
		})
	}
}

// TestRootCellDiagnostics pins the M (range-shaped cells) and F (fallback cell) outputs of the root awk, which
// focus_range_report turns into WARNs; the report differential checks them against bash.
func TestRootCellDiagnostics(t *testing.T) {
	for _, c := range []struct {
		label, table, fallback string
		shaped                 int
	}{
		{"6g two range-shaped cells", niagaraHeader + rootRow("B7–B8", "B1–B3"), "", 2},
		{"7j.5 fallback", "| Focus | Estado | State file | Blocks | Notes |\n|---|---|---|---|---|\n" + rootRow("see notes", "B2–B4"), "B2–B4", 1},
		{"the empty field after the closing pipe is no cell", "| a | b | c | d | e | Bloques |\n|---|---|---|---|---|---|\n" + rootRow("x", "B1-B2"), "", 1},
		{"a header over the state cell is ignored", "| F | S | Bloques | x | y |\n|---|---|---|---|---|\n" + rootRow("x", "B1-B2"), "", 1},
	} {
		sf := focusCorpus(t, t.TempDir(), c.table)
		rc, _, err := readRootCell(sf)
		if err != nil || rc.fallback != c.fallback || rc.shaped != c.shaped {
			t.Errorf("%s: fallback=%q shaped=%d (%v), want %q %d", c.label, rc.fallback, rc.shaped, err, c.fallback, c.shaped)
		}
	}
}
