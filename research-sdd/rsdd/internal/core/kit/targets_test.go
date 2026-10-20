package kit

import (
	"crypto/sha256"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/gfm"
)

// targetCorpus is shared by the unit tests and the differential test. Each source is a TARGETS.md body.
// Cases 1-9 are the fixtures of toolbelt/tests/target-paths.test.sh.
var targetCorpus = map[string]string{
	"basic": "# Targets\n\nProse citation only: (`/prose/should/not/appear`).\n\n| # | name | path |\n|---|------|------|\n" +
		"| 1 | real      | `/table/real/path` |\n| 2 | truncated | `/home/x/.../trunc-target` |\n",
	"rh-prose": "# Targets\nProse mentioning `$RESEARCH_HOME/prose-rh` for context only.\n\n| # | name | path |\n|---|------|------|\n" +
		"| 1 | rh | `$RESEARCH_HOME/rh-target` |\n",
	"rh-braced":   tableRows("| 1 | a | `${RESEARCH_HOME}/braced` |", "| 2 | b | `$RESEARCH_HOME/plain` |"),
	"no-trail-nl": strings.TrimSuffix(tableRows("| 1 | a | `/first` |", "| 2 | b | `/last-no-newline` |"), "\n"),
	"crlf":        strings.ReplaceAll(tableRows("| 1 | a | `/crlf-one` |", "| 2 | b | `/crlf-two` |"), "\n", "\r\n"),
	"indented":    "  | 1 | a | `/spaces` |\n\t| 2 | b | `/tab` |\n",
	"multi-token": "| 1 | a | `/one` `/two` and `$RESEARCH_HOME/three` | `/four` |\n",
	"dups":        tableRows("| 1 | a | `/dup` |", "| 2 | b | `/dup` |", "| 3 | c | `$RESEARCH_HOME/dup` |"),
	"sorting":     tableRows("| 1 | a | `/b` |", "| 2 | b | `/B` |", "| 3 | c | `/a/b` |", "| 4 | d | `/a-b` |", "| 5 | e | `/a` |", "| 6 | f | `/é` |"),
	"non-path":    tableRows("| 1 | a | `/mrdoob/three.js` |", "| 2 | b | `relative/path` |", "| 3 | c | `` |", "| 4 | d | `/` |"),
	"glued":       "| 1 | a | `x`/y` |\n",
	"spaces-in":   "| 1 | a | `/with space/dir` |\n",
	"not-rows":    "see | `/pipe-not-leading` |\n> | `/quoted` |\n`/bare`\n- | `/list` |\n",
	"vtab-row":    "\v| 1 | a | `/after-vtab` |\n\f| 2 | b | `/after-ff` |\n\r| 3 | c | `/after-cr` |\n",
	"header-only": "# t\n\n| # | Target | Path |\n|---|---|---|\n",
	"prose-only":  "# t\n\nsome `/prose` only, no table\n",
	"empty":       "",
}

func rhEnv(rh string) Getenv { return envOf(map[string]string{"RESEARCH_HOME": rh, "HOME": "/home/u"}) }

func TestTableRowsOnlyProseNeverBecomesATarget(t *testing.T) { // CLAUDE.md section 11 (a), cases 1a/1b/3
	got := PathsAll(targetCorpus["basic"], rhEnv(""))
	want := []string{"/home/x/.../trunc-target", "/table/real/path"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("basic: got %q want %q", got, want)
	}
	got = PathsAll(targetCorpus["rh-prose"], rhEnv("/home/rh"))
	if want := []string{"/home/rh/rh-target"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("rh-prose: got %q want %q (prose $RESEARCH_HOME must not appear)", got, want)
	}
	if got := PathsAll(targetCorpus["not-rows"], rhEnv("")); len(got) != 0 {
		t.Fatalf("non-row lines leaked: %q", got)
	}
}

func TestTruncatedPathInsideARowPassesThroughAndWarns(t *testing.T) { // section 11 (b), case 2
	paths := PathsAll(targetCorpus["basic"], rhEnv(""))
	if !contains(paths, "/home/x/.../trunc-target") {
		t.Fatalf("truncated in-row path vanished: %q", paths)
	}
	usable, warns := Classify(paths, func(p string) bool { return p == "/table/real/path" })
	if !reflect.DeepEqual(usable, []string{"/table/real/path"}) {
		t.Fatalf("usable = %q", usable)
	}
	want := []Warning{{Kind: WarnTruncated, Path: "/home/x/.../trunc-target"}}
	if !reflect.DeepEqual(warns, want) {
		t.Fatalf("warns = %+v want %+v", warns, want)
	}
}

