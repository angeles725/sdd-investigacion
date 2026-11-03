package show

import (
	"os"
	"path/filepath"
	"slices"
	"testing"
)

// Unit tests of the S2 helpers: the goldens pin the readers end to end, these name the rule of each helper.

func TestStripQualifier(t *testing.T) {
	for in, want := range map[string]string{
		"high":              "high",
		"high (ctx)":        "high",
		"high  (ctx)":       "high",
		"high(ctx)":         "high",
		"(x)":               "",
		"a (b) c":           "a (b) c",
		"a (b (c)":          "a",
		"a (b) (c)":         "a (b)",
		"a (b (c) d)":       "a (b (c) d)",
		"a ( ":              "a ( ",
		"a (b)) ":           "a (b)) ",
		"a ()":              "a",
		"x \t(y)":           "x \t",
		"deferred (parked)": "deferred",
		"":                  "",
	} {
		if got := stripQualifier(in); got != want {
			t.Errorf("stripQualifier(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestIsGapBacklogHeading(t *testing.T) {
	for in, want := range map[string]bool{
		"## Gap-backlog":               true,
		"## Gap-backlog (prioritized)": true,
		"## Gap-backlog (a b)":         true,
		"## Gap-backlog ()":            false,
		"## Gap-backlog (a))":          false,
		"## Gap-backlog (a) x":         false,
		"## Gap-backlog(a)":            false,
		"## Gap-backlog ":              false,
		"## Gap-backlogs":              false,
		"### Gap-backlog":              false,
		" ## Gap-backlog":              false,
		"## Gap-backlog (a)\r":         false,
		"":                             false,
	} {
		if got := isGapBacklogHeading(in); got != want {
			t.Errorf("isGapBacklogHeading(%q) = %v, want %v", in, got, want)
		}
	}
}

func TestReadRowsIsTheBashReadLoop(t *testing.T) {
	type row struct{ p, g, s string }
	var got []row
	readRows("high\tg1\tpending\nhigh\t\tpending\n\tlow\tg3\t\n\nlast\tno\tnewline", func(p, g, s string) { got = append(got, row{p, g, s}) })
	want := []row{{"high", "g1", "pending"}, {"high", "pending", ""}, {"low", "g3", ""}, {"", "", ""}}
	if !slices.Equal(got, want) {
		t.Errorf("readRows = %q, want %q (a tab run is one separator; a last line without a newline is not seen)", got, want)
	}
	got = nil
	readRows("a\tb\tc\td\te\n", func(p, g, s string) { got = append(got, row{p, g, s}) })
	if want := []row{{"a", "b", "c\td\te"}}; !slices.Equal(got, want) {
		t.Errorf("readRows keeps later tabs in the status: %q", got)
	}
}

func TestBlockIDs(t *testing.T) {
	got := blockIDs("AB1 B2x B_3 _B4 B5_ (B6) B7. -B8- B9-1 B10/B11 xB12 B13B14 B\nB15\nB16")
	if want := []string{"B6", "B7", "B8", "B9", "B10", "B11", "B15", "B16"}; !slices.Equal(got, want) {
		t.Errorf("blockIDs = %q, want %q", got, want)
	}
	if distinct([]string{"B1", "B2", "B1"}) != 2 || distinct(nil) != 0 {
		t.Error("distinct is sort -u | wc -l")
	}
}

func TestStripParens(t *testing.T) {
	for in, want := range map[string]string{
		"a (b) c":       "a  c",
		"(a (b) c)":     " c)",
		"a (b":          "a (b",
		"(a)(b)":        "",
		"a) (b":         "a) (b",
		"x (1) y (2) z": "x  y  z",
		"":              "",
	} {
		if got := stripParens(in); got != want {
			t.Errorf("stripParens(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestEmDashGapID(t *testing.T) {
	for in, want := range map[string]bool{
		"G1":          true,
		"B1-G2":       true,
		"**G1**":      true,
		"~~G1~~":      true,
		"`[G1]`":      true,
		"[**G1**]":    true,
		"G1: note":    true,
		"G1 (later)":  true,
		"G1·b":        true,
		"G1—b":        true,
		"G1.2_x":      true,
		"Gx":          false,
		"a note":      false,
		"":            false,
		"1":           true,
		"-G1":         false,
		"G1\xe2\x80":  true, // the cut is bytewise: 0xE2 is in the set
		"Ø1":          false,
		"G1\xe2\x80x": true,
	} {
		if got := emDashGapID(in); got != want {
			t.Errorf("emDashGapID(%q) = %v, want %v", in, got, want)
		}
	}
}

func TestStripMarkupAndLeadTok(t *testing.T) {
	for in, want := range map[string]string{
		"active":        "active",
		"**active**":    "active",
		"**active":      "active",
		"act**ive**":    "active**",
		"`active`":      "active",
		"`a`b`":         "`a`b`",
		"[active](u)":   "active",
		"[`active`](u)": "active",
		"[a](b) c":      "[a](b) c",
		"[a]()":         "a",
		"[a](b)c)":      "[a](b)c)",
		"[](u)":         "",
		"[a]":           "[a]",
		"`":             "`",
		"":              "",
	} {
		if got := stripMarkup(in); got != want {
			t.Errorf("stripMarkup(%q) = %q, want %q", in, got, want)
		}
	}
	for in, want := range map[string]string{"**Active** (n)": "active", "Paused\tx": "paused", "\tPaused": "", "": "", "[A](u)": "a", "[A](u) b": "[a](u)"} {
		if got := leadTok(in); got != want {
			t.Errorf("leadTok(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestFocusCellsKeepsTheUntrimmedLineQuirks(t *testing.T) {
	for in, want := range map[string][]string{
		"| a | b |":     {"a", "b"},
		"  | a | b |":   {"", "a", "b"},
		"\t| a |":       {"", "a"},
		"| a | b |  ":   {"a", "b", ""},
		"| a | b   ":    {"a", "b"},
		"  | a | b |  ": {"", "a", "b", ""},
		"a | b":         {"a", "b"},
		"  a | b":       {"a", "b"},
		"a | b |":       {"a", "b"},
		"|  ":           {""},
		"| a\\|b | c |": {"a|b", "c"},
		"| a |\r":       {"a", "\r"},
	} {
		if got := focusCells(in); !slices.Equal(got, want) {
			t.Errorf("focusCells(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestCountInvestigableBlockedStatus(t *testing.T) {
	root := t.TempDir()
	must(t, os.MkdirAll(filepath.Join(root, "corpus"), 0o755))
	must(t, os.WriteFile(filepath.Join(root, stateRel), []byte("## Gap-backlog\n"+h4+"\n| high | a | x | pending |\n| high | b | x | pending |\n| high | c | x | pending |\n"), 0o644))
	s, _, _ := stdio(root)
	c := &ctx{s: s, target: filepath.Join(root, "corpus"), state: filepath.Join(root, stateRel)}
	for name, tc := range map[string]struct {
		status func(string) int
		n, rc  int
	}{
		"none-blocked":  {func(string) int { return 1 }, 3, 0},
		"one-blocked":   {func(g string) int { return map[bool]int{true: 0, false: 1}[g == "b"] }, 2, 0},
		"all-blocked":   {func(string) int { return 0 }, 0, 0},
		"unknown-count": {func(string) int { return 2 }, 3, 3},
		"one-unknown":   {func(g string) int { return map[bool]int{true: 2, false: 1}[g == "c"] }, 3, 3},
	} {
		if n, rc := c.countInvestigableWith(tc.status); n != tc.n || rc != tc.rc {
			t.Errorf("%s: count_investigable = %d rc %d, want %d rc %d (an unknown blocked status is counted and fails the verdict)", name, n, rc, tc.n, tc.rc)
		}
	}
}

func TestUnreadableFiles(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("mode-000 files are readable by root")
	}
	root := t.TempDir()
	foc := filepath.Join(root, "FOCUSES.md")
	must(t, os.WriteFile(foc, []byte("| Focus | Status |\n|---|---|\n| alpha | active |\n"), 0o644))
	must(t, os.Chmod(foc, 0))
	s, _, errb := stdio(root)
	c := &ctx{s: s, target: root, state: filepath.Join(root, "missing.md")}
	if tok := c.focusTokUncached(foc, "RESEARCH-STATE-alpha.md"); tok != "" || errb.Len() != 0 {
		t.Errorf("an unreadable FOCUSES.md yields no token and no WARN of ours, got %q / %q", tok, errb.String())
	}
	if c.stateText() != "" {
		t.Error("an unreadable state file yields no records")
	}
	if n, rc := c.inplaceBlocked(); n != 0 || rc != 2 {
		t.Errorf("inplaceBlocked on an unreadable state = %d rc %d, want 0 rc 2", n, rc)
	}
}

func TestFocusTokCacheServesTheSecondReadWithoutAWarning(t *testing.T) {
	root := t.TempDir()
	foc := filepath.Join(root, "FOCUSES.md")
	must(t, os.WriteFile(foc, []byte("| Focus | Status |\n|---|---|\n| alpha | halted |\n"), 0o644))
	s, _, errb := stdio(root)
	c := &ctx{s: s, target: root}
	for range 3 {
		if tok := c.focusTokCached(foc, "RESEARCH-STATE-alpha.md"); tok != "" {
			t.Fatalf("token %q", tok)
		}
	}
	if want := "WARN: FOCUSES.md row alpha: unreadable/nonconforming status token [halted]\n"; errb.String() != want {
		t.Errorf("warnings = %q, want exactly one: %q", errb.String(), want)
	}
	if _, ok := c.focCache[foc+"\x1e"+"RESEARCH-STATE-alpha.md"]; !ok {
		t.Error("the cache key is the file and the state basename joined by 0x1e")
	}
	if c.focusTokCached(filepath.Join(root, "absent.md"), "x") != "" || len(c.focCache) != 2 {
		t.Error("a missing file is cached as the empty token")
	}
}

func TestPick(t *testing.T) {
	for _, tc := range []struct{ parsed, previous, want string }{
		{"7", "5", "7"}, {"", "5", "5"}, {"x", "5", "5"}, {"", "", "0"}, {"x", "y", "0"}, {"7x", "5", "5"}, {"007", "", "007"}, {"0", "9", "0"},
	} {
		if got := pick(tc.parsed, tc.previous); got != tc.want {
			t.Errorf("pick(%q, %q) = %q, want %q", tc.parsed, tc.previous, got, tc.want)
		}
	}
}
