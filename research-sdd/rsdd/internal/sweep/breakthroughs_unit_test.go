package sweep

import (
	"os"
	"reflect"
	"strings"
	"testing"
)

// Boundary and unit tests of the pure parts of `sweep breakthroughs`. The scenario table
// (breakthroughs_scenarios_test.go) drives whole sweeps; these pin the edges a hand mutant would move: every
// boundary of the marker, the ledger cell and the line numbers, and every branch of the hook filter.

func TestBreakthroughsResearchHomeOf(t *testing.T) {
	env := func(rh, home string) func(string) string {
		return func(k string) string {
			switch k {
			case "RESEARCH_HOME":
				return rh
			case "HOME":
				return home
			}
			return ""
		}
	}
	for name, c := range map[string]struct{ rh, home, want string }{
		"set":                      {"/r", "/h", "/r"},
		"one trailing slash":       {"/r/", "/h", "/r"},
		"two trailing slashes":     {"/r//", "/h", "/r/"},
		"unset falls to HOME":      {"", "/h", "/h"},
		"HOME trailing slash":      {"", "/h/", "/h"},
		"ampersand and backslash":  {`/r&d\x`, "/h", `/r&d\x`},
		"both unset":               {"", "", ""},
		"the slash alone is empty": {"/", "/h", ""},
	} {
		if got := researchHomeOf(env(c.rh, c.home)); got != c.want {
			t.Errorf("%s: researchHomeOf = %q, want %q", name, got, c.want)
		}
	}
}

func TestBreakthroughsLedgerPointers(t *testing.T) {
	const rh = "/home/x"
	for name, c := range map[string]struct {
		ledger string
		want   []string
	}{
		"first and only row":          {"| 1 | t | w | `/a/b.md:3` | k |\n", []string{"/a/b.md:3"}},
		"two tokens in one cell":      {"| 1 | t | w | `/a/b.md:3` and `/a/c.md:9` | k |\n", []string{"/a/b.md:3", "/a/c.md:9"}},
		"only the fourth cell":        {"| 1 | `/a/t.md:1` | `/a/w.md:2` | `/a/b.md:3` | `/a/k.md:4` |\n", []string{"/a/b.md:3"}},
		"three cells only":            {"| 1 | t | `/a/b.md:3` |\n", nil},
		"fourth cell without a pipe":  {"| 1 | t | w | `/a/b.md:3`\n", []string{"/a/b.md:3"}},
		"five fields exactly":         {"|1|t|w|`/a/b.md:3`|\n", []string{"/a/b.md:3"}},
		"no pipe at the start":        {" | 1 | t | w | `/a/b.md:3` | k |\n", nil},
		"header row":                  {"| # | t | w | `/a/b.md:3` | k |\n", nil},
		"skeleton row":                {"| — | t | w | `/a/b.md:3` | k |\n", nil},
		"dash row":                    {"| - | t | w | `/a/b.md:3` | k |\n", nil},
		"empty first cell":            {"|  | t | w | `/a/b.md:3` | k |\n", nil},
		"first cell is trimmed":       {"|\t# \t| t | w | `/a/b.md:3` | k |\n", nil},
		"separator":                   {"|---|---|---|---|---|\n|:--:|:--:|:--:|:--:|:--:|\n| : | t | w | `/a/b.md:3` | k |\n", nil},
		"token needs digits":          {"| 1 | t | w | `/a/b.md:x` `/a/c.md:` `nocolon` | k |\n", nil},
		"token needs a path":          {"| 1 | t | w | `:5` | k |\n", nil},
		"colon inside the path":       {"| 1 | t | w | `/a:b/c.md:3` | k |\n", []string{"/a:b/c.md:3"}},
		"digits after the last colon": {"| 1 | t | w | `/a/b.md:3:4` | k |\n", []string{"/a/b.md:3:4"}},
		"portable":                    {"| 1 | t | w | `$RESEARCH_HOME/b.md:3` | k |\n", []string{rh + "/b.md:3"}},
		"portable braces":             {"| 1 | t | w | `${RESEARCH_HOME}/b.md:3` | k |\n", []string{rh + "/b.md:3"}},
		"portable needs the slash":    {"| 1 | t | w | `$RESEARCH_HOMEx/b.md:3` `${RESEARCH_HOME}b.md:3` | k |\n", []string{"$RESEARCH_HOMEx/b.md:3", "${RESEARCH_HOME}b.md:3"}},
		"portable only as a prefix":   {"| 1 | t | w | `/a/$RESEARCH_HOME/b.md:3` | k |\n", []string{"/a/$RESEARCH_HOME/b.md:3"}},
		"last line without newline":   {"| 1 | t | w | `/a/b.md:3` | k |", []string{"/a/b.md:3"}},
		"rows in order":               {"| 1 | t | w | `/a/1.md:1` | k |\n| 2 | t | w | `/a/2.md:2` | k |\n", []string{"/a/1.md:1", "/a/2.md:2"}},
	} {
		if got := ledgerPointers([]byte(c.ledger), rh); !reflect.DeepEqual(got, c.want) {
			t.Errorf("%s: pointers = %q, want %q", name, got, c.want)
		}
	}
}

