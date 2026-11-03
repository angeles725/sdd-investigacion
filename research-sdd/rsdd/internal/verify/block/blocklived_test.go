//go:build unix

package block

import (
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/testkit/observed"
)

// Tests added for the gremlins mutants of this package that survived (PR #2598 teeth run). One rule per case or test,
// named after the rule it pins. The hand cases below get their expected output from the frozen legacy script (the
// goldens are recorded by the differential under !nodiff), so the mutant run, which builds with nodiff, still
// kills them without bash. Guard -> test:
//
//	gitTopLevel / extra git root for a cite ............ lived-git-toplevel-root
//	TARGET-ROOT from a `corpus` ancestor ................ lived-corpus-target-root, lived-corpus-no-marker
//	empty-digest ellipsis (16 vs 17 chars) .............. lived-digest-elided-16
//	ephemeral-ok marker at the start of a line .......... lived-ephemeral-marker-at-line-start
//	OCR extract found through its source_pdf or loose key  lived-ocr-pdf-basename-and-loose-key
//	manifest: no findings line, every manifest, row forms lived-manifest-*
//	nonpath: two-letter package labels az / za .......... lived-nonpath-package-az-za
//	Class.method: ext and stem boundaries ............... lived-methodlike-boundaries
//	P6 probe coverage / marker sums / legend fence ...... lived-probe-coverage-*, lived-marker-sums, lived-legend-*
//	BP-SERIES / second pass / low-confidence / counters . lived-backptr-*

