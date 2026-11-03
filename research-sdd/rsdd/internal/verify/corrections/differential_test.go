//go:build !nodiff && unix

package corrections

import (
	"bytes"
	"fmt"
	"math/rand"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"testing"
)

// Differential tests: the frozen legacy script (testdata/legacy, the bytes of verify-corrections.sh before the
// port) and the Go command must print the same stdout and stderr and exit with the same code on the same
// corpus. A missing bash FAILS: a skipped differential proves nothing.

func (o observed) same(p observed) bool { return o == p }

// fixtureFiles reads a directory of testdata/fixtures as a corpus map (files only, one level).
func fixtureFiles(t *testing.T, name string) map[string]string {
	t.Helper()
	root := filepath.Join("testdata", "fixtures", name)
	ents, err := os.ReadDir(root)
	if err != nil {
		t.Fatalf("fixture dir %s: %v", root, err)
	}
	if len(ents) == 0 {
		t.Fatalf("fixture dir %s is empty", root)
	}
	m := map[string]string{}
	for _, e := range ents {
		b, err := os.ReadFile(filepath.Join(root, e.Name()))
		if err != nil {
			t.Fatal(err)
		}
		m[e.Name()] = string(b)
	}
	return m
}

// The oracle (the frozen script) needs this host: bash, find, grep, sed, sort and the default `awk` being GNU awk
// (gawk), all on PATH, and the C.UTF-8 locale (the script's second grep and its awk character handling follow the
// caller's locale, so the oracle runs under LC_ALL=C.UTF-8, never the host's). A host lacking any of them FAILS
// the differential with a typed message, never skips it: a skipped differential proves nothing (L5).
var (
	oracleOnce sync.Once
	oracleErr  error
)

func requireOracleHost(t *testing.T) {
	t.Helper()
	oracleOnce.Do(func() {
		for _, tool := range []string{"bash", "find", "grep", "sed", "sort", "awk"} {
			if _, err := exec.LookPath(tool); err != nil {
				oracleErr = fmt.Errorf("oracle tool %q not on PATH: %w", tool, err)
				return
			}
		}
		if out, err := exec.Command("awk", "--version").CombinedOutput(); err != nil || !strings.HasPrefix(string(out), "GNU Awk") {
			oracleErr = fmt.Errorf("the default awk is not GNU awk (gawk): %q", strings.SplitN(string(out), "\n", 2)[0])
			return
		}
		out, err := exec.Command("locale", "-a").Output()
		if err != nil {
			oracleErr = fmt.Errorf("cannot list locales (locale -a): %w", err)
			return
		}
		for _, l := range strings.Fields(string(out)) {
			if strings.EqualFold(strings.ReplaceAll(l, "-", ""), "C.UTF8") {
				return
			}
		}
		oracleErr = fmt.Errorf("the C.UTF-8 locale is not installed (locale -a lists none)")
	})
	if oracleErr != nil {
		t.Fatalf("differential: the oracle host is incomplete; the Go port is NOT proven against verify-corrections.sh: %v", oracleErr)
	}
}

// legacyScript is absolute and computed at init, while the working directory is still the package directory: a test
// that changes directory (the relative-target case) must still find the oracle.
var legacyScript, _ = filepath.Abs(filepath.Join("testdata", "legacy", "verify-corrections.sh"))

// runLegacy runs the frozen script on dir.
func runLegacy(t *testing.T, dir string) observed { return runLegacyArgs(t, "", dir) }

// runLegacyArgs runs the frozen script with the given arguments, in cwd when it is not empty.
func runLegacyArgs(t *testing.T, cwd string, args ...string) observed {
	t.Helper()
	requireOracleHost(t)
	bash, err := exec.LookPath("bash")
	if err != nil {
		t.Fatalf("differential: bash not found; the Go port is NOT proven against verify-corrections.sh: %v", err)
	}
	cmd := exec.Command(bash, append([]string{legacyScript}, args...)...)
	cmd.Dir = cwd
	cmd.Env = []string{"PATH=" + os.Getenv("PATH"), "HOME=" + t.TempDir(), "LC_ALL=C.UTF-8"}
	var out, errb bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errb
	code := 0
	if err := cmd.Run(); err != nil {
		ee, ok := err.(*exec.ExitError)
		if !ok {
			t.Fatalf("legacy run: %v", err)
		}
		code = ee.ExitCode()
	}
	return observed{out.String(), errb.String(), code}
}

