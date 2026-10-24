package kit

import "testing"

// Ports of the inplace_gap_id / inplace_blocked_count contract (kit #1915) that
// research-sdd-status-inplace-blocked.test.sh and verify-state-inplace-blocked.test.sh exercise end to end.

type gapIDCase struct{ in, want string } // want "" = not ID-shaped

// gapIDCases is shared with the differential test.
var gapIDCases = []gapIDCase{
	{"AB. Builders de config", "AB"}, {"ab: x", "AB"}, {"AB", "AB"}, {"**AB. Offsets de campo**", "AB"},
	{"**G12**", "G12"}, {"  \tB851-G1 rest", "B851-G1"}, {"B1.2.3.", "B1.2.3"}, {"Builders", ""}, {"abcd", ""},
	{"abc", "ABC"}, {"a1b2c3d4", "A1B2C3D4"}, {"-AB", ""}, {".1", ""}, {"A_B", ""}, {"AB::", ""}, {"", ""},
	{"   ", ""}, {"**", ""}, {"ñ1", ""}, {"G1**.", ""}, {"**G1.**", "G1"}, {"x\vG1", "X"}, {"AB:.", ""}, {"AB.:", "AB."},
}

func TestInplaceGapID(t *testing.T) {
	for _, c := range gapIDCases {
		got, ok := InplaceGapID(c.in)
		if got != c.want || ok != (c.want != "") {
			t.Errorf("InplaceGapID(%q) = %q %v, want %q", c.in, got, ok, c.want)
		}
	}
}

type inplaceCase struct {
	label, body, rows string
	want              int
}

const blockedSection = "- **AB. Offsets de campo** — needs: a decompiler\n- exact name row — needs: hardware\n- no needs here\n"

// inplaceCases is shared with the differential test.
var inplaceCases = []inplaceCase{
	{"the three token forms count", "", "high\tg1\tblocked (requires-hardware)\nlow\tg2\tblocked-on-tool: x\nlow\tg3\tblocked\nlow\tg4\tblocked:\nlow\tg5\tblocked, later\n", 5},
	{"other statuses do not", "", "high\tg1\tpending\nlow\tg2\tblockedish\nlow\tg3\tnot blocked\nlow\tg4\t\n", 0},
	{"closed rows are skipped", "", "low\t~~g1~~\tblocked\nlow\tg2\tblocked ✅ closed\nlow\tg3\t~~blocked~~\n", 0},
	{"bold status token", "", "low\tg1\t**blocked** (requires-x)\nlow\tg2\tx**blocked\n", 1},
	{"a Blocked-gaps bullet suppresses by exact name", blockedSection, "low\texact name row\tblocked\nlow\texact name\tblocked\n", 1},
	{"a Blocked-gaps bullet suppresses by gap ID", blockedSection, "low\tAB. Builders de config — offsets\tblocked\nlow\tAC. other\tblocked\n", 1},
	{"a bullet without needs: suppresses nothing", blockedSection, "low\tno needs here\tblocked\n", 1},
	{"needs: is case-blind and dash forms are cut", "- G7 Thing -- NEEDS: x\n  - G8 other –needs: y\n-G9 nospace needs: z\n", "low\tG7 Thing\tblocked\nlow\tG8 other\tblocked\nlow\tG9 x\tblocked\n", 1},
	{"tabs collapse and the last field keeps the rest", "", "low\t\tg1\tblocked\nlow\tg2\tblocked\textra\n\tg3\tblocked\n", 1},
	{"a last row without a newline is not read", "", "low\tg1\tblocked\nlow\tg2\tblocked", 1},
	{"a dash-less needs: before a dashed one wins", "- G1 a needs: b — needs: c\n", "low\tG1 a\tblocked\nlow\tG1 a needs: b\tblocked\n", 0},
	{"en dash bytes in the C-locale bracket", "- G2 x\xe2\x80 needs: c\n- G3 y€ needs: d\n", "low\tG2 x\tblocked\nlow\tG3 y€\tblocked\n", 0},
	{"interleaved blanks and dashes keep all but the last dash run", "- xylo - - needs: y\n- pqrs -  -needs: q\n- mnop -- -- needs: n\n- abcd - efgh - needs: c\n",
		"low\txylo -\tblocked\nlow\tpqrs -\tblocked\nlow\tmnop --\tblocked\nlow\tabcd - efgh\tblocked\nlow\txylo\tblocked\nlow\tmnop\tblocked\n", 2},
	{"empty gap", "", "low\t\t\n", 0},
	{"empty input", "", "", 0},
}

func TestInplaceBlockedCount(t *testing.T) {
	for _, c := range inplaceCases {
		if got := InplaceBlockedCount(c.body, c.rows); got != c.want {
			t.Errorf("%s: got %d, want %d", c.label, got, c.want)
		}
	}
}