func bkLivedCases() []bkCase {
	blk := func(name, body string) bkFile { return bkFile{rel: name, data: bkLegend + body} }
	hc := func(name string, args []string, env map[string]string, files ...bkFile) bkCase {
		if env == nil {
			env = map[string]string{}
		}
		return bkCase{name: "hand/" + name, args: args, env: env, files: files}
	}
	sum := func(s string) string { h := sha256.Sum256([]byte(s)); return hex.EncodeToString(h[:]) }
	mf := func(dir string, rows ...string) bkFile {
		return bkFile{rel: "sources/probes/" + dir + "/SCRIPTS-MANIFEST.md", data: "| script | sha256 | run | block | on | remote | role |\n|---|---|---|---|---|---|---|\n" + strings.Join(rows, "\n") + "\n"}
	}
	fakeGit := []bkFile{{rel: ".git/HEAD", data: "ref: refs/heads/main\n"}, {rel: ".git/objects", dir: true}, {rel: ".git/refs", dir: true}}
	home := map[string]string{"HOME": "@D@/home"} // a HOME outside the corpus root, or the HOME guard refuses it
	homeDir := bkFile{rel: "home", dir: true}
	run := bkFile{rel: "sources/probes/b1/run.sh", data: "echo hi\n"}
	other := bkFile{rel: "sources/probes/b2/other.sh", data: "echo two\n"}
	blockN := func(n string) string { return "# Block " + n + " — t\n\n" }

	cases := []bkCase{
		hc("lived-git-toplevel-root", []string{"sub/b.md", "sub"}, nil,
			append([]bkFile{blk("sub/b.md", "`top.go:1`\n"), {rel: "top.go", data: "x\n"}}, fakeGit...)...),
		hc("lived-corpus-target-root", []string{"proj/corpus/sub/b.md", "proj/corpus/sub"}, home,
			blk("proj/corpus/sub/b.md", "`top.go:1` `top.go:1-9`\n"), bkFile{rel: "proj/go.mod", data: "m\n"}, bkFile{rel: "proj/top.go", data: "x\n"}, homeDir),
		hc("lived-corpus-no-marker", []string{"proj/corpus/b.md", "proj/corpus"}, home,
			blk("proj/corpus/b.md", "`top.go:1`\n"), bkFile{rel: "proj/top.go", data: "x\n"}, homeDir),
		hc("lived-digest-elided-16", []string{"b.md"}, nil,
			blk("b.md", "sha256 e3b0c44298fc1c14… and e3b0c44298fc1c149...\n")),
		hc("lived-ephemeral-marker-at-line-start", []string{"b.md"}, nil,
			blk("b.md", "<!-- ephemeral-ok: spot check --> /tmp/a/b\n<!-- ephemeral-ok: --> /tmp/c/d\nsee /tmp/e/f <!-- ephemeral-ok:--> x\n")),
		hc("lived-ocr-pdf-basename-and-loose-key", []string{"b.md"}, nil,
			blk("b.md", "numbers come from the tufte scan only\nkappa-sigma noted\n"),
			bkFile{rel: "sources/extracted/zeta-extract-doc.md", data: "reliability: ocr-lossy\nsource_pdf: docs/tufte.pdf\n"},
			bkFile{rel: "sources/extracted/kappa-sigma-two.md", data: "extracted via OCR\n"}),
		hc("lived-manifest-all-ok", []string{"b.md"}, nil,
			blk("b.md", "`sources/probes/b1/run.sh`\n"), run, mf("b1", "| run.sh | "+sum(run.data)+" |")),
		hc("lived-manifest-every-manifest", []string{"b.md"}, nil,
			blk("b.md", "`sources/probes/b1/run.sh` `sources/probes/b2/other.sh`\n"), run, other,
			mf("b1", "| run.sh | "+sum(run.data)+" |"), mf("b2", "| other.sh | "+sum(other.data)+" |")),
		hc("lived-manifest-row-forms", []string{"b.md"}, nil,
			blk("b.md", "`sources/probes/b1/run.sh` `sources/probes/b1/lonely.sh` `sources/probes/b1/bad.sh`\n"), run,
			bkFile{rel: "sources/probes/b1/lonely.sh", data: "x\n"}, bkFile{rel: "sources/probes/b1/bad.sh", data: "y\n"},
			mf("b1", "| run.sh | "+sum(run.data)+" |", "| lonely.sh", "| bad.sh | "+strings.Repeat("a", 63)+"g |")),
		hc("lived-nonpath-package-az-za", []string{"b.md"}, nil, blk("b.md", "`az.x.R:1` `za.x.R:2`\n")),
		hc("lived-methodlike-boundaries", []string{"b.md"}, nil,
			blk("b.md", "`Abc.alpha:5` `Abc.zeta:6` `Aaa.qux:3` `Zaa.qux:4` `abc.xYz:7`\n")),
		hc("lived-probe-coverage-equal", []string{"b.md"}, nil, blk("b.md", "x [CERT] `sources/probes/b1/run.sh`\n"), run),
		hc("lived-marker-sums", []string{"b.md"}, nil,
			blk("b.md", "[CERT-hw]\n"+strings.Repeat("[CERT-live] ", 2)+"\n"+strings.Repeat("[CERT] ", 4)+"\n"+strings.Repeat("[CERT-doc] ", 8)+"\n"+
				strings.Repeat("[CERT-web] ", 16)+"\n"+strings.Repeat("[CERT-a] ", 32)+"\n[INFER]\n`sources/probes/b1/run.sh`\n"), run),
		hc("lived-legend-marker-before-fence", []string{"b.md"}, nil,
			bkFile{rel: "b.md", data: "# Block 1 — t\n> Method: [CERT] = x\n> [CERT-a] last\n---\n\nbody [CERT]\n"}),
		hc("lived-backptr-series-mismatch", []string{"x-block3.md"}, nil,
			bkFile{rel: "x-block3.md", data: blockN("3") + "This corrects Block 1.\n"}, bkFile{rel: "x-block1.md", data: "# Block R1\nBlock 3 points back\n"}),
		hc("lived-backptr-other-prefix-only", []string{"x-block3.md"}, nil,
			bkFile{rel: "x-block3.md", data: blockN("3") + "This corrects Block 1.\n"}, bkFile{rel: "y-block1.md", data: "# Block 1\n"}),
		hc("lived-backptr-low-confidence-present", []string{"x-block9.md"}, nil,
			bkFile{rel: "x-block9.md", data: blockN("9") + "Block 4 is the one this corrects.\n"}, bkFile{rel: "x-block4.md", data: "# Block 4\nsee Block 9\n"}),
		hc("lived-backptr-missing-and-notfound", []string{"x-block9.md"}, nil,
			bkFile{rel: "x-block9.md", data: blockN("9") + "This corrects Block 1.\n\nThis corrects Block 2.\n"}, bkFile{rel: "x-block1.md", data: "# Block 1\nnothing\n"}),
		hc("lived-backptr-corrector-window", []string{"x-block9.md"}, nil,
			bkFile{rel: "x-block9.md", data: blockN("9") + "This corrects Block 1, corrected" + strings.Repeat(" ", 45) + "by Block 2.\n"},
			bkFile{rel: "x-block1.md", data: "# Block 1\nno pointer\n"}, bkFile{rel: "x-block2.md", data: "# Block 2\nno pointer\n"}),
		hc("lived-backptr-notfound-and-ambiguous", []string{"x-block9.md"}, nil,
			bkFile{rel: "x-block9.md", data: blockN("9") + "This corrects Block 1.\n\nThis corrects Block 2.\n"},
			bkFile{rel: "x-block1.md", data: "# Block 1\n"}, bkFile{rel: "x-block1-slug.md", data: "# Block 1\n"}),
	}
	return append(cases, bkScanEdgeCase())
}