func TestBreakthroughsMarkerLines(t *testing.T) {
	for name, c := range map[string]struct {
		text string
		want []int
	}{
		"plain":               {"> **Breakthrough:** x\n", []int{1}},
		"no space":            {">**Breakthrough:** x\n", []int{1}},
		"tab and spaces":      {">\t \v\f**Breakthrough:** x\n", []int{1}},
		"carriage return":     {">\r**Breakthrough:** x\n", []int{1}},
		"no quote":            {"**Breakthrough:** x\n", nil},
		"leading blank":       {" > **Breakthrough:** x\n", nil},
		"text before":         {"> a **Breakthrough:** x\n", nil},
		"lowercase":           {"> **breakthrough:** x\n", nil},
		"no colon":            {"> **Breakthrough** x\n", nil},
		"colon outside":       {"> **Breakthrough**: x\n", nil},
		"bare caps":           {"> BREAKTHROUGH: x\n", nil},
		"second line":         {"a\n> **Breakthrough:** x\n", []int{2}},
		"two markers":         {"> **Breakthrough:** a\nb\n> **Breakthrough:** c\n", []int{1, 3}},
		"no final newline":    {"a\n> **Breakthrough:** x", []int{2}},
		"empty file":          {"", nil},
		"blank lines count":   {"\n\n\n> **Breakthrough:** x\n", []int{4}},
		"NUL byte is a line":  {"a\x00b\n> **Breakthrough:** x\n", []int{2}},
		"invalid UTF-8":       {"\xff\xfe\n> **Breakthrough:** x\n", []int{2}},
		"CRLF line endings":   {"a\r\n> **Breakthrough:** x\r\n", []int{2}},
		"newline only at end": {"> **Breakthrough:** x\n\n", []int{1}},
	} {
		if got := markerLines([]byte(c.text)); !reflect.DeepEqual(got, c.want) {
			t.Errorf("%s: markerLines = %v, want %v", name, got, c.want)
		}
	}
}

func TestBreakthroughsCarriesMarker(t *testing.T) {
	data := []byte("a\n> **Breakthrough:** x\nc")
	for digits, want := range map[string]bool{
		"1": false, "2": true, "02": true, "002": true, "3": false, "4": false, "0": false, "00": false,
		"99999999999999999999": false, "9223372036854775807": false, "9223372036854775808": false,
	} {
		if got := carriesMarker(data, digits); got != want {
			t.Errorf("carriesMarker(line %s) = %v, want %v", digits, got, want)
		}
	}
	if carriesMarker(nil, "1") {
		t.Error("an empty file has no line 1")
	}
	if !carriesMarker([]byte("> **Breakthrough:** x"), "1") {
		t.Error("a single line without a newline is line 1")
	}
}

