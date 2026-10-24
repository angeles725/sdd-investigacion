//go:build !nodiff

package grammar

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"testing"
)

// Build tag nodiff drops the bash-driven tests (this file, fleet_test.go, gen_test.go) for mutation runs, where
// the package test repeats per mutant; `make check` always runs them.
//
// Differential tests: the REAL lib/retro-grammar.sh (testdata/diff-driver.sh) and the Go port must agree byte for
// byte on stdout, stderr and the return code for every input. Bash runs under LC_ALL=C, the locale the port
// implements (doc.go). The driver fails loudly: exit 97 is a broken harness and a t.Fatal, never a skip or a pass.
// Only a missing bash binary skips, with a message saying the port is NOT proven in that run.

const (
	toolbeltRel = "../../../../toolbelt"
	harnessRC   = 97
)

// driverSlots caps concurrent bash drivers: the parallel mode subtests share a loaded host.
var driverSlots = make(chan struct{}, 4)

type bashOut struct {
	stdout, stderr string
	rc             int
}

// bashBatch runs one driver mode over inputs (one per line on stdin) and returns one result per input.
func bashBatch(t *testing.T, mode string, inputs []string) []bashOut {
	t.Helper()
	driverSlots <- struct{}{}
	defer func() { <-driverSlots }() // released on t.Fatal/t.Skip too (both unwind through defers)
	so := runDriver(t, mode, strings.Join(inputs, "\n")+"\n")
	out := make([]bashOut, 0, len(inputs))
	for len(so) > 0 {
		var r bashOut
		var no, ne int
		nl := bytes.IndexByte(so, '\n')
		if nl < 0 {
			t.Fatalf("differential %s: truncated frame header %q", mode, so)
		}
		if _, err := fmt.Sscanf(string(so[:nl]), "%d %d %d", &r.rc, &no, &ne); err != nil {
			t.Fatalf("differential %s: bad frame header %q: %v", mode, so[:nl], err)
		}
		body := so[nl+1:]
		if len(body) < no+ne {
			t.Fatalf("differential %s: frame shorter than its header says", mode)
		}
		r.stdout, r.stderr = string(body[:no]), string(body[no:no+ne])
		out = append(out, r)
		so = body[no+ne:]
	}
	if len(out) != len(inputs) {
		t.Fatalf("differential %s: %d frames for %d inputs", mode, len(out), len(inputs))
	}
	return out
}

func runDriver(t *testing.T, mode, stdin string) []byte {
	t.Helper()
	bin, err := exec.LookPath("bash")
	if err != nil {
		t.Skip("differential: bash not found in PATH; the Go port is NOT proven against lib/retro-grammar.sh in this run")
	}
	tb, err := filepath.Abs(toolbeltRel)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(tb, "lib", "retro-grammar.sh")); err != nil {
		t.Fatalf("differential: toolbelt not found at %s (%v); a moved package must update toolbeltRel, not skip", tb, err)
	}
	script, _ := filepath.Abs(filepath.Join("testdata", "diff-driver.sh"))
	cmd := exec.Command(bin, script, tb, mode)
	cmd.Env = []string{"PATH=" + os.Getenv("PATH"), "LC_ALL=C"}
	cmd.Stdin = strings.NewReader(stdin)
	var so, se bytes.Buffer
	cmd.Stdout, cmd.Stderr = &so, &se
	if err := cmd.Run(); err != nil {
		var ee *exec.ExitError
		if !errors.As(err, &ee) {
			t.Fatalf("differential: cannot run the driver: %v", err)
		}
		t.Fatalf("differential: driver %s exited %d (harness failure): %s", mode, ee.ExitCode(), se.String())
	}
	if se.Len() != 0 {
		t.Fatalf("differential: driver %s wrote outside its frames: %s", mode, se.String())
	}
	return so.Bytes()
}

// rcOf is the shell return code of a Go predicate.
func rcOf(ok bool) int {
	if ok {
		return 0
	}
	return 1
}

// joinLines renders records the way awk prints them: each one "\n"-terminated.
func joinLines(xs []string) string {
	var b strings.Builder
	for _, x := range xs {
		b.WriteString(x)
		b.WriteByte('\n')
	}
	return b.String()
}