// bkScanEdgeSentences are correction sentences, each citing its own earlier block (number n) of a corpus where every
// cited block exists without a pointer back: the high-confidence ones print a BACKPTR? line, the others only count.
func bkScanEdgeSentences() (self string, sents map[int]string) {
	x := func(n int) string { return strings.Repeat("x", n) }
	return "99", map[int]string{
		11: "This corrects " + x(58) + " Block 11.",
		12: "This corrects " + x(59) + " Block 12.",
		13: "This corrects " + x(23) + " Block 13.",
		14: "This corrects " + x(24) + " Block 14.",
		15: "Block 15 " + x(50) + " corrects.",
		16: "refut x Block 16 x refut",
		17: "Block 17 x correcting",
		18: "this corrects block 18 clearly.",
		19: "It is not only fine so this corrects " + x(23) + " Block 19.",
		10: "This corrects Block 10.",
	}
}

func bkScanEdgeCase() bkCase {
	self, sents := bkScanEdgeSentences()
	body := "# Block " + self + " — t\n\n"
	files := []bkFile{}
	for n := 10; n <= 19; n++ {
		body += sents[n] + "\n\n"
		files = append(files, bkFile{rel: "x-block" + strconv.Itoa(n) + ".md", data: "# Block " + strconv.Itoa(n) + "\nno pointer\n"})
	}
	body += "This corrects Block 21 · Block 22 · and more.\n\nThis corrects B0x.\n\nThis corrects B9x.\n\nThis refutes R0.\n\nThis refutes R9.\n"
	files = append(files, bkFile{rel: "x-block" + self + ".md", data: body})
	return bkCase{name: "hand/lived-backptr-scan-edges", args: []string{"x-block" + self + ".md"}, env: map[string]string{}, files: files}
}

func TestAwkSubstrTailEdges(t *testing.T) {
	if got := awkSubstr("abc", 3, 1); got != "c" {
		t.Errorf("awkSubstr at the last character = %q, want %q", got, "c")
	}
	for _, c := range []struct {
		s     string
		start int
		want  string
	}{{"abc", 1, "abc"}, {"abc", 2, "bc"}, {"héllo", 1, "héllo"}, {"héllo", 3, "llo"}, {"abc", 4, ""}} {
		if got := awkTail(c.s, c.start); got != c.want {
			t.Errorf("awkTail(%q,%d) = %q want %q", c.s, c.start, got, c.want)
		}
	}
}

func TestLeadingSeparatorSplits(t *testing.T) {
	if s, e := splitRange("-5"); s != "" || e != "5" {
		t.Errorf("splitRange(-5) = %q,%q want empty start and 5 (${rng%%-*} / ${rng##*-})", s, e)
	}
	if got := citeFile(":5"); got != "" {
		t.Errorf("citeFile(:5) = %q want empty (${c%%:*})", got)
	}
}

