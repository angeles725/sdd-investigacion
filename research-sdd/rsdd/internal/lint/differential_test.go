//go:build !nodiff

package lint

import (
	"fmt"
	"math/rand"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"syscall"
	"testing"
)

func fixtureFiles(t *testing.T, dir string) []string {
	t.Helper()
	ents, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	var out []string
	for _, e := range ents {
		if !e.IsDir() && strings.HasSuffix(e.Name(), ".md") {
			out = append(out, e.Name())
		}
	}
	sort.Strings(out)
	if len(out) < 60 {
		t.Fatalf("empty-input: only %d fixtures in %s", len(out), dir)
	}
	return out
}

// Every fixture, in FAIL and --audit mode, in one legacy spawn per mode (the whole output is compared).
func TestLintBlockDifferentialFixtures(t *testing.T) {
	t.Parallel()
	fx := fixtures(t)
	files := fixtureFiles(t, fx)
	same(t, "fail", fx, files...)
	same(t, "audit", fx, append([]string{"--audit"}, files...)...)
}

func TestLintBlockDifferentialCorpora(t *testing.T) {
	t.Parallel()
	fx := fixtures(t)
	for _, d := range []string{"corpus", "corpus-empty", "corpus-nomatch", "corpus-unclassified", "corpus/", "nested-nope"} {
		same(t, "audit "+d, fx, "--audit", d)
		same(t, "fail "+d, fx, d)
	}
	same(t, "two dirs", fx, "--audit", "corpus", "corpus-nomatch", "corpus-empty")
	same(t, "dir+file+absent", fx, "--audit", "corpus", "r3-first.md", "absent.md")
	same(t, "-- terminator", fx, "--audit", "--", "r3-first.md")
}

func TestLintBlockDifferentialStatesAndUsage(t *testing.T) {
	t.Parallel()
	fx := fixtures(t)
	for _, args := range [][]string{
		{}, {"--bogus", "r3-first.md"}, {"-h"}, {"--help", "--bogus"}, {"--bogus", "-h"}, {"--audit"},
		{"--pack"}, {"--pack", ""}, {"--pack", "-x", "r3-first.md"}, {"--pack="}, {"--pack=-x", "r3-first.md"},
		{"absent.md"}, {"absent.md", "r3-first.md"}, {"--audit", "absent.md"}, {"absent.md", "r3-clean.md"},
		{"empty.md"}, {"blank.md"}, {"empty.md", "r3-clean.md"}, {"--audit", "empty.md"}, {"--audit", "empty.md", "blank.md"},
		{"r3-first.md", "r3-last.md", "r6-single.md"}, {"corpus-nomatch/demo-block1.md"}, {"/"},
	} {
		same(t, "args", fx, args...)
	}
}

// --pack runs are handed to the Python engine; the arguments, exit code and output must come through unchanged.
func TestLintBlockDifferentialPacks(t *testing.T) {
	t.Parallel()
	fx := fixtures(t)
	files := fixtureFiles(t, fx)
	for _, p := range []string{"jvm", "child-gap", "nope", "Bad", ","} {
		same(t, "pack "+p, fx, "--pack", p, "r3-first.md")
		same(t, "pack= "+p, fx, "--pack="+p, "--audit", "corpus")
	}
	same(t, "all packs", fx, "--pack", "jvm", "--pack=multi-version", "--pack", "native-binary,child-gap", "--audit", "corpus")
	same(t, "all packs files", fx, append([]string{"--pack", "jvm", "--pack", "multi-version", "--pack", "native-binary", "--pack", "child-gap"}, files...)...)
	same(t, "pack partial", fx, "--pack", "jvm", "absent.md", "pack-jvm.md")
}