// fileModes maps a driver file mode to the Go rendering of the same call. Every mode reads through Read, so an
// absent or unreadable path takes the typed-error branch the mode documents.
var fileModes = map[string]func(path string) bashOut{
	"defenced": func(p string) bashOut {
		d, err := Read(p)
		if err != nil {
			return bashOut{rc: 1}
		}
		return bashOut{stdout: joinLines(d.Lines), stderr: d.FenceWarning()}
	},
	// delta_info: bash prints a zero line for an absent file (rc 0, the silent zero Go reports as ErrAbsentInput)
	// and a typed stderr line plus the zero line, rc 1, for an unreadable one.
	"delta": func(p string) bashOut {
		d, err := Read(p)
		switch {
		case errors.Is(err, ErrAbsentInput):
			return bashOut{stdout: DeltaInfo{Form: FormNone}.Line()}
		case err != nil:
			return bashOut{stdout: DeltaInfo{Form: FormNone}.Line(), rc: 1,
				stderr: "retro-grammar: cannot read " + p + " (unreadable) — delta count is UNKNOWN, not zero\n"}
		}
		return bashOut{stdout: Delta(d).Line(), stderr: d.FenceWarning()}
	},
	"canon": func(p string) bashOut {
		d, err := Read(p)
		if err != nil {
			return bashOut{rc: 1}
		}
		h, ok := CanonicalHeading(d)
		if !ok {
			return bashOut{}
		}
		return bashOut{stdout: h + "\n"}
	},
	"unrec":     readThen(func(d *Doc) []string { return UnrecHeadings(d) }),
	"entryrows": readThen(func(d *Doc) []string { return rowLines(EntryRows(d)) }),
	// entry_ids prints nothing for no entries; its read failure is entry_rows' rc 1.
	"entryids": readThen(EntryIDs),
	// entry_warn always returns 0; on an unreadable file only its delta_info call speaks.
	"entrywarn": func(p string) bashOut {
		d, err := Read(p)
		switch {
		case errors.Is(err, ErrUnreadable):
			return bashOut{stderr: "retro-grammar: cannot read " + p + " (unreadable) — delta count is UNKNOWN, not zero\n"}
		case err != nil:
			return bashOut{}
		}
		return bashOut{stdout: EntryWarn(d)}
	},
}

// awkCannotOpen stands for gawk's own fatal line (it names the awk program line, so it is not pinned byte for
// byte): retro_grammar_has_honesty does not guard readability, so an unreadable file is an untyped rc 2.
const awkCannotOpen = "<awk: fatal: cannot open file>"

// normalize applies the one declared normalizer to a bash result before comparison.
func normalize(b bashOut) bashOut {
	if b.rc == 2 && strings.Contains(b.stderr, "fatal: cannot open file") && strings.Count(b.stderr, "\n") == 1 {
		b.stderr = awkCannotOpen
	}
	return b
}

func init() {
	fileModes["honesty"] = func(p string) bashOut {
		d, err := Read(p)
		switch {
		case errors.Is(err, ErrUnreadable):
			return bashOut{rc: 2, stderr: awkCannotOpen}
		case err != nil:
			return bashOut{rc: 1}
		}
		return bashOut{rc: rcOf(HasHonesty(d))}
	}
	fileModes["rowtitles"] = func(p string) bashOut {
		d, err := Read(p)
		if err != nil {
			return bashOut{rc: 1}
		}
		var b strings.Builder
		for _, r := range RowTitles(d) {
			b.WriteString(r.Line())
		}
		return bashOut{stdout: b.String()}
	}
	fileModes["altrows"] = readThen(func(d *Doc) []string { return rowLines(AltEntryRows(d)) })
	fileModes["altheads"] = readThen(AltHeads)
}

// tokenModes maps a driver token mode to the Go verdict, rendered the way the driver frames it.
var tokenModes = map[string]func(tok string) bashOut{
	"deltaid": func(tok string) bashOut { return bashOut{stdout: strconv.Itoa(b2i(DeltaID(tok))) + "\n"} },
	"idskip":  func(tok string) bashOut { return bashOut{stdout: strconv.Itoa(b2i(TableIDSkip(tok))) + "\n"} },
	"idsafe":  func(tok string) bashOut { return bashOut{rc: rcOf(IDSignatureSafe(tok))} },
}

// tokenCorpus is a hand list of id edges plus every blank- or pipe-separated word of the generated vocabulary
// and of the kit fixtures (no line breaks: one token per driver input line).
func tokenCorpus(t *testing.T) []string {
	t.Helper()
	set := map[string]bool{}
	for _, tok := range []string{"", "A", "R1", "SPKI-A", "ITEM-ID", "ABCDEFGH1", "ABCDEFG1", "A-", "A-B-C", "#", "#3",
		"---", ":-:", "D1.", "d1", "x\xff", "\\", "D|1", "é", "a_b-C9", " D1", "D 1", "Total", "1"} {
		set[tok] = true
	}
	words := func(line string) {
		for _, w := range strings.FieldsFunc(line, func(r rune) bool { return r == ' ' || r == '|' || r == '\t' }) {
			set[w] = true
		}
	}
	for _, l := range genVocab {
		words(l)
	}
	for _, p := range fixturePaths(t) {
		d, err := Read(p)
		if err != nil {
			t.Fatal(err)
		}
		for _, l := range d.Raw {
			words(l)
		}
	}
	out := make([]string, 0, len(set))
	for tok := range set {
		if !strings.ContainsAny(tok, "\n\r") {
			out = append(out, tok)
		}
	}
	sort.Strings(out)
	return out
}