func assertSame(t *testing.T, name, dir string) {
	t.Helper()
	want := runLegacy(t, dir)
	got := runGo(dir)
	if !got.same(want) {
		t.Errorf("%s: Go differs from the legacy script (exit legacy %d, go %d)\n%s%s", name, want.code, got.code,
			lineDiff("stdout", want.stdout, got.stdout), lineDiff("stderr", want.stderr, got.stderr))
	}
}

// lineDiff lists the lines present on one side only (a compact view of a long report).
func lineDiff(label, legacy, goOut string) string {
	set := func(s string) map[string]bool {
		m := map[string]bool{}
		for _, l := range strings.Split(s, "\n") {
			m[l] = true
		}
		return m
	}
	lm, gm := set(legacy), set(goOut)
	var b strings.Builder
	for _, l := range strings.Split(legacy, "\n") {
		if !gm[l] {
			fmt.Fprintf(&b, "  %s legacy only: %s\n", label, l)
		}
	}
	for _, l := range strings.Split(goOut, "\n") {
		if !lm[l] {
			fmt.Fprintf(&b, "  %s go only:     %s\n", label, l)
		}
	}
	if b.Len() == 0 && legacy != goOut {
		fmt.Fprintf(&b, "  %s: same lines, different order or multiplicity\n    legacy: %q\n    go:     %q\n", label, legacy, goOut)
	}
	return b.String()
}

func TestDifferentialFixtures(t *testing.T) {
	for _, name := range []string{"blender-wrapped", "real-1868", "real-1874"} {
		t.Run(name, func(t *testing.T) {
			dir := corpus(t, fixtureFiles(t, name))
			assertSame(t, name, dir)
			if o := runGo(dir); !strings.Contains(o.stdout, "AMBIG") && !strings.Contains(o.stdout, "FAIL") && !strings.Contains(o.stdout, "WARN") {
				t.Errorf("%s: the fixture exercised no finding at all:\n%s", name, o.stdout)
			}
		})
	}
}

// TestDifferentialGenerated compares the two implementations on seeded random corpora built from the shapes the
// extractor distinguishes (verbs and their non-assertive/negated/noun forms, refs and joined lists, parentheticals,
// bare B<N> refs, focus qualifiers, abbreviations, multi-byte text, reciprocal notes, FOCUSES.md rows).
func TestDifferentialGenerated(t *testing.T) {
	seeds := generatedSeeds
	for seed := 1; seed <= seeds; seed++ {
		files := genCorpus(rand.New(rand.NewSource(int64(seed))))
		dir := corpus(t, files)
		assertSame(t, fmt.Sprintf("seed %d", seed), dir)
		if t.Failed() {
			names := make([]string, 0, len(files))
			for n := range files {
				names = append(names, n)
			}
			sort.Strings(names)
			if keep := os.Getenv("VC_DUMP_DIR"); keep != "" {
				for n, body := range files {
					_ = os.MkdirAll(filepath.Join(keep, filepath.Dir(n)), 0o755)
					_ = os.WriteFile(filepath.Join(keep, n), []byte(body), 0o644)
				}
			}
			t.Logf("seed %d corpus files: %v (dir %s)", seed, names, dir)
			return
		}
	}
}