func TestLintBlockDifferentialInputBytes(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	bad := []string{"\xff", "\xc3(", "\xe2\x82(", "\xe2\x82", "\xed\xa0\x80", "\xf0\x90\x80", "\xf4\x90\x80\x80", "\xc0\x80", "\x80", "\xe0\x80\x80", "\xf1\x80\x80", "\xf5", "\xc2"}
	var names []string
	for i, b := range bad {
		for j, pre := range []string{"", "ascii é中 ", strings.Repeat("x", 30)} {
			names = append(names, filepath.Base(write(t, dir, fmt.Sprintf("bad%02d-%d.md", i, j), pre+b+" tail\n")))
		}
	}
	names = append(names, filepath.Base(write(t, dir, "crlf.md", "## Self-verify\r\n| a | [CERT-hw] | /tmp/x |\r\n\r\n[Block 3] never shows it\r\n")))
	names = append(names, filepath.Base(write(t, dir, "cr.md", "## Self-verify\r- [CERT-hw] /tmp/x\r\rtext\r")))
	names = append(names, filepath.Base(write(t, dir, "bom.md", "\ufeff## Self-verify\n- [CERT-hw] /tmp/x\n")))
	names = append(names, filepath.Base(write(t, dir, "seps.md", "## Self-verify\n- [CERT-hw] /tmp/x\v- [CERT-hw] /tmp/y\f- [CERT-hw] /tmp/z\u2028- [CERT-hw] /tmp/w\u0085x\u001cy\u2029z\n")))
	names = append(names, filepath.Base(write(t, dir, "nul.md", "a\x00b\n- [CERT-hw] /tmp/x\n")))
	names = append(names, filepath.Base(write(t, dir, "nonl.md", "## Self-verify\n- [CERT-hw] /tmp/x")))
	names = append(names, filepath.Base(write(t, dir, "ws.md", "\u00a0\u2003\u3000\n\u0085\n")))
	names = append(names, filepath.Base(write(t, dir, "dir-block1.md", "")))
	if err := os.Mkdir(filepath.Join(dir, "d-block2.md"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("crlf.md", filepath.Join(dir, "link-block3.md")); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("nowhere.md", filepath.Join(dir, "dangling-block4.md")); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(".", filepath.Join(dir, "loop")); err != nil {
		t.Fatal(err)
	}
	if err := syscall.Mkfifo(filepath.Join(dir, "pipe-block5.md"), 0o644); err != nil { // exists, but `[ -f ]` is false
		t.Fatal(err)
	}
	same(t, "fifo is neither file nor directory", dir, "pipe-block5.md")
	same(t, "bytes audit", dir, append([]string{"--audit"}, names...)...)
	same(t, "bytes fail", dir, names...)
	same(t, "dir passed as file", dir, "d-block2.md")
	same(t, "symlink files", dir, "link-block3.md", "dangling-block4.md")
	same(t, "corpus with links", dir, "--audit", ".")
	same(t, "symlinked root", dir, "--audit", "loop")
	same(t, "symlinked root slash", dir, "--audit", "loop/")
	for _, f := range names[:6] {
		same(t, "single "+f, dir, f)
	}
}

func TestLintBlockDifferentialCorpusListing(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	for _, f := range []string{
		"a/x-block1.md", "a/b/y-bloque2-note.md", "a/node_modules/z-block3.md", "a/.git/h-block4.md", "a/.claude/c-block5.md",
		"a/venv/v-block6.md", "a/.venv/v-block7.md", "a/site-packages/s-block8.md", "a/.atl/t-block9.md", "a/notes.md", "a/block10.md",
		"a/-block11.md", "a/ok-block12-x_y-z.md", "a/ok-block12-x y.md", "a/UP-BLOCK13.md", "a/z-block14.MD", "a/n.txt", "a/é-block15.md",
		"a/sp ace-block16.md", "a/m-block1.md.md", "a/q-blockx.md",
	} {
		write(t, dir, f, "## Self-verify\n- [CERT-hw] /tmp/x\n")
	}
	same(t, "listing", dir, "--audit", "a")
	same(t, "listing slash", dir, "--audit", "a/")
	same(t, "listing abs", dir, "--audit", filepath.Join(dir, "a"))
	same(t, "listing sub", dir, "--audit", "a/b")
	if os.Geteuid() != 0 {
		blocked := filepath.Join(dir, "a", "locked")
		write(t, dir, "a/locked/l-block1.md", "x\n")
		unread := write(t, dir, "a/unread-block20.md", "x\n")
		if err := os.Chmod(unread, 0); err != nil {
			t.Fatal(err)
		}
		if err := os.Chmod(blocked, 0); err != nil {
			t.Fatal(err)
		}
		defer os.Chmod(blocked, 0o755) //nolint:errcheck
		same(t, "degraded listing", dir, "--audit", "a")
		same(t, "unreadable file", dir, "a/unread-block20.md", "a/x-block1.md")
	}
}

// ---- generated documents ---------------------------------------------------------------------------------

var vocab = []string{
	"## Self-verify", "## Self verify", "### Selfverify notes", "## SELF‐VERIF checks", "# Other", "#hash tag", "####### seven", "## Self-verify", "## Evidence",
	"| Claim | Status | Evidence |", "|---|---|---|", "| a | [CERT-hw] | /tmp/x.txt |", "| a | [CERT-live] | evidence/ |", "| b | [CERT hw] | $TMPDIR/a, scratchpad |",
	"| c | [CERT‑live] | out.txt:12 |", "| d | [CERT-hw] | src/main.c:10-20 |", "|\u00a0e\u00a0|\u00a0[CERT-hw]\u00a0|\u00a0/var/tmp/q\u00a0|", "| f | [cert-HW] | /dev/shm/z | /tmp/y |", "| g | [CERT-hw] | demo-block12.md |",
	"- [CERT-hw] /tmp/a.txt", "- [CERT-live] see ${TMPDIR}/b then evidence/c", "1. [CERT-hw] /private/tmp/q", "٣. [CERT-hw] /tmp/arabic", "* [CERT-hw] binary/sha256 and/or 3/3 N/A", "- [CERT-hw] a/b/c.txt, /tmp/q.",
	"text [CERT-hw] (/tmp/x) more", "[CERT live] (evidence/a.md, /tmp/b)", "[CERT‐hw]: (scratchpad/z)", "see [CERT-hw]` — (/tmp/y (nested) q)", "[CERT-live] (a/b.c)", "[CERT-hw] no group /tmp/x",
	"[Block 3] does not mention foo", "[Block 12] never shows the thing", "[block 2] didn't cite x.", "[Block 4] did not include y; but never", "[Block 5] § 55.2 never contains it", "[BLOCK 6] doesn't show a",
	"[Block 7] x.never shows", "[Block 8] a. never shows", "[Block 9] a.b never shows", "[Block\u00a010] never mentions evidence/e1.md", "[Block 11] does not mentioned", "[Block 13] never showsx", "[Block 14] xnever shows",
	"[Block 15] énever shows", "[Block 16] never   shows  it", "[Block 17] — never shows", "[Block 18] does\u00a0not show", "[Block ٣] never cites", "[Block 19] never showed raw/out.log",
	"[Block 20] " + strings.Repeat("w ", 40) + "never shows", "[Block 21] " + strings.Repeat("w ", 41) + "never shows", "[Block 22] " + strings.Repeat("a.", 41) + " never shows",
	"<!-- lint-waive: R3 reason=ok -->", "<!--lint-ok: r3 free text-->", "<!-- lint-waive: R3 -->", "<!-- lint-waive: R12abc reason=x -->", "<!-- lint-waive: R3\u00a0reason=x -->",
	"<!-- lint-waive: R4 reason=y -->", "<!-- lint-waive: R٣ reason=z -->", "<!-- lint-waive: reason=no rule -->", "<!-- lint-ok: R6 with alias reason -->", "<!-- LINT-WAIVE: R6 reason=up -->", "<!-- lint-waive: R6 reason=  -->",
	"<!-- lint-waive: r6 reason=lower -->", "<!-- lint-waive: R99 reason=unknown -->", "<!-- lint-waive: R3 reason=a --> <!-- lint-ok: R6 b -->", "<!-- lint-waive: R1é reason=word -->",
	"```", "~~~", "````", ">```", "``` text", "   ~~~~", "> quoted [Block 3] never shows", "> | a | [CERT-hw] | /tmp/q |", "> ## Self-verify",
	"", "", "", "plain paragraph line", "a **bold [Block 3] does **not** show** b", "  indented continuation", "\t| tab | [CERT-hw] | /tmp/t |",
	"\u00a0| g | [CERT-hw] | /tmp/q |\u00a0", "| :--- | ---: |", "|:-:|", "###### six", "``", "<!-- lint-waive:   R3   reason=wide -->", "| h | [CERT-hw] | /private/tmp/p |", "| i | [CERT-hw] | /dev/shm/p |",
	"- [CERT-hw] (/tmp/a)(b)", "- [CERT-hw] x/y.elevenchars /tmp/z", "- [CERT-hw] x/y.12345a /tmp/z", "- [CERT-hw] x/y.a123456 /tmp/z", "[Block 3] doesnot show", "[Block 3] donot show",
	"Self-verify\n===", "Setext\n---", "- item one", "- item two [Block 3] never shows", "1) not a list", "\u00a0 nbsp lead",
}

func genDoc(r *rand.Rand) string {
	n := 3 + r.Intn(14)
	var b strings.Builder
	for i := 0; i < n; i++ {
		b.WriteString(vocab[r.Intn(len(vocab))])
		b.WriteByte('\n')
	}
	return b.String()
}

func TestLintBlockDifferentialGeneratedDocuments(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	r := rand.New(rand.NewSource(20261101))
	var names []string
	for i := 0; i < 600; i++ {
		names = append(names, filepath.Base(write(t, dir, fmt.Sprintf("g%03d.md", i), genDoc(r))))
	}
	same(t, "generated audit", dir, append([]string{"--audit"}, names...)...)
	same(t, "generated fail", dir, names...)
}