func TestNonPathTokensPassThroughAndAreUnresolvable(t *testing.T) { // section 11: callers filter them
	paths := PathsAll(targetCorpus["non-path"], rhEnv(""))
	if !reflect.DeepEqual(paths, []string{"/mrdoob/three.js"}) {
		t.Fatalf("paths = %q (relative, empty and bare-slash tokens are not Form 1 paths)", paths)
	}
	usable, warns := Classify(paths, func(string) bool { return false })
	if len(usable) != 0 || len(warns) != 1 || warns[0].Kind != WarnUnresolvable || warns[0].Path != "/mrdoob/three.js" {
		t.Fatalf("usable=%q warns=%+v", usable, warns)
	}
}

func TestResearchHomeForms(t *testing.T) { // case 3, 8, 9, section 11
	src := targetCorpus["rh-braced"]
	if got, want := PathsAll(src, rhEnv("/home/rh")), []string{"/home/rh/braced", "/home/rh/plain"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("both spellings: got %q want %q", got, want)
	}
	if got := PathsAll(src, rhEnv("/rh-slash/")); !reflect.DeepEqual(got, []string{"/rh-slash/braced", "/rh-slash/plain"}) {
		t.Fatalf("trailing slash must not double: %q", got)
	}
	if got := PathsAll(src, rhEnv("/rh&amp/path")); !reflect.DeepEqual(got, []string{"/rh&amp/path/braced", "/rh&amp/path/plain"}) {
		t.Fatalf("'&' must stay literal: %q", got)
	}
	// ${RESEARCH_HOME:-$HOME}: unset or empty falls back to HOME; only ONE trailing slash is stripped (${rh%/}).
	if got := PathsAll(src, envOf(map[string]string{"HOME": "/home/u"})); got[0] != "/home/u/braced" {
		t.Fatalf("HOME fallback: %q", got)
	}
	if got := PathsAll(src, rhEnv("/two//")); got[0] != "/two//braced" {
		t.Fatalf("exactly one trailing slash is stripped: %q", got)
	}
	if got := PathsAll(src, envOf(nil)); got[0] != "/braced" {
		t.Fatalf("both unset expands to an empty root: %q", got)
	}
}

func TestPairsKeepRawAndExpanded(t *testing.T) { // case 5
	got := PairsAll(targetCorpus["multi-token"], rhEnv("/rh"))
	want := []Pair{{"$RESEARCH_HOME/three", "/rh/three"}, {"/four", "/four"}, {"/one", "/one"}, {"/two", "/two"}}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %+v want %+v", got, want)
	}
	if got[0].Line() != "$RESEARCH_HOME/three\t/rh/three" {
		t.Fatalf("Line() = %q", got[0].Line())
	}
}

// list edges (section 7): the interesting token in the FIRST, MIDDLE and LAST row, a single row, and the same
// input with and without a trailing newline. A tr/read loop once dropped the last token.
func TestListEdgesFirstMiddleLastSingleAndTrailingNewline(t *testing.T) {
	cases := []struct {
		name string
		src  string
		want []string
	}{
		{"first", tableRows("| 1 | a | `/edge` |", "| 2 | b | `/m` |", "| 3 | c | `/z` |"), []string{"/edge", "/m", "/z"}},
		{"middle", tableRows("| 1 | a | `/a` |", "| 2 | b | `/edge` |", "| 3 | c | `/z` |"), []string{"/a", "/edge", "/z"}},
		{"last", tableRows("| 1 | a | `/a` |", "| 2 | b | `/m` |", "| 3 | c | `/edge` |"), []string{"/a", "/edge", "/m"}},
		{"single", tableRows("| 1 | a | `/only` |"), []string{"/only"}},
		{"single-row-two-tokens", "| `/x` | `/y` |", []string{"/x", "/y"}},
	}
	for _, c := range cases {
		for _, nl := range []string{"", "\n"} {
			src := strings.TrimSuffix(c.src, "\n") + nl
			if got := PathsAll(src, rhEnv("")); !reflect.DeepEqual(got, c.want) {
				t.Errorf("%s nl=%q: got %q want %q", c.name, nl, got, c.want)
			}
		}
	}
	// the very last token of a file with no trailing newline (the historical dropped-last-token bug)
	if got := PathsAll(targetCorpus["no-trail-nl"], rhEnv("")); !contains(got, "/last-no-newline") {
		t.Fatalf("last token dropped: %q", got)
	}
	if got := PathsAll(targetCorpus["crlf"], rhEnv("")); !reflect.DeepEqual(got, []string{"/crlf-one", "/crlf-two"}) {
		t.Fatalf("CRLF: %q", got)
	}
}

func TestIndentedRowsAreRows(t *testing.T) { // the row test is ^\s*\|, not ^\|
	if got := PathsAll(targetCorpus["indented"], rhEnv("")); !reflect.DeepEqual(got, []string{"/spaces", "/tab"}) {
		t.Fatalf("got %q", got)
	}
}