var (
	genVerbs = []string{"Corrects", "corrects", "CORRECTS", "corrige", "Corrige", "se corrige", "si no se corrige", "corrigió", "corrigieron",
		"corrects nothing in", "no corrige", "never corrects", "Corrects no claim in", "corrects nothing but", "corrigendum", "CORRIGENDUM", "Corrigendum to",
		"corrigendum of", "corrigendum al", "corrigendum for the", "corrigenda", "correctsx", "corrigeñ", "ñcorrige", "corrigiéndose", "corrigendum:", "incorrectly",
		"the correct value", "corrector", "corrects the claim in", "corrige la suposición", "corrects (the premise)"}
	genRefs = []string{"[Block 8]", "[Bloque 12]", "[ Block  3 ]", "[Block 0010]", "[Block 5] §2", "[Block 3]/[Block 4]", "[Block 5] y [Block 6]", "[Block 9]",
		"[Block 1]", "[Block 11]", "[Block 2] and [Block 14]", "[Block 6]/[Bloque 7]", "[Block 13]", "[Block 4]", "[Block 3] §6.3–6.4 and [Block 8]"}
	genBare = []string{"B9", "b12", "B50-G6", "B3 and B4", "B5 y B6", "B7x", "B2 and [Block 11]", "B10/B11", "B12 and B13 and [Block 6]"}
	genQual = []string{"`integration` ", "of the focus `fluke` ", "in `fluke.md` ", "`foo` focus ", "of `x` ", "in `pi5` ", "of the `fluke` focus ", "of the focus `ghost` ", "of the `ghost` focus ", "`niagara5` "}
	genGlue = []string{" ", " ", " the claim ", " this ", " the assumption behind ", " junto a ", " alongside ", " this run's ", " the caller’s ", " our backlog's ", " the decompiler's ",
		" nothing in ", " no claim in ", " no longer ", ", and ", ", but ", "; ", " · ", ". ", " cf. ", " e.g. ", " i.e. ", " p. ", " x. ", " (", ") ", "(", ")", " — ", " – ", "ñ ", " é ", " “quoted” ",
		" see ", ", ", ": ", " [CERT] ", " [tag] ", " [a very long tag that is far beyond the limit] ", " `code` ", " the "}
	genBreaks = []string{"\n", "\n", "\n> ", "\n> > ", "\n- ", "\n\n", "\n| ", "\n# ", "\n1. ", "\n   ", " ", " "}
	genNotes  = []string{"corrected in B%d", "Corregido en B%d", "refined in B%d", "—corrected in B%d", "uncorrected in B%d", "miscorrected in B%d",
		"CORRECCIÓN — [Block %d].", "**Correction (2026-01-01) — [Bloque %d] §4.1.**", "Correction: [Block %d] was wrong", "erratum B%d", "corrigendum [Block %d]", "corrected in B0%d",
		"Refinement planned, see B%d", "§14 refinement (B%d)", "Refinamiento (B%d)", "refinado en B%d", "corrected in B%d0", "corrected in Block %d", "corregido en bloque 0%d", "miscorrection [Block %d]."}
)

func pick(r *rand.Rand, xs []string) string { return xs[r.Intn(len(xs))] }

func genUnit(r *rand.Rand) string {
	var b strings.Builder
	for i, n := 0, 1+r.Intn(6); i < n; i++ {
		switch r.Intn(7) {
		case 0, 1:
			b.WriteString(pick(r, genVerbs))
		case 2, 3:
			b.WriteString(pick(r, genRefs))
		case 4:
			b.WriteString(pick(r, genBare))
		case 5:
			b.WriteString(pick(r, genQual))
		default:
			b.WriteString("word")
		}
		b.WriteString(pick(r, genGlue))
	}
	return b.String()
}

func genBlock(r *rand.Rand, num int, notes bool) string {
	var b strings.Builder
	fmt.Fprintf(&b, "# Block %d\n\n", num)
	for i, n := 0, 3+r.Intn(14); i < n; i++ {
		b.WriteString(genUnit(r))
		b.WriteString(pick(r, genBreaks))
	}
	if notes {
		for i, n := 0, r.Intn(5); i < n; i++ {
			b.WriteString(fmt.Sprintf(pick(r, genNotes), 1+r.Intn(14)) + pick(r, []string{"\n", "\n\n", " and more\n", ""}))
		}
	}
	return b.String()
}

func genCorpus(r *rand.Rand) map[string]string {
	files := map[string]string{}
	prefixes := []string{"t", "u", "fluke", "pi5-decoding", "niagara5"}
	nb := 4 + r.Intn(10)
	for i := 0; i < nb; i++ {
		p := prefixes[r.Intn(len(prefixes))]
		num := 1 + r.Intn(14)
		kw := pick(r, []string{"block", "block", "bloque"})
		pad := pick(r, []string{"", "", "0", "00"})
		sub := pick(r, []string{"", "", "sub/", "sub/deep/"})
		suffix := pick(r, []string{"", "", "-slug"})
		files[fmt.Sprintf("%s%s-%s%s%d%s.md", sub, p, kw, pad, num, suffix)] = genBlock(r, num, r.Intn(3) > 0)
	}
	if r.Intn(2) == 0 {
		var b strings.Builder
		b.WriteString("| slug | status | state | block | question |\n|---|---|---|---|---|\n")
		for _, s := range []string{"fluke", "integration", "foo", "x", "pi5"} {
			if r.Intn(2) == 0 {
				fmt.Fprintf(&b, "| `%s` | active | open | `%s-blockN.md` | q |\n", s, pick(r, prefixes))
			}
		}
		files["FOCUSES.md"] = b.String()
	}
	files["notes.md"] = "not a block\n"
	files["x-block1.template.md"] = "Corrects [Block 2]\n"
	return files
}