func TestBreakthroughsTrimZeros(t *testing.T) {
	for in, want := range map[string]string{"7": "7", "07": "7", "007": "7", "0": "0", "000": "0", "10": "10", "100": "100", "0100": "100"} {
		if got := trimZeros(in); got != want {
			t.Errorf("trimZeros(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestBreakthroughsPointerIndex(t *testing.T) {
	ix := newPointerIndex([]string{"/a/x.md:07", "/a/y.md:5", "/a/z.md:1:2"})
	for _, c := range []struct {
		file  string
		lines []int
		want  bool
	}{
		{"/a/x.md", []int{7}, true}, {"/a/x.md", []int{70}, false}, {"/a/x.md", []int{1, 7}, true}, {"/a/x.md", []int{1, 8}, false},
		{"/a/y.md", []int{5}, true}, {"/a/y.md", []int{57}, false}, {"/a/y.md", []int{50}, false}, {"/a/x.md", nil, false},
		{"/a/y.mdx", []int{5}, false}, {"/b/y.md", []int{5}, false}, {"/a/z.md:1", []int{2}, true}, {"/a/z.md", []int{2}, false},
	} {
		if got := ix.indexes(c.file, c.lines); got != c.want {
			t.Errorf("indexes(%q, %v) = %v, want %v", c.file, c.lines, got, c.want)
		}
	}
}

func TestBreakthroughsSplitPointer(t *testing.T) {
	if f, l := splitPointer("/a:b/c.md:12"); f != "/a:b/c.md" || l != "12" {
		t.Errorf("splitPointer = %q, %q", f, l)
	}
}

func TestBreakthroughsParentAndFile(t *testing.T) {
	for in, want := range map[string]string{
		"WARN: unindexed breakthrough — tagged block not in BREAKTHROUGHS.md: /x/y/z/b-block1.md:7": "z/b-block1.md:7",
		"WARN: x BREAKTHROUGHS.md: /one/two:3":                                                      "one/two:3",
		"WARN: x BREAKTHROUGHS.md: a/BREAKTHROUGHS.md: /p/q.md:1":                                   "p/q.md:1",
		"WARN: x BREAKTHROUGHS.md: file.md:1":                                                       "file.md:1",
		"no lead /a/b":                                                                              "a/b",
	} {
		if got := parentAndFile(in); got != want {
			t.Errorf("parentAndFile(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestBreakthroughsSummaryFilter(t *testing.T) {
	warn := func(n int) string {
		return "WARN: unindexed breakthrough — tagged block not in BREAKTHROUGHS.md: /c/d" + string(rune('0'+n)) + "/f-block1.md:" + string(rune('0'+n)) + "\n"
	}
	const (
		abs   = "INFO: corpus not found (absent-input): /gone\n"
		empty = "INFO: corpus exists, no block files (empty-input): /e\n"
		nom   = "INFO: no tagged breakthroughs in corpus (no-match — expected while back-fill pending): /n\n"
		sum   = "\nSummary: 0 tagged breakthrough(s) across corpora · 0 unindexed · 0 drifted · 0 skipped-unreadable.\n"
		agg   = "INFO: 2 target(s) not traversed (absent-input) — corpus directory not found; see INFO lines above.\n"
	)
	for name, c := range map[string]struct{ in, want string }{
		"absent per-target lines go, the aggregate points at --full": {abs + abs + sum + agg,
			"Summary: 0 tagged breakthrough(s) across corpora · 0 unindexed · 0 drifted · 0 skipped-unreadable.\nINFO: 2 target(s) not traversed (absent-input) — corpus directory not found; run --full to list them.\n"},
		"aggregate without the pointer is kept": {"INFO: 1 target(s) not traversed (absent-input) — gone\n", "INFO: 1 target(s) not traversed (absent-input) — gone\n"},
		"only the first pointer is replaced":    {"INFO: 1 target(s) not traversed (absent-input) see INFO lines above. see INFO lines above\n", "INFO: 1 target(s) not traversed (absent-input) run --full to list them. see INFO lines above\n"},
		"empty only":                            {empty + empty, "INFO: 2 corpus(es) empty-input — run --full to list them\n"},
		"no-match only":                         {nom + nom + nom, "INFO: 3 corpus(es) no-match — run --full to list them\n"},
		"both":                                  {nom + empty + nom, "INFO: 1 corpus(es) empty-input, 2 no-match — run --full to list them\n"},
		"counted lines come last":               {empty + sum + "Ledger consistent — x\n", "Summary: 0 tagged breakthrough(s) across corpora · 0 unindexed · 0 drifted · 0 skipped-unreadable.\nLedger consistent — x\nINFO: 1 corpus(es) empty-input — run --full to list them\n"},
		"no-match with another reason":          {"INFO: no tagged breakthroughs in corpus (no-match): /n\n", "INFO: 1 corpus(es) no-match — run --full to list them\n"},
		"other INFO lines pass":                 {"INFO: corpus exists, other: /e\nINFO: no tagged breakthroughs in corpus (nomatch): /n\n", "INFO: corpus exists, other: /e\nINFO: no tagged breakthroughs in corpus (nomatch): /n\n"},
		"blank lines go, whitespace-only too":   {"a\n\n \t \nb\n  x\n", "a\nb\n  x\n"},
		"CR is not blank":                       {"a\n\r\nb\n", "a\n\r\nb\n"},
		"one unindexed":                         {warn(1) + "For each unindexed breakthrough: add\n", "WARN: 1 unindexed breakthrough(s) not in BREAKTHROUGHS.md: d1/f-block1.md:1 — add a row each (path:line); run --full for all\n"},
		"five unindexed have no remainder":      {warn(1) + warn(2) + warn(3) + warn(4) + warn(5), "WARN: 5 unindexed breakthrough(s) not in BREAKTHROUGHS.md: d1/f-block1.md:1, d2/f-block1.md:2, d3/f-block1.md:3, d4/f-block1.md:4, d5/f-block1.md:5 — add a row each (path:line); run --full for all\n"},
		"six unindexed name five":               {warn(1) + warn(2) + warn(3) + warn(4) + warn(5) + warn(6), "WARN: 6 unindexed breakthrough(s) not in BREAKTHROUGHS.md: d1/f-block1.md:1, d2/f-block1.md:2, d3/f-block1.md:3, d4/f-block1.md:4, d5/f-block1.md:5, +1 more — add a row each (path:line); run --full for all\n"},
		"drift lines pass":                      {"WARN: drift — x\nFor each drifted row: verify\n", "WARN: drift — x\nFor each drifted row: verify\n"},
		"unindexed line must start the line":    {" WARN: unindexed breakthrough\n", " WARN: unindexed breakthrough\n"},
	} {
		got := breakthroughsSummaryFilter(strings.TrimRight(c.in, "\n"))
		if got != c.want {
			t.Errorf("%s:\n got %q\nwant %q", name, got, c.want)
		}
	}
}

func TestBreakthroughsHookContext(t *testing.T) {
	out := "INFO: corpus not found (absent-input): /g\n\nSummary: x"
	if got, want := breakthroughsHookContext(out, 0, true), btHookHeaderLine+out; got != want {
		t.Errorf("full: %q, want %q", got, want)
	}
	if got, want := breakthroughsHookContext(out, 0, false), btHookHeaderLine+"Summary: x"; got != want {
		t.Errorf("summary: %q, want %q", got, want)
	}
	for _, full := range []bool{true, false} {
		if got, want := breakthroughsHookContext("boom\nmore", 1, full), "Research-SDD breakthroughs sweep could not run (exit 1 — check TARGETS.md and lib/ helper):\nboom\nmore"; got != want {
			t.Errorf("failed (full=%v): %q, want %q", full, got, want)
		}
	}
	if got := breakthroughsHookContext("x", 3, false); !strings.Contains(got, "(exit 3 ") {
		t.Errorf("the exit code is named: %q", got)
	}
}

const btHookHeaderLine = "Research-SDD breakthrough ledger sweep (§22):\n"

func TestBreakthroughsBlockFiles(t *testing.T) {
	dir := t.TempDir()
	for _, f := range []string{"b-block1.md", "a-block1.md", "A-block1.md", "z/q-bloque2-x.md", "c.md", "block1.md", "d-block1.txt"} {
		p := dir + "/" + f
		if err := os.MkdirAll(p[:strings.LastIndex(p, "/")], 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, nil, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	got := blockFiles(dir)
	want := []string{dir + "/A-block1.md", dir + "/a-block1.md", dir + "/b-block1.md", dir + "/z/q-bloque2-x.md"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("blockFiles = %v, want %v", got, want)
	}
	empty := t.TempDir()
	if got := blockFiles(empty); got != nil {
		t.Errorf("an empty dir has no block files: %v", got)
	}
	if err := os.WriteFile(empty+"/notes.md", nil, 0o644); err != nil {
		t.Fatal(err)
	}
	if got := blockFiles(empty); got != nil {
		t.Errorf("markdown that is not a block: %v", got)
	}
}

func TestBreakthroughsMarkUnreadableCountsOnce(t *testing.T) {
	var tt btTotals
	tt.markUnreadable("/a")
	tt.markUnreadable("/a")
	tt.markUnreadable("/b")
	if tt.unreadable != 2 {
		t.Errorf("unreadable = %d, want 2", tt.unreadable)
	}
}

func TestBreakthroughsSummaryLines(t *testing.T) {
	for name, c := range map[string]struct {
		t    btTotals
		has  []string
		lack []string
	}{
		"clean":      {btTotals{}, []string{"Ledger consistent"}, []string{"For each", "INFO", "PARTIAL"}},
		"unindexed":  {btTotals{unindexed: 1}, []string{"For each unindexed breakthrough:"}, []string{"Ledger consistent", "For each drifted"}},
		"drift":      {btTotals{drift: 1}, []string{"For each drifted row:"}, []string{"Ledger consistent", "For each unindexed"}},
		"skipped":    {btTotals{skipped: 1, skippedNames: "a, b"}, []string{"WARN: 1 target(s) skipped — truncated/unresolvable path in TARGETS.md; this sweep is PARTIAL: a, b\n"}, []string{"Ledger consistent"}},
		"unreadable": {btTotals{unreadable: 1}, []string{"1 skipped-unreadable."}, []string{"Ledger consistent"}},
		"absent":     {btTotals{absent: 2}, []string{"INFO: 2 target(s) not traversed (absent-input)"}, nil},
	} {
		var b strings.Builder
		writeBreakthroughsSummary(&b, c.t)
		for _, h := range c.has {
			if !strings.Contains(b.String(), h) {
				t.Errorf("%s: lacks %q\n%s", name, h, b.String())
			}
		}
		for _, l := range c.lack {
			if strings.Contains(b.String(), l) {
				t.Errorf("%s: holds %q\n%s", name, l, b.String())
			}
		}
	}
}
