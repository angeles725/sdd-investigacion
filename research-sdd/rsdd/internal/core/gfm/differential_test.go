package gfm

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// Differential test: the REAL bash readers (testdata/diff-driver.sh) and the Go reader must produce equal
// output on the same inputs. The Go side derives each reader's observable output from gfm cells only, so a
// divergence in cell splitting, trimming or escape handling shows up as a different string.
//
// Covered readers (see READERS.md for the rest): lib/gap-rows.sh gap_rows_parse (cell text, directly),
// research-sdd-status.sh count_open_contra, _read_focuses_tok_uncached, and the --sync-state derivations
// deferred_open (DEF-AWK) and covered_blocks (Iteration-history Block column).

const toolbeltRel = "../../../../toolbelt"

func driver(t *testing.T) (tb, script string) {
	t.Helper()
	if _, err := exec.LookPath("bash"); err != nil {
		t.Skip("differential: bash not found in PATH; the Go reader is NOT proven against the kit's bash readers in this run")
	}
	tb, err := filepath.Abs(toolbeltRel)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(tb, "lib", "gap-rows.sh")); err != nil {
		t.Fatalf("differential: toolbelt not found at %s (%v); a moved package must update toolbeltRel, not skip", tb, err)
	}
	script, _ = filepath.Abs(filepath.Join("testdata", "diff-driver.sh"))
	return tb, script
}

func runBash(t *testing.T, mode, file string, keys ...string) string {
	t.Helper()
	tb, script := driver(t)
	args := append([]string{script, tb, mode, file}, keys...)
	cmd := exec.Command("bash", args...)
	var stderr strings.Builder
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		t.Fatalf("bash driver %s %s failed: %v\n%s", mode, file, err, stderr.String())
	}
	return strings.TrimRight(string(out), "\n")
}

// variants writes the input as-is and without its trailing newline into a temp dir.
func variants(t *testing.T, path string) map[string]string {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	out := map[string]string{}
	for name, content := range map[string]string{
		"as-is":          string(b),
		"no-trailing-nl": strings.TrimRight(string(b), "\n"),
	} {
		p := filepath.Join(dir, name+".md")
		if err := os.WriteFile(p, []byte(content), 0o600); err != nil {
			t.Fatal(err)
		}
		out[p] = content
	}
	return out
}

func asciiLower(s string) string {
	b := []byte(s)
	for i, c := range b {
		if c >= 'A' && c <= 'Z' {
			b[i] = c + 32
		}
	}
	return string(b)
}

var (
	reGapID   = regexp.MustCompile(`^B[0-9]+-G[0-9]+([ \t]|$)`)
	reClosed  = regexp.MustCompile(`^(—|~~|[0-9]+$)`)
	reTier    = regexp.MustCompile(`^(high|medium|low|deferred)$`)
	reGapHead = regexp.MustCompile(`^B[0-9]+-G[0-9]+[ \t]*`)
)

// gapRowsGo mirrors the record logic of gap_rows_parse on top of gfm cells.
func gapRowsGo(src string) string {
	var out []string
	for r := range Rows(src, Options{}) {
		a := append([]string{""}, r.Text()...) // 1-based, like awk
		n := len(a) - 1
		get := func(i int) string {
			if i >= 1 && i <= n {
				return a[i]
			}
			return ""
		}
		if !reGapID.MatchString(get(2)) {
			continue
		}
		pr := get(1)
		closed := reClosed.MatchString(pr)
		pending := strings.HasPrefix(asciiLower(get(n)), "pending")
		if closed && !pending {
			out = append(out, "SKIPPED\t"+get(2))
			continue
		}
		if n < 4 || (!closed && !reTier.MatchString(pr)) {
			s := r.Source
			if len(s) > 90 {
				s = s[:90]
			}
			out = append(out, "UNPARSED\t"+s)
			continue
		}
		gid := get(2)
		if i := strings.IndexAny(gid, " \t"); i >= 0 {
			gid = gid[:i]
		}
		txt := strings.ReplaceAll(reGapHead.ReplaceAllString(get(2), ""), "\t", " ")
		st := "other"
		if pending {
			st = "pending"
		}
		bn := strings.TrimPrefix(gid, "B")
		bn = bn[:strings.Index(bn, "-G")]
		out = append(out, fmt.Sprintf("ROW\t%s\t%s\t%s\t%s", gid, bn, st, txt))
	}
	return strings.TrimRight(strings.Join(out, "\n"), "\n")
}

