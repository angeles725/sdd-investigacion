package kit

import "testing"

var gapIDCases = []struct{ in, want string }{
	{"AB.", "AB"}, {"AB", "AB"}, {"ab:", "AB"}, {"**AB.**", "AB"}, {"  AB. Builders de config", "AB"}, {"B1", "B1"}, {"abc", "ABC"},
	{"1", "1"}, {"x.y-1", "X.Y-1"}, {"Builders", ""}, {"abcd", ""}, {"-x", ""}, {"a_b", ""}, {"", ""}, {"   ", ""}, {"AB::", ""}, {"**", ""},
	{"é1", ""}, {"G12 foo", "G12"},
}

func TestInplaceGapID(t *testing.T) {
	for _, c := range gapIDCases {
		if got := InplaceGapID(c.in); got != c.want {
			t.Errorf("%q: %q want %q", c.in, got, c.want)
		}
	}
}

type ipScenario struct{ name, body, rows string }

// ipScenarios is shared with the differential test. Rows are "priority<TAB>gap<TAB>status" and end in a newline.
var ipScenarios = []ipScenario{
	{"in-place blocked counted", "", "high\tAB. Builders\tblocked: waits\n"},
	{"first middle last", "", "h\tA1 x\tblocked\nh\tB2 y\topen\nh\tC3 z\tblocked-on-api\n"},
	{"single", "", "h\tA1 x\tblocked,\n"},
	{"token variants", "", "h\tA1\t**blocked** now\nh\tA2\tblockedx\nh\tA3\tBlocked\nh\tA4\tblocked: x\n"},
	{"closed rows skipped", "", "h\t~~A1 x~~\tblocked\nh\tA2\t~~blocked~~\nh\tA3\tblocked ✅\nh\tA4\tblocked\n"},
	{"also listed under blocked-gaps by exact name", "- A1 Builders — needs: x\n", "h\tA1 Builders\tblocked\nh\tA2\tblocked\n"},
	{"also listed by gap id", "- **AB. Offsets de campo** — needs: y\n", "h\tAB. Builders de config\tblocked\nh\tCD. Other\tblocked\n"},
	{"bullet without needs does not suppress", "- AB. Builders\n", "h\tAB. Builders\tblocked\n"},
	{"needs in several spellings", "  - X1 a - needs: z\n- X2 b needs: q\n* X3 c needs: no\n- X4 dash — NEEDS: w\n", "h\tX1 a\tblocked\nh\tX2 b\tblocked\nh\tX3 c\tblocked\nh\tX4 dash\tblocked\nh\tX5 e\tblocked\n"},
	{"empty gap skipped", "", "h\t\tblocked\n"},
	{"empty input", "", ""},
	{"no match", "", "h\tA1\topen\nh\tA2\tdone\n"},
}

func TestInplaceBlockedCount(t *testing.T) {
	want := map[string]int{
		"in-place blocked counted": 1, "first middle last": 2, "single": 1, "token variants": 2, "closed rows skipped": 1,
		"also listed under blocked-gaps by exact name": 1, "also listed by gap id": 1, "bullet without needs does not suppress": 1,
		"needs in several spellings": 2, "empty gap skipped": 0, "empty input": 0, "no match": 0,
	}
	for _, s := range ipScenarios {
		if got := InplaceBlockedCount(s.body, s.rows); got != want[s.name] {
			t.Errorf("%s: %d want %d", s.name, got, want[s.name])
		}
	}
}

// FINDING F9: `while read` drops a final row that has no trailing newline (the section 7 list-edge bug). Go counts it.
func TestInplaceBlockedCountLastRowWithoutNewline(t *testing.T) {
	if got := InplaceBlockedCount("", "h\tA1\topen\nh\tA2\tblocked"); got != 1 {
		t.Errorf("last row dropped: %d", got)
	}
}