func TestIsLowerAlnumUnderscoreEdges(t *testing.T) {
	for _, c := range []byte("az09_") {
		if !isLowerAlnumUnderscore(c) {
			t.Errorf("%q is a word character", c)
		}
	}
	for _, c := range []byte("`{/:@AZ-") {
		if isLowerAlnumUnderscore(c) {
			t.Errorf("%q is not a lower-case word character", c)
		}
	}
}

func TestScanCorrectionsLivedEdges(t *testing.T) {
	scan := func(self int, lines ...string) ([]bpCand, bpTrailer) {
		c, tr, _ := scanCorrections(lines, self)
		return c, tr
	}
	x := func(n int) string { return strings.Repeat("x", n) }
	// BP-POSTTOK: a cite glued to a following letter is not a cite; the digit range of the token is 0-9, ends included.
	if c, _, r := scanCorrections([]string{"# Block R9 — t", "", "This refutes R3x."}, 9); !r || len(c) != 0 {
		t.Errorf("R3x in an R corpus is not a cite: %+v %v", c, r)
	}
	for _, s := range []string{"This corrects B0x.", "This corrects B9x."} {
		if c, _ := scan(20, s); len(c) != 0 {
			t.Errorf("%q: a B<digit> glued to a letter is not a cite: %+v", s, c)
		}
	}
	// BP-RMODE: a bare R<digit> outside an R corpus is not a cite, for every digit.
	for _, s := range []string{"This refutes R0.", "This refutes R9."} {
		if c, _ := scan(7, s); len(c) != 0 {
			t.Errorf("%q outside an R corpus: %+v", s, c)
		}
	}
	// The keyword in lower case is still the keyword form.
	if c, _ := scan(7, "this corrects block 3 clearly."); len(c) != 1 || c[0].conf != "high" {
		t.Errorf("a lower-case `block 3` after a correction act is high confidence: %+v", c)
	}
	// BP-PROXIMITY is 60 characters, inclusive; BP-CONF is 25, inclusive.
	if c, tr := scan(9, "This corrects "+x(58)+" Block 3."); len(c) != 1 || tr.far != 0 {
		t.Errorf("a gap of exactly 60 is near: %+v %+v", c, tr)
	}
	if c, tr := scan(9, "This corrects "+x(59)+" Block 3."); len(c) != 0 || tr.far != 1 {
		t.Errorf("a gap of 61 is far: %+v %+v", c, tr)
	}
	if c, _ := scan(9, "This corrects "+x(23)+" Block 3."); len(c) != 1 || c[0].conf != "high" {
		t.Errorf("a gap of exactly 25 is still high confidence: %+v", c)
	}
	if c, _ := scan(9, "This corrects "+x(24)+" Block 3."); len(c) != 1 || c[0].conf != "low" {
		t.Errorf("a gap of 26 is low confidence: %+v", c)
	}
	// The gap to an act AFTER the cite is measured from the end of the cite.
	if c, tr := scan(9, "Block 3 "+x(50)+" corrects."); len(c) != 1 || tr.far != 0 {
		t.Errorf("an act 52 characters after the cite is near: %+v %+v", c, tr)
	}
	// Two acts at the same distance: the first one found decides.
	if c, _ := scan(9, "refut x Block 3 x refut"); len(c) != 1 || c[0].conf != "high" {
		t.Errorf("a tie between two acts goes to the first (the one before the cite): %+v", c)
	}
	// An act after the cite whose long name overlaps the cite's position is still after it.
	if c, _ := scan(9, "Block 3 x correcting"); len(c) != 1 || c[0].conf != "low" {
		t.Errorf("an act after the cite, not adjoining it, is low confidence: %+v", c)
	}
	// The block number keeps its zeros.
	if c, _ := scan(20, "This corrects Block 10."); len(c) != 1 || c[0].num != 10 {
		t.Errorf("Block 10 is number 10: %+v", c)
	}
	// BP-CORRECTOR looks at the 40 characters before the cite only: an act 45 blanks earlier is out of reach.
	if c, tr := scan(9, "This corrects Block 1, corrected"+strings.Repeat(" ", 45)+"by Block 2."); len(c) != 2 || tr.corrector != 0 {
		t.Errorf("a corrector phrase further than 40 characters before the cite is not a corrector: %+v %+v", c, tr)
	}
	if c, tr := scan(9, "This corrects Block 1, corrected"+strings.Repeat(" ", 5)+"by Block 2."); len(c) != 1 || tr.corrector != 1 {
		t.Errorf("a corrector phrase within 40 characters drops the cite: %+v %+v", c, tr)
	}
	// BP-LIST: two cites joined by two middle dots are a list.
	if c, tr := scan(20, "This corrects Block 3 · Block 4 · and more."); len(c) != 0 || tr.list != 1 {
		t.Errorf("two cites and two separators are a list: %+v %+v", c, tr)
	}
}