// contraGo mirrors count_open_contra: STATUS is the 4th cell, exactly "open" (any case). Any line with a pipe is a row.
func contraGo(src string) string {
	c := 0
	for r := range Rows(src, Options{Shape: ShapeAnyPipe, KeepCR: true}) {
		if cells := r.Text(); len(cells) >= 4 && asciiLower(cells[3]) == "open" {
			c++
		}
	}
	return fmt.Sprint(c)
}

var (
	reLink  = regexp.MustCompile(`^\[[^\]]*\]\([^)]*\)$`)
	reTick  = regexp.MustCompile("^`[^`]*`$")
	reSpace = regexp.MustCompile(`[ \t\n\r\f\v].*$`)
)

func stripMarkup(s string) string {
	if reLink.MatchString(s) {
		s = strings.TrimPrefix(s, "[")
		s = s[:strings.LastIndex(s, "](")]
	}
	if reTick.MatchString(s) {
		s = s[1 : len(s)-1]
	}
	s = strings.TrimPrefix(s, "**")
	return strings.Replace(s, "**", "", 1)
}

// focTokGo mirrors _read_focuses_tok_uncached for one key.
func focTokGo(src, key string) string {
	slug := strings.TrimSuffix(strings.TrimPrefix(key, "RESEARCH-STATE-"), ".md")
	var fcol, scol, sfcol int
	hdone := false
	for r := range Rows(src, Options{Shape: ShapeAnyPipe, KeepCR: true}) {
		a := r.Text()
		n := len(a)
		if n == 0 || IsSeparator(a) { // awk's issep is vacuously true for zero cells
			continue
		}
		col := func(i int) string { return a[i-1] }
		if !hdone {
			hdone = true
			for k := 1; k <= n; k++ {
				switch asciiLower(col(k)) {
				case "focus":
					fcol = k
				case "status", "estado":
					scol = k
				case "research-state", "state file":
					sfcol = k
				}
			}
			if scol == 0 && fcol > 0 {
				scol = fcol + 1
			}
			continue
		}
		matched := false
		if fcol > 0 && fcol <= n {
			if cv := stripMarkup(col(fcol)); cv == key || cv == slug {
				matched = true
			}
		}
		if !matched && sfcol > 0 && sfcol <= n {
			if cv := stripMarkup(col(sfcol)); cv == key || cv == slug {
				matched = true
			}
		}
		if !matched {
			continue
		}
		if scol == 0 || scol > n {
			return ""
		}
		tok := asciiLower(reSpace.ReplaceAllString(stripMarkup(col(scol)), ""))
		switch tok {
		case "active", "paused", "stopped", "planned", "bootstrapping", "reopened", "document":
			return tok
		}
		return ""
	}
	return ""
}

var (
	reBacklogHead = regexp.MustCompile(`^## Gap-backlog( \([^)]+\))?$`)
	rePriorityHdr = regexp.MustCompile(`^(priority|pr\.?|p|prioridad)$`)
	reDashes      = regexp.MustCompile(`^-+$`)
	reBlockID     = regexp.MustCompile(`\bB[0-9]+\b`)
)

// stateGo mirrors the deferred_open (DEF-AWK) and covered_blocks (Iteration-history Block column) derivations.
func stateGo(src string) string {
	var ib, tok bool
	ex, deferred := 0, 0
	prv := ""
	inIter, blockcol := false, -1
	blocks := map[string]bool{}
	for _, line := range strings.Split(src, "\n") {
		if strings.HasPrefix(line, "## ") {
			ib, ex, tok, prv = reBacklogHead.MatchString(line), 0, false, ""
			inIter, blockcol = strings.HasPrefix(line, "## Iteration history"), -1
			continue
		}
		cells, ok := SplitRow(line, Options{Shape: ShapeAnyPipe, KeepCR: true})
		if !ok {
			prv = ""
			continue
		}
		r := Row{Padded: cells}
		a := r.Text()
		if inIter {
			if blockcol < 0 {
				for i, v := range a {
					if asciiLower(v) == "block" {
						blockcol = i
						break
					}
				}
			} else if blockcol < len(a) {
				for _, m := range reBlockID.FindAllString(a[blockcol], -1) {
					blocks[m] = true
				}
			}
		}
		get := func(i int) string {
			if i <= len(a) {
				return a[i-1]
			}
			return ""
		}
		p := asciiLower(get(1))
		pv := strings.ReplaceAll(prv, "**", "")
		prv = p
		if reDashes.MatchString(p) {
			ex, tok = len(a), rePriorityHdr.MatchString(pv)
			continue
		}
		if p != "deferred" || (!ib && !tok) {
			continue
		}
		sc := 4
		if ex > 0 {
			sc = ex
		}
		if (sc != 4 && sc != 5) || len(a) != sc {
			continue
		}
		st := asciiLower(get(len(a)))
		if strings.Contains(get(2), "~~") || (sc == 5 && strings.Contains(get(3), "~~")) || strings.Contains(st, "~~") || strings.Contains(st, "✅") {
			continue
		}
		deferred++
	}
	return fmt.Sprintf("covered_blocks=%d\ndeferred_open=%d", len(blocks), deferred)
}

