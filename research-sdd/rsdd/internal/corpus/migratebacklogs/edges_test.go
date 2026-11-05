package migratebacklogs

import (
	"strings"
	"testing"
)

// The tests of this file run under -tags nodiff as well (no oracle needed): they pin the character-class and
// length edges of the small helpers and the hunk arithmetic of the unified diff, so a boundary or negation mutant
// of those lines cannot live.

func TestLowerIsAsciiOnly(t *testing.T) {
	t.Parallel()
	// the bytes next to each end of A-Z stay as they are; the ends fold
	if got, want := lower("@AZ[ÄÉ`az{"), "@az[ÄÉ`az{"; got != want {
		t.Errorf("lower = %q, want %q", got, want)
	}
}

func TestWordRunAlphabet(t *testing.T) {
	t.Parallel()
	for in, want := range map[string]string{
		"az": "az", "AZ": "AZ", "a-z": "a-z", "-": "-", "a`": "a", "a{": "a", "a@": "a", "a[": "a", "a0": "a", "a9": "a", "a:": "a", "a ": "a", "": "", "(a": "",
	} {
		if got := wordRun(in); got != want {
			t.Errorf("wordRun(%q) = %q, want %q", in, got, want)
		}
	}
	// the decoration in front of a status word: bold, backtick, bracket, blank, and nothing else
	for in, want := range map[string]string{"**a": "a", "`a": "a", "[a": "a", " a": "a", "*`[ a": "a", "(a": "", "~a": "", "_a": ""} {
		if got := leadingWord(in); got != want {
			t.Errorf("leadingWord(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestStateFileNameLengthEdge(t *testing.T) {
	t.Parallel()
	for name, want := range map[string]bool{
		"RESEARCH-STATE.md": true, "RESEARCH-STATE-a.md": true, "RESEARCH-STATE.md.bak": false, "RESEARCH-STATE": false, "RESEARCH-STAT.md": false,
		"RESEARCH-STATE.template.md": false, "RESEARCH-STATE-x.template.md": false, "xRESEARCH-STATE.md": false, "RESEARCH-STATE.MD": false, ".md": false, "RESEARCH-STATE.m": false,
	} {
		if got := isStateFile(name); got != want {
			t.Errorf("isStateFile(%q) = %v, want %v", name, got, want)
		}
	}
}

func TestLabelOf(t *testing.T) {
	t.Parallel()
	for rel, want := range map[string]string{
		"RESEARCH-STATE.md": "(root)", "a/RESEARCH-STATE.md": "(root)", "RESEARCH-STATE-.md": "(root)", "RESEARCH-STATE-a.md": "a", "s/RESEARCH-STATE-a-b.md": "a-b",
		"RESEARCH-STATE_a.md": "(root)", "RESEARCH-STATE-ab.md": "ab", "RESEARCH-STATE--.md": "-",
	} {
		if got := labelOf(rel); got != want {
			t.Errorf("labelOf(%q) = %q, want %q", rel, got, want)
		}
	}
}

func TestSeparatorAndBlankHelpers(t *testing.T) {
	t.Parallel()
	for in, want := range map[string]bool{"-": true, "---": true, ":-": true, "-:": true, ":-:": true, "::": false, ":": false, "": false, "-a": false, "- -": false, ":--:x": false} {
		if got := isSepFirst(in); got != want {
			t.Errorf("isSepFirst(%q) = %v, want %v", in, got, want)
		}
	}
	for in, want := range map[string]bool{" ": true, "\t": true, ":": true, "-": true, " : - ": true, "": false, "a": false, " a ": false, "|": false} {
		if got := blankOrDelimiter(in); got != want {
			t.Errorf("blankOrDelimiter(%q) = %v, want %v", in, got, want)
		}
	}
}

func TestBareDropsDecorationOnly(t *testing.T) {
	t.Parallel()
	for in, want := range map[string]string{"**a**": "a", " `b` ": "b", "** c **": "c", "d*e": "d*e", "`**f**`": "f", "": "", "  ": ""} {
		if got := bare(in); got != want {
			t.Errorf("bare(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestSplitLinesKeepsEveryTerminator(t *testing.T) {
	t.Parallel()
	for src, want := range map[string][]line{
		"":         nil,
		"a":        {{"a", ""}},
		"a\n":      {{"a", "\n"}},
		"a\r\nb":   {{"a", "\r\n"}, {"b", ""}},
		"\n":       {{"", "\n"}},
		"\r\n\r\n": {{"", "\r\n"}, {"", "\r\n"}},
		"a\rb\n":   {{"a\rb", "\n"}},
		"a\r":      {{"a\r", ""}},
		"a\n\nb\n": {{"a", "\n"}, {"", "\n"}, {"b", "\n"}},
	} {
		got := splitLines(src)
		if len(got) != len(want) {
			t.Errorf("splitLines(%q) = %v, want %v", src, got, want)
			continue
		}
		var back strings.Builder
		for i := range got {
			if got[i] != want[i] {
				t.Errorf("splitLines(%q)[%d] = %v, want %v", src, i, got[i], want[i])
			}
			back.WriteString(got[i].text())
		}
		if back.String() != src {
			t.Errorf("splitLines(%q) does not round-trip: %q", src, back.String())
		}
	}
}

func TestRowRoundTripAndSet(t *testing.T) {
	t.Parallel()
	for _, src := range []string{"| a | b |", "|a|b|", "  | a | b |  ", "| a | b", "| a | b  ", "|", "||", "| |", "| a\\|b | c |", "\t|\ta\t|", "| a |   "} {
		r, ok := parseRow(src)
		if !ok || r.String() != src {
			t.Errorf("parseRow(%q) round-trips to %q (ok=%v)", src, r.String(), ok)
		}
	}
	if _, ok := parseRow("a | b"); ok {
		t.Error("a line without a leading pipe is not a row")
	}
	for _, p := range []struct{ src, want string }{
		{"|  a  | b |", "|  X  | b |"},
		{"|a| b |", "|X| b |"},
		{"|\ta\t| b |", "|\tX\t| b |"},
		{"| a  | b |", "| X  | b |"},
		{"|  | b |", "| X | b |"},
		{"| \t | b |", "| X | b |"},
		{"|    | b |", "| X | b |"},
	} {
		r, _ := parseRow(p.src)
		r.set(0, "X")
		if got := r.String(); got != p.want {
			t.Errorf("set on %q = %q, want %q", p.src, got, p.want)
		}
	}
}

// writeHunk arithmetic: the counts, the start line and the `,count` rules of GNU diff.
func TestHunkRangeRules(t *testing.T) {
	t.Parallel()
	for _, p := range []struct {
		start, count int
		want         string
	}{{0, 0, "0,0"}, {4, 0, "4,0"}, {0, 1, "1"}, {9, 1, "10"}, {0, 2, "1,2"}, {4, 7, "5,7"}} {
		if got := hunkRange(p.start, p.count); got != p.want {
			t.Errorf("hunkRange(%d, %d) = %q, want %q", p.start, p.count, got, p.want)
		}
	}
}

func lines(texts ...string) []line {
	out := make([]line, len(texts))
	for i, t := range texts {
		out[i] = line{body: t, eol: "\n"}
	}
	return out
}

func TestUnifiedDiffShapes(t *testing.T) {
	t.Parallel()
	seq := func(n int) []string {
		var s []string
		for i := 1; i <= n; i++ {
			s = append(s, "l"+string(rune('a'+i-1)))
		}
		return s
	}
	change := func(base []string, at ...int) []string {
		out := append([]string(nil), base...)
		for _, i := range at {
			out[i] = "CHANGED"
		}
		return out
	}
	base := seq(20)
	for _, p := range []struct {
		name     string
		old, new []string
		wantHdr  []string
	}{
		{"same", base, base, nil},
		{"first line", base, change(base, 0), []string{"@@ -1,4 +1,4 @@"}},
		{"second line", base, change(base, 1), []string{"@@ -1,5 +1,5 @@"}},
		{"fourth line", base, change(base, 3), []string{"@@ -1,7 +1,7 @@"}},
		{"fifth line", base, change(base, 4), []string{"@@ -2,7 +2,7 @@"}},
		{"last line", base, change(base, 19), []string{"@@ -17,4 +17,4 @@"}},
		{"before last", base, change(base, 18), []string{"@@ -16,5 +16,5 @@"}},
		{"gap of 6 merges", base, change(base, 5, 12), []string{"@@ -3,14 +3,14 @@"}},
		{"gap of 7 splits", base, change(base, 5, 13), []string{"@@ -3,7 +3,7 @@", "@@ -11,7 +11,7 @@"}},
		{"adjacent merge", base, change(base, 5, 6), []string{"@@ -3,8 +3,8 @@"}},
		{"gap of 1 merges", base, change(base, 5, 7), []string{"@@ -3,9 +3,9 @@"}},
		{"append to one line", []string{"x"}, []string{"x", "y"}, []string{"@@ -1 +1,2 @@"}},
		{"append to empty tail", base, append(append([]string(nil), base...), "n1", "n2"), []string{"@@ -18,3 +18,5 @@"}},
		{"append after changed last", base, append(change(base, 19), "n1"), []string{"@@ -17,4 +17,5 @@"}},
		{"delete the tail", []string{"a", "b", "c", "d"}, []string{"a", "b"}, []string{"@@ -1,4 +1,2 @@"}},
		{"delete everything but one", []string{"a", "b"}, []string{"a"}, []string{"@@ -1,2 +1 @@"}},
	} {
		got := unifiedDiff("f", lines(p.old...), lines(p.new...))
		if len(p.wantHdr) == 0 {
			if got != "" {
				t.Errorf("%s: diff of equal files = %q", p.name, got)
			}
			continue
		}
		var hdrs []string
		for _, l := range strings.Split(got, "\n") {
			if strings.HasPrefix(l, "@@") {
				hdrs = append(hdrs, l)
			}
		}
		if !strings.HasPrefix(got, "--- a/f\n+++ b/f\n") || len(hdrs) != len(p.wantHdr) {
			t.Errorf("%s: headers %v, want %v\n%s", p.name, hdrs, p.wantHdr, got)
			continue
		}
		for i := range hdrs {
			if hdrs[i] != p.wantHdr[i]+"" && hdrs[i] != p.wantHdr[i] {
				t.Errorf("%s: hunk %d is %q, want %q", p.name, i, hdrs[i], p.wantHdr[i])
			}
		}
	}
}

// A hunk is a valid patch: the context lines and the old side rebuild the old file, the context and the new side
// rebuild the new one.
func TestUnifiedDiffBodyRebuildsBothFiles(t *testing.T) {
	t.Parallel()
	old := lines("a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k")
	new := lines("a", "B", "c", "d", "e", "f", "G", "h", "i", "j", "k", "tail")
	got := unifiedDiff("f", old, new)
	var o, n []string
	for _, l := range strings.Split(got, "\n")[2:] {
		switch {
		case strings.HasPrefix(l, " "):
			o, n = append(o, l[1:]), append(n, l[1:])
		case strings.HasPrefix(l, "-"):
			o = append(o, l[1:])
		case strings.HasPrefix(l, "+"):
			n = append(n, l[1:])
		}
	}
	if strings.Join(o, "") != "abcdefghijk" || strings.Join(n, "") != "aBcdefGhijktail" {
		t.Errorf("old side %v, new side %v\n%s", o, n, got)
	}
}

func TestUnifiedDiffMarksMissingNewlinesOnTheirSide(t *testing.T) {
	t.Parallel()
	old := []line{{"a", "\n"}, {"b", ""}}
	same := []line{{"a", "\n"}, {"b", ""}}
	if d := unifiedDiff("f", old, same); d != "" {
		t.Errorf("equal files: %q", d)
	}
	added := []line{{"a", "\n"}, {"b", "\n"}}
	if got, want := unifiedDiff("f", old, added), "--- a/f\n+++ b/f\n@@ -1,2 +1,2 @@\n a\n-b\n\\ No newline at end of file\n+b\n"; got != want {
		t.Errorf("terminator added:\n%q\nwant\n%q", got, want)
	}
	dropped := []line{{"a", "\n"}, {"c", ""}}
	if got, want := unifiedDiff("f", old, dropped), "--- a/f\n+++ b/f\n@@ -1,2 +1,2 @@\n a\n-b\n\\ No newline at end of file\n+c\n\\ No newline at end of file\n"; got != want {
		t.Errorf("both sides unterminated:\n%q\nwant\n%q", got, want)
	}
	ctx := []line{{"a", ""}}
	if got := unifiedDiff("f", []line{{"x", "\n"}, {"a", ""}}, []line{{"y", "\n"}, {"a", ""}}); got != "--- a/f\n+++ b/f\n@@ -1,2 +1,2 @@\n-x\n+y\n a\n\\ No newline at end of file\n" {
		t.Errorf("context line without terminator: %q (%v)", got, ctx)
	}
}

func TestRegistryHeaderAcceptsStatusInTheFirstColumn(t *testing.T) {
	status, ok := registryHeader([]string{" Status ", " Focus "})
	if status != 0 || !ok {
		t.Fatalf("registryHeader(Status, Focus) = (%d, %v), want (0, true)", status, ok)
	}
	if _, ok := registryHeader([]string{"Focus", "Notes"}); ok {
		t.Fatal("a table without a Status column is not the registry")
	}
}

func TestAppendSkeletonOnAnEmptyFile(t *testing.T) {
	var manual []manualItem
	out := appendSkeleton(nil, classification{}, false, &manual)
	want := []string{"", canonicalHeading, "", "| Priority | Gap | Artifact type / source | Status |", "|---|---|---|---|"}
	if len(out) != len(want) {
		t.Fatalf("skeleton of an empty file has %d lines, want %d", len(out), len(want))
	}
	for i, l := range out {
		if l.body != want[i] || l.eol != "\n" {
			t.Fatalf("line %d = %q%q, want %q\\n", i, l.body, l.eol, want[i])
		}
	}
	if len(manual) != 1 || manual[0].reason != reasonEmptySkeleton {
		t.Fatalf("manual = %+v, want one %s finding", manual, reasonEmptySkeleton)
	}
}

func TestPlanStatusTokenAfterLeadingBold(t *testing.T) {
	// "**open** x": the bold markers are dropped first, so the token is "open" and only it is rewritten.
	if got, reason := planStatus("**open** x", "P1"); got != "**pending** x" || reason != "" {
		t.Fatalf("planStatus = (%q, %q), want (%q, \"\")", got, reason, "**pending** x")
	}
	// No blank at all: the whole lead is the token.
	if got, reason := planStatus("open", "P1"); got != "pending" || reason != "" {
		t.Fatalf("planStatus(open) = (%q, %q), want (pending, \"\")", got, reason)
	}
}