func TestSortIsBytewiseAndUnique(t *testing.T) {
	got := PathsAll(targetCorpus["sorting"], rhEnv(""))
	want := []string{"/B", "/a", "/a-b", "/a/b", "/b", "/é"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("C-locale order: got %q want %q", got, want)
	}
	if got := PathsAll(targetCorpus["dups"], envOf(nil)); !reflect.DeepEqual(got, []string{"/dup"}) {
		t.Fatalf("dups: %q", got)
	}
}

func TestReadingStatesAreDistinct(t *testing.T) { // section 7: empty, no-rows, no-tokens, tokens
	for name, want := range map[string]Reading{
		"empty": ReadEmptyInput, "prose-only": ReadNoRows, "header-only": ReadNoTokens, "basic": ReadTokens,
	} {
		if _, got := Derive(targetCorpus[name], rhEnv("")); got != want {
			t.Errorf("%s: reading %v want %v", name, got, want)
		}
	}
}

func TestReadTargetsTypedErrors(t *testing.T) { // cases 4, 6, 7
	dir := t.TempDir()
	if _, err := ReadTargets(""); !errors.Is(err, ErrUsage) {
		t.Errorf("empty name: %v", err)
	}
	if _, err := ReadTargets(filepath.Join(dir, "missing.md")); !errors.Is(err, ErrAbsentInput) {
		t.Errorf("missing: %v", err)
	}
	if _, err := ReadTargets(dir); !errors.Is(err, ErrAbsentInput) {
		t.Errorf("directory is not a regular file: %v", err)
	}
	p := write(t, filepath.Join(dir, "empty.md"), "")
	if s, err := ReadTargets(p); err != nil || s != "" {
		t.Errorf("empty file must read as empty, not as an error: %q %v", s, err)
	}
	if os.Geteuid() != 0 {
		u := write(t, filepath.Join(dir, "locked.md"), "| `/x` |\n")
		if err := os.Chmod(u, 0); err != nil {
			t.Fatal(err)
		}
		if _, err := ReadTargets(u); !errors.Is(err, ErrUnreadable) { // finding F2: bash returns an empty list, rc 0
			t.Errorf("mode 000: %v", err)
		}
	}
}

func TestDerivationNeverModifiesItsInput(t *testing.T) { // section 8
	p := write(t, filepath.Join(t.TempDir(), "TARGETS.md"), targetCorpus["basic"])
	before := sha256.Sum256([]byte(targetCorpus["basic"]))
	st0, _ := os.Stat(p)
	src, err := ReadTargets(p)
	if err != nil {
		t.Fatal(err)
	}
	PathsAll(src, rhEnv(""))
	b, _ := os.ReadFile(p)
	st1, _ := os.Stat(p)
	if sha256.Sum256(b) != before || !st1.ModTime().Equal(st0.ModTime()) {
		t.Fatal("input changed")
	}
}

// FINDING F1: the row test of the bash lib is `^\s*\|` where \s covers \v \f \r; core/gfm trims only space and
// tab. A line led by one of them is a row to the bash lib and not to gfm. Bash wins here (byte parity).
func TestFindingGfmRowShapeDiffersFromBash(t *testing.T) {
	if got := PathsAll(targetCorpus["vtab-row"], rhEnv("")); !reflect.DeepEqual(got, []string{"/after-cr", "/after-ff", "/after-vtab"}) {
		t.Fatalf("bash row shape not reproduced: %q", got)
	}
	for _, lead := range []string{"\v", "\f", "\r"} {
		if _, ok := gfm.SplitRow(lead+"| a |", gfm.Options{KeepCR: true}); ok {
			t.Errorf("gfm now treats %q-led lines as rows: the finding is resolved, drop the special case", lead)
		}
	}
}

// FINDING F5: target_name_for_retro splits the row on EVERY pipe (awk -F'|'); gfm honours `\|`. A name or path
// cell holding an escaped pipe therefore shifts the columns in bash. Bash behaviour is kept.
func TestFindingNameLookupSplitsOnEscapedPipes(t *testing.T) {
	cells, ok := gfm.SplitRow("| 1 | a\\|b | `/p` |", gfm.Options{})
	if !ok || len(cells) != 3 {
		t.Fatalf("gfm cells = %q", cells)
	}
	root := physical(t, t.TempDir())
	mkfiles(t, root, "p/retros/r.md")
	tgt := write(t, filepath.Join(root, "T.md"), "| 1 | a\\|b | `"+root+"/p` |\n")
	got, err := NameForRetro(tgt, filepath.Join(root, "p/retros/r.md"), rhEnv(root))
	if err != nil {
		t.Fatal(err)
	}
	// bash: $3 = ` a\`, $4 = `b `, so the path cell does not contain the token and the name falls back to the basename
	if got.Name != "p" {
		t.Fatalf("name = %q, want the basename fallback %q", got.Name, "p")
	}
}

func contains(xs []string, s string) bool {
	for _, x := range xs {
		if x == s {
			return true
		}
	}
	return false
}