func TestDifferentialGapRows(t *testing.T) {
	for _, f := range []string{
		"testdata/fixtures/state/RESEARCH-STATE.md", "testdata/fixtures/outline/RESEARCH-STATE.md",
		"testdata/fixtures/nogaps/RESEARCH-STATE.md", "testdata/edge/gaprows.md",
	} {
		for p, content := range variants(t, f) {
			want := runBash(t, "gaprows", p)
			if got := gapRowsGo(content); got != want {
				t.Errorf("%s (%s): Go differs from gap_rows_parse\n--- bash\n%s\n--- go\n%s", f, filepath.Base(p), want, got)
			}
		}
	}
}

func TestDifferentialGapRowsHasCoverage(t *testing.T) {
	// A differential over an input that yields nothing proves nothing (anti-silent-zero): require records of each kind.
	got := gapRowsGo(mustRead(t, "testdata/edge/gaprows.md"))
	for _, kind := range []string{"ROW\t", "SKIPPED\t", "UNPARSED\t"} {
		if !strings.Contains(got, kind) {
			t.Errorf("edge/gaprows.md yields no %q record; the edge input lost its teeth", kind)
		}
	}
	if n := strings.Count(gapRowsGo(mustRead(t, "testdata/fixtures/state/RESEARCH-STATE.md")), "ROW\t"); n != 16 {
		t.Errorf("state fixture yields %d ROW records, want 16", n)
	}
}

func mustRead(t *testing.T, p string) string {
	t.Helper()
	b, err := os.ReadFile(p)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func TestDifferentialContra(t *testing.T) {
	for _, f := range []string{"testdata/fixtures/contra/CONTRADICTIONS.md", "testdata/edge/contra.md"} {
		for p, content := range variants(t, f) {
			want, got := runBash(t, "contra", p), contraGo(content)
			if got != want {
				t.Errorf("%s (%s): count_open_contra bash=%s go=%s", f, filepath.Base(p), want, got)
			}
			if want == "0" {
				t.Errorf("%s: bash counted 0 open rows; the input has no teeth", f)
			}
		}
	}
}

func TestDifferentialFocusTok(t *testing.T) {
	cases := map[string][]string{
		"testdata/fixtures/focuses/FOCUSES.md": {"f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8", "f9", "RESEARCH-STATE-f6.md", "nope"},
		"testdata/edge/focuses.md":             {"e1", "e2", "e3", "e4", "e5", "e6", "e7", "RESEARCH-STATE-e3.md", "x|y"},
	}
	for f, keys := range cases {
		for p, content := range variants(t, f) {
			var want []string
			for _, k := range keys {
				want = append(want, k+"="+focTokGo(content, k))
			}
			if got, bash := strings.Join(want, "\n"), runBash(t, "foctok", p, keys...); got != bash {
				t.Errorf("%s (%s): _read_focuses_tok_uncached\n--- bash\n%s\n--- go\n%s", f, filepath.Base(p), bash, got)
			}
		}
	}
}

func TestDifferentialStateDerivations(t *testing.T) {
	f := "testdata/fixtures/state/RESEARCH-STATE.md"
	want, got := runBash(t, "state", f), stateGo(mustRead(t, f))
	if got != want {
		t.Errorf("--sync-state derivations\n--- bash\n%s\n--- go\n%s", want, got)
	}
	if !strings.Contains(want, "deferred_open=7") || !strings.Contains(want, "covered_blocks=9") {
		t.Errorf("bash derived %q, want deferred_open=7 and covered_blocks=9 (GFM expectation)", want)
	}
}
