//go:build unix

package block

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/fsview"
)

// Oracle-free unit tests of the pure helpers of `rsdd verify block`. The expected values are the ones the frozen
// bash script / GNU tools produce (pinned by the differential test under !nodiff); here they are literals, so the
// mutation run (nodiff) kills the boundary and negation mutants of the helpers. Guard -> test:
//
//	VB-LINECOUNT (unterminated last line, CR, END stop, unreadable) ... TestVbLinesCountsLikeAwk
//	int64 comparison of a cited number ................................ TestShellIntBounds
//	range split on the last dash ...................................... TestSplitRange
//	`\b` before an artifact cite ....................................... TestGrepOWordStartBoundary
//	PF-LADDER-ACCEPT (3 routes AND cheapest) ........................... TestPfScanLadderBoundary
//	VB-EP-DIGEST64 / VB-EP-SEGMENT / VB-EP-OWNED ........................ TestHasDigestBoundary, TestSkipScratch
//	cut -c counts bytes ................................................ TestCutBytes
//	sort -k1n -u ....................................................... TestDedupeByLine
//	source_pdf field ................................................... TestSourcePDF
//	find's path join ................................................... TestJoinFind
//	P1721 / P1766 nonpath guards ....................................... TestSplitNonpathGuards
//	BP-FORWARD / BP-LIST / BP-PROXIMITY / BP-CORRECTOR ................. TestScanCorrections*
//	VB-UNREADABLE (an unreadable block is DEGRADED, exit 1) ............ TestBlockUnreadableIsNeverClean

func TestVbLinesCountsLikeAwk(t *testing.T) {
	d := t.TempDir()
	v := fsView{View: fsview.View{Cwd: d}}
	for _, c := range []struct {
		content string
		end     int64
		want    int64
	}{
		{"", 0, 0}, {"a", 0, 1}, {"a\n", 0, 1}, {"a\nb", 0, 2}, {"a\n\n", 0, 2}, {"a\r\nb\r\n", 0, 2},
		{"a\nb\nc\nd\n", 2, 2}, {"a\nb\nc\nd\n", 4, 4}, {"a\nb\n", 9, 2}, {"a\nb\nc", 3, 3}, {"a\nb\nc", 1, 1},
	} {
		p := filepath.Join(d, "f")
		if err := os.WriteFile(p, []byte(c.content), 0o644); err != nil {
			t.Fatal(err)
		}
		if got, ok := v.vbLines(p, c.end); !ok || got != c.want {
			t.Errorf("vbLines(%q, %d) = %d,%v want %d", c.content, c.end, got, ok, c.want)
		}
	}
	if _, ok := v.vbLines(filepath.Join(d, "missing"), 0); ok {
		t.Error("an unreadable file must fail the counter, never read as zero lines")
	}
}

func TestShellIntBounds(t *testing.T) {
	for _, c := range []struct {
		in string
		v  int64
		ok bool
	}{{"0", 0, true}, {"007", 7, true}, {"9223372036854775807", 1<<63 - 1, true}, {"9223372036854775808", 0, false}, {"", 0, false}, {"1x", 0, false}} {
		if v, ok := shellInt(c.in); v != c.v || ok != c.ok {
			t.Errorf("shellInt(%q) = %d,%v want %d,%v", c.in, v, ok, c.v, c.ok)
		}
	}
}

func TestSplitRange(t *testing.T) {
	for in, want := range map[string][2]string{"5": {"5", "5"}, "2-9": {"2", "9"}, "01-1": {"01", "1"}} {
		if s, e := splitRange(in); s != want[0] || e != want[1] {
			t.Errorf("splitRange(%q) = %q,%q want %q,%q", in, s, e, want[0], want[1])
		}
	}
	if got := citeFile("a/b.go:12-14"); got != "a/b.go" {
		t.Errorf("citeFile = %q", got)
	}
	if got := citeFile("plain"); got != "plain" {
		t.Errorf("citeFile without colon = %q", got)
	}
}

func TestGrepOWordStartBoundary(t *testing.T) {
	for _, c := range []struct {
		in   string
		want []string
	}{
		{"B12-x.txt:3", []string{"B12-x.txt:3"}},
		{"(B12-x.txt:3)", []string{"B12-x.txt:3"}},
		{"verbB12-x.txt:3", nil},
		{"_B12-x.txt:3", nil},
		{"éB12-x.txt:3", nil},
		{"verbB12-x.txt:3 B13-y.log:4", []string{"B13-y.log:4"}},
		{"B12-3:44", nil}, // an all-digit remainder is prose, not an artifact
		{"b5-ab.txt:1‑2", []string{"b5-ab.txt:1‑2"}},
	} {
		got := grepOWordStart(vbArtCite, c.in)
		if strings.Join(got, "|") != strings.Join(c.want, "|") {
			t.Errorf("grepOWordStart(%q) = %q want %q", c.in, got, c.want)
		}
	}
}