func TestDifferentialTokens(t *testing.T) {
	toks := tokenCorpus(t)
	for mode, f := range tokenModes {
		t.Run(mode, func(t *testing.T) {
			t.Parallel()
			bash := bashBatch(t, mode, toks)
			yes, bad := 0, 0
			for i, tok := range toks {
				if bash[i].rc == 0 && bash[i].stdout != "0\n" {
					yes++
				}
				if got := f(tok); got != bash[i] {
					if bad++; bad <= 5 {
						t.Errorf("%s %q: go=%+v bash=%+v", mode, tok, got, bash[i])
					}
				}
			}
			if yes == 0 || yes == len(toks) {
				t.Errorf("%s: bash said the same for all %d tokens: vacuous", mode, len(toks))
			}
			t.Logf("%s: %d tokens, %d accepted", mode, len(toks), yes)
		})
	}
}

// TestDifferentialTitleIdentity runs retro_grammar_title_has_identity over every table cell of the fixtures and
// the vocabulary plus UTF-8 edges (11/12-character boundaries, surrogates, overlongs, beyond U+10FFFF).
func TestDifferentialTitleIdentity(t *testing.T) {
	set := map[string]bool{}
	for _, tok := range tokenCorpus(t) {
		set[tok] = true
	}
	for _, e := range []string{"ééééééééééé", "éééééééééééé", "abcdefghi\x80\x80\x80", "\xed\xa0\x80abcdefghij",
		"\xc0\xafabcdefghijk", "\xf4\x90\x80\x80abcdefghi", "\xf0\x9f\x98\x80abcdefghijk", "abcdefghij\xc3",
		"\xf8\x88\x80\x80\x80abcdefghi", "\xfd\xbf\xbf\xbf\xbf\xbfabcdefghij", "\xf8\x87\xbf\xbf\xbfabcdefg",
		"\xef\xbf\xbeabcdefghij", "\xfeabcdefghij", "DOC-FIX", "Regression", "low ", "fix it now please"} {
		set[e] = true
	}
	cells := func(lines []string) {
		for _, l := range lines {
			for _, c := range splitCells(l) {
				set[strings.TrimSpace(c)] = true
			}
		}
	}
	cells(genVocab)
	for _, p := range fixturePaths(t) {
		d, err := Read(p)
		if err != nil {
			t.Fatal(err)
		}
		cells(d.Raw)
	}
	var all []string
	for tok := range set {
		if !strings.ContainsAny(tok, "\n\r") {
			all = append(all, tok)
		}
	}
	sort.Strings(all)
	// Bash forks iconv, tr and wc per title: keep every informative title (near the 12-character floor, non-ASCII,
	// a bare token) and a fixed 1-in-20 sample of the rest.
	var titles []string
	for i, tok := range all {
		if (len(tok) >= 9 && len(tok) <= 15) || strings.ContainsFunc(tok, func(r rune) bool { return r >= 0x80 }) ||
			bareTokens[lower(tok)] || i%20 == 0 {
			titles = append(titles, tok)
		}
	}
	bash := bashBatch(t, "titleid", titles)
	yes := 0
	for i, title := range titles {
		got := bashOut{rc: rcOf(TitleHasIdentity(title))}
		if bash[i].rc == 0 {
			yes++
		}
		if got != bash[i] {
			t.Errorf("titleid %q: go=%+v bash=%+v", title, got, bash[i])
		}
	}
	if yes == 0 || yes == len(titles) {
		t.Errorf("titleid: one verdict for all %d titles: vacuous", len(titles))
	}
	t.Logf("titleid: %d titles, %d with identity", len(titles), yes)
}