// bkChmodRun runs the command on a corpus directory holding the given files, with the named ones made unreadable.
// It skips when a mode-000 file is still readable (root).
func bkChmodRun(t *testing.T, env map[string]string, args []string, files map[string]string, unreadable ...string) observed.Run {
	t.Helper()
	d, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	for rel, data := range files {
		p := filepath.Join(d, rel)
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(strings.ReplaceAll(data, bkDirToken, d)), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	for _, rel := range unreadable {
		p := filepath.Join(d, rel)
		if err := os.Chmod(p, 0); err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { os.Chmod(p, 0o644) }) //nolint:errcheck // so t.TempDir can remove it
		if f, err := os.Open(p); err == nil {
			f.Close()
			t.Skip("a mode-000 file is still readable here (running as root)")
		}
	}
	e := []string{"HOME=" + d, "LC_ALL=C.UTF-8"}
	for k, v := range env {
		e = append(e, k+"="+strings.ReplaceAll(v, bkDirToken, d))
	}
	return bkGo(d, args, e)
}

// A cite found in a later root is resolved even when an earlier root holds an unreadable file of that name: the
// degraded line count is reported only when no root resolved the cite (BT-FIT-DEGRADED).
func TestBacktickResolvesInLaterRootDespiteUnreadableEarlier(t *testing.T) {
	got := bkChmodRun(t, map[string]string{"SOURCE_ROOT": "@D@/src"}, []string{"b.md"},
		map[string]string{"b.md": bkLegend + "`x.go:2`\n", "x.go": "one\n", "src/x.go": "a\nb\nc\n"}, "x.go")
	for _, want := range []string{"   ok      x.go:2\n", "   resolved 1 of 1 (0 extern, 0 failed)\n", "== exit 0 ==\n"} {
		if !strings.Contains(got.Stdout, want) {
			t.Errorf("stdout lacks %q\n%s", want, got.Stdout)
		}
	}
	if strings.Contains(got.Stdout, "DEGRADED") {
		t.Errorf("a resolved cite must not read as degraded:\n%s", got.Stdout)
	}
}

// The back-pointer summary is printed when only some candidates are typed: one unreadable candidate file (degraded)
// and one with a pointer (present) still make a non-empty section.
func TestBackptrDegradedAndPresentIsNotNone(t *testing.T) {
	got := bkChmodRun(t, nil, []string{"x-block9.md"}, map[string]string{
		"x-block9.md": "# Block 9 — t\n\nThis corrects Block 1.\n\nThis corrects Block 2.\n",
		"x-block1.md": "# Block 1\n",
		"x-block2.md": "# Block 2\nsee Block 9\n",
	}, "x-block1.md")
	if strings.Contains(got.Stdout, "(none — no correction sentence") {
		t.Errorf("one degraded and one present candidate is not an empty section:\n%s", got.Stdout)
	}
	if want := "-- back-pointer: 0 possibly missing · 1 present · 0 ambiguous · 0 not found · 1 degraded (correction sentences: 2;"; !strings.Contains(got.Stdout, want) {
		t.Errorf("stdout lacks %q\n%s", want, got.Stdout)
	}
}