func TestPfScanLadderBoundary(t *testing.T) {
	route := func(n int) []string {
		l := []string{"## S", "It is not possible to read it."}
		for i := 1; i <= n; i++ {
			l = append(l, "- Route "+string(rune('0'+i))+": x")
		}
		return append(l, "Cheapest: route 1")
	}
	if got := len(pfScan(route(2))); got != 1 {
		t.Errorf("2 routes: %d hits, want 1", got)
	}
	if got := len(pfScan(route(3))); got != 0 {
		t.Errorf("3 routes + cheapest: %d hits, want 0", got)
	}
	noCheapest := route(3)
	noCheapest = noCheapest[:len(noCheapest)-1]
	if got := len(pfScan(noCheapest)); got != 1 {
		t.Errorf("3 routes without cheapest: %d hits, want 1", got)
	}
	if h := pfScan([]string{"x", "A physically impossible value and an Impossible Reading", "```", "no way to", "```", "not with grep, measured: it is not possible"}); len(h) != 0 {
		t.Errorf("measurement language, fences and the measured-negative form must not fire: %+v", h)
	}
	if h := pfScan([]string{"Cannot be DETERMINED here"}); len(h) != 1 || h[0].ph != "cannot be determined" || h[0].line != 1 {
		t.Errorf("verdict phrase is reported lower-cased with its line: %+v", h)
	}
}

func TestHasDigestBoundary(t *testing.T) {
	d64, d63, d65 := strings.Repeat("a", 64), strings.Repeat("a", 63), strings.Repeat("a", 65)
	for _, c := range []struct {
		line string
		want bool
	}{{"sha256 " + d64, true}, {"SHA256: " + strings.ToUpper(d64), true}, {"sha256 " + d63, false}, {"sha256 " + d65, false}, {d64, false}, {"sha256 " + d63 + " x " + d64, true}} {
		if got := hasDigest(c.line); got != c.want {
			t.Errorf("hasDigest(%q) = %v want %v", c.line, got, c.want)
		}
	}
}

func TestSkipScratch(t *testing.T) {
	for _, c := range []struct {
		tok  string
		spad bool
		want bool
	}{
		{"scratchpad/x", true, false}, {"a/scratchpad/x", true, false}, {"ascratchpad/x", true, true},
		{"/tmp/scratchpad/x", true, true}, {"$TMPDIR/scratchpad/x", true, true}, {"${TMPDIR}/scratchpad/x", true, true},
		{"/private/var/tmp/scratchpad/x", true, true}, {"/home/u/scratchpad/x", true, false}, {"ascratchpad/x", false, false},
	} {
		if got := skipScratch(c.tok, c.spad); got != c.want {
			t.Errorf("skipScratch(%q,%v) = %v want %v", c.tok, c.spad, got, c.want)
		}
	}
}

func TestCutBytes(t *testing.T) {
	if got := cutBytes("abc", 3); got != "abc" {
		t.Errorf("cutBytes at the limit = %q", got)
	}
	if got := cutBytes("abcd", 3); got != "abc" {
		t.Errorf("cutBytes past the limit = %q", got)
	}
	if got := cutBytes("ééé", 3); len(got) != 3 {
		t.Errorf("cutBytes counts bytes, got %d", len(got))
	}
}

func TestDedupeByLine(t *testing.T) {
	got := dedupeByLine([]string{"10:b", "2:a", "10:c", "2:z", "1:q"})
	if strings.Join(got, "|") != "1:q|2:a|10:b" {
		t.Errorf("dedupeByLine = %q (numeric order, first line seen kept)", got)
	}
}

func TestSourcePDF(t *testing.T) {
	for _, c := range []struct {
		lines []string
		want  string
	}{
		{[]string{"source_pdf: a/b.pdf"}, "a/b.pdf"}, {[]string{"x", "- source_pdf: p: q"}, "p"}, {[]string{"source_pdf:nospace"}, ""},
		{[]string{"source_pdf: first", "source_pdf: second"}, "first"}, {[]string{"none"}, ""},
	} {
		if got := sourcePDF(c.lines); got != c.want {
			t.Errorf("sourcePDF(%q) = %q want %q", c.lines, got, c.want)
		}
	}
	for in, want := range map[string]string{"a.b.pdf": "a.b", "noext": "noext", ".hid": ""} {
		if got := vbStripExt(in); got != want {
			t.Errorf("vbStripExt(%q) = %q want %q", in, got, want)
		}
	}
}