// TestDifferentialDupIDs feeds whole id lists on stdin, the way the consumers pipe item ids.
func TestDifferentialDupIDs(t *testing.T) {
	for _, ids := range [][]string{
		{"1", "2", "1"}, {"b", "B", "a", "b", "B", "B"}, {"", "x", ""}, {"10", "9", "10", "9"}, {"é", "e", "é"}, {"z"},
	} {
		so := runDriver(t, "dupids", strings.Join(ids, "\n")+"\n")
		want := fmt.Sprintf("0 %d 0\n%s", len(joinLines(DupIDs(ids))), joinLines(DupIDs(ids)))
		if string(so) != want {
			t.Errorf("DupIDs(%q): bash frame %q, go %q", ids, so, want)
		}
	}
}

// rowLines renders rows as their bash records, without the trailing newline joinLines adds back.
func rowLines(rows []Row) []string {
	out := make([]string, len(rows))
	for i, r := range rows {
		out[i] = strings.TrimSuffix(r.Line(), "\n")
	}
	return out
}

// readThen renders a mode that prints one line per result and returns 1, silently, on a failed read.
func readThen(f func(*Doc) []string) func(string) bashOut {
	return func(p string) bashOut {
		d, err := Read(p)
		if err != nil {
			return bashOut{rc: 1}
		}
		return bashOut{stdout: joinLines(f(d))}
	}
}

// checkFileModes runs every file mode over paths on both sides and reports each disagreement.
// With requireSignal, a mode on which bash gives one outcome for every input fails: that corpus would prove nothing.
func checkFileModes(t *testing.T, label string, paths []string, requireSignal bool) {
	t.Helper()
	modes := make([]string, 0, len(fileModes))
	for m := range fileModes {
		modes = append(modes, m)
	}
	sort.Strings(modes)
	for _, mode := range modes {
		t.Run(mode, func(t *testing.T) {
			t.Parallel()
			bash := bashBatch(t, mode, paths)
			for i := range bash {
				bash[i] = normalize(bash[i])
			}
			distinct := map[bashOut]bool{}
			bad := 0
			for i, p := range paths {
				distinct[bash[i]] = true
				if got := fileModes[mode](p); got != bash[i] {
					if bad++; bad <= 5 {
						t.Errorf("%s %s %s:\n  go=%+v\nbash=%+v", label, mode, p, got, bash[i])
					}
				}
			}
			if bad > 5 {
				t.Errorf("%s %s: %d more disagreements not shown", label, mode, bad-5)
			}
			if requireSignal && len(distinct) < 2 {
				t.Errorf("%s %s: bash gave one outcome for all %d inputs: the corpus is vacuous for this mode", label, mode, len(paths))
			}
			t.Logf("%s %s: %d inputs, %d distinct bash outcomes", label, mode, len(paths), len(distinct))
		})
	}
}

// fixturePaths lists every markdown fixture of the kit's test suites (the frozen retro corpora live there).
func fixturePaths(t *testing.T) []string {
	t.Helper()
	root, err := filepath.Abs(filepath.Join(toolbeltRel, "tests", "fixtures"))
	if err != nil {
		t.Fatal(err)
	}
	var out []string
	err = filepath.WalkDir(root, func(p string, d os.DirEntry, err error) error {
		if err == nil && !d.IsDir() && strings.HasSuffix(p, ".md") {
			out = append(out, p)
		}
		return err
	})
	if err != nil || len(out) == 0 {
		t.Fatalf("fixtures under %s: %d files, %v", root, len(out), err)
	}
	return out
}

func TestDifferentialFixtures(t *testing.T) {
	paths := fixturePaths(t)
	checkFileModes(t, "fixture", paths, false)
	t.Logf("fixtures: %d files x %d modes", len(paths), len(fileModes))
}

func TestDifferentialGenerated(t *testing.T) {
	dir := t.TempDir()
	docs := generatedDocs(200)
	paths := make([]string, len(docs))
	for i, src := range docs {
		paths[i] = filepath.Join(dir, "g"+strconv.Itoa(i)+".md")
		if err := os.WriteFile(paths[i], []byte(src), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	checkFileModes(t, "generated", paths, true)
}

func TestDifferentialAbsentAndEmpty(t *testing.T) {
	dir := t.TempDir()
	empty := filepath.Join(dir, "empty.md")
	if err := os.WriteFile(empty, nil, 0o644); err != nil {
		t.Fatal(err)
	}
	paths := []string{"", filepath.Join(dir, "missing.md"), dir, empty}
	if os.Geteuid() != 0 { // root reads a mode-000 file: the unreadable premise is then unavailable
		locked := filepath.Join(dir, "locked.md")
		if err := os.WriteFile(locked, []byte("## Proposed kit deltas\n"), 0); err != nil {
			t.Fatal(err)
		}
		paths = append(paths, locked)
	}
	checkFileModes(t, "edge", paths, true)
}
