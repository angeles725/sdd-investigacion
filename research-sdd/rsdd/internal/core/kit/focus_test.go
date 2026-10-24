package kit

import (
	"testing"
)

// Ports of the derive_focus_prefix contract and toolbelt/tests/focus-prefix-range.test.sh section 4 (kit #906).

const rootState = "`RESEARCH-STATE.md`"

// niagaraHeader is the FOCUSES.md layout of the bash suite: 5 data cells, the block cell last.
const niagaraHeader = "| Focus | Estado | RESEARCH-STATE | Ámbito | Bloques |\n|---|---|---|---|---|\n"

func rootRow(cell4, cell5 string) string {
	return "| (base) | stopped | " + rootState + " | " + cell4 + " | " + cell5 + " |\n"
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