func TestJoinFind(t *testing.T) {
	for _, c := range [][3]string{{"d", "f", "d/f"}, {"d/", "f", "d/f"}, {"/", "f", "/f"}, {"d//", "f", "d//f"}} {
		if got := joinFind(c[0], c[1]); got != c[2] {
			t.Errorf("joinFind(%q,%q) = %q want %q", c[0], c[1], got, c[2])
		}
	}
}

func TestSplitNonpathGuards(t *testing.T) {
	b := &blockRun{fs: fsView{View: fsview.View{Cwd: t.TempDir()}}, target: t.TempDir()}
	np := func(cites ...string) string {
		n, _ := b.splitNonpath(cites)
		return strings.Join(n, "|")
	}
	if got := np("127.0.0.1:80", "api.example.org:443", "javax.baja.Foo:238", "notes.v1.org:7", "analysis.v2.R:3", "data.clean.R:3", "com.example.my_app.R:9", "uk.co.acme.R:2", "de.v2.report.R:1", "org.foo.Log:5"); got != "127.0.0.1:80|api.example.org:443|javax.baja.Foo:238|com.example.my_app.R:9|uk.co.acme.R:2|org.foo.Log:5" {
		t.Errorf("nonpath set = %q", got)
	}
	if !versioned("a.v1") || !versioned("v2") || !versioned("v1.b") || versioned("v2x") || versioned("xv1") {
		t.Error("version-like label rule drifted")
	}
}

func TestScanCorrectionsFilters(t *testing.T) {
	scan := func(self int, lines ...string) ([]bpCand, bpTrailer) {
		c, tr, _ := scanCorrections(lines, self)
		return c, tr
	}
	if c, _ := scan(7, "This corrects [Block 3] clearly."); len(c) != 1 || c[0].conf != "high" || c[0].num != 3 || c[0].line != 1 {
		t.Errorf("a correction of an earlier keyword cite is a high-confidence candidate: %+v", c)
	}
	if c, tr := scan(7, "This corrects Block 3 and Block 9."); len(c) != 1 || tr.forward != 1 {
		t.Errorf("a later block is a forward pointer: %+v %+v", c, tr)
	}
	if c, tr := scan(7, "No correction of Block 3 here."); len(c) != 0 || tr.neg != 1 {
		t.Errorf("negation: %+v %+v", c, tr)
	}
	if _, tr := scan(7, "A corrigendum for Block 3."); tr.noun != 1 {
		t.Errorf("noun: %+v", tr)
	}
	if _, tr := scan(7, "Block 3 was corrected."); tr.passive != 1 {
		t.Errorf("passive: %+v", tr)
	}
	if _, tr := scan(7, "A self-correction of Block 3."); tr.self != 1 {
		t.Errorf("self: %+v", tr)
	}
	if c, tr := scan(7, "Fixed in B3, corrected by B5."); tr.corrector != 1 || len(c) != 1 {
		t.Errorf("the corrector is dropped, the corrected kept: %+v %+v", c, tr)
	}
	if c, tr := scan(9, "We refute B1 and B2 and B3."); len(c) != 0 || tr.list != 1 {
		t.Errorf("3+ blocks is a cross-reference list: %+v %+v", c, tr)
	}
	far := "This corrects " + strings.Repeat("x", 70) + " Block 3."
	if c, tr := scan(9, far); len(c) != 0 || tr.far != 1 {
		t.Errorf("a cite 60+ characters away is far: %+v %+v", c, tr)
	}
	if c, _ := scan(9, "Block 3 is the one this corrects."); len(c) != 1 || c[0].conf != "low" {
		t.Errorf("an act after the cite is low confidence: %+v", c)
	}
	if c, _, r := scanCorrections([]string{"# Block R7 — t", "", "This refutes R3."}, 7); !r || len(c) != 1 || c[0].ser != "R" || c[0].num != 3 {
		t.Errorf("a bare RN is a cite only in an R-numbered corpus: %+v %v", c, r)
	}
	if c, _, r := scanCorrections([]string{"This refutes R3."}, 7); r || len(c) != 0 {
		t.Errorf("a bare RN outside an R corpus is not a cite: %+v %v", c, r)
	}
}

func TestAwkSubstr(t *testing.T) {
	for _, c := range []struct {
		s        string
		start, n int
		want     string
	}{{"héllo", 2, 3, "éll"}, {"abc", 0, 2, "a"}, {"abc", -1, 3, "a"}, {"abc", 4, 1, ""}, {"abc", 2, 0, ""}, {"abc", 2, 99, "bc"}} {
		if got := awkSubstr(c.s, c.start, c.n); got != c.want {
			t.Errorf("awkSubstr(%q,%d,%d) = %q want %q", c.s, c.start, c.n, got, c.want)
		}
	}
	if got := awkLower("ÀBc"); got != "àbc" {
		t.Errorf("awkLower = %q", got)
	}
}
