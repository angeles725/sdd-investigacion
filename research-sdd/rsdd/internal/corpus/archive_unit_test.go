package corpus

import (
	"bytes"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/testkit/execfile"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// Unit tests of the pure pieces of `rsdd corpus archive`. The differential ones run the bash original (bash `printf %q`,
// the sed prefix rule, the lib/retro-status.sh functions) on the same inputs.

func archiveBashOut(t *testing.T, script string, args ...string) string {
	t.Helper()
	if _, err := exec.LookPath("bash"); err != nil {
		t.Skip("bash not found")
	}
	c := exec.Command("bash", append([]string{"-c", script, "_"}, args...)...)
	c.Env = append(os.Environ(), "LC_ALL=C.UTF-8")
	out, err := c.Output()
	if err != nil {
		t.Fatalf("bash: %v", err)
	}
	return string(out)
}

// archiveNewFx is a fixture root laid out like the parity harness: home, tmp and work dirs and the toolbelt farm.
func archiveNewFx(t *testing.T) *archiveFx {
	t.Helper()
	root := t.TempDir()
	for _, d := range []string{"home", "tmp", "work/case"} {
		if err := os.MkdirAll(filepath.Join(root, d), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	return &archiveFx{t: t, root: root, cdir: filepath.Join(root, "work", "case"), tb: archiveFarm(t, root)}
}

func TestArchiveQuoteMatchesBash(t *testing.T) {
	cases := []string{"", "plain", "/a/b c", "hint space", "a'b", `a"b`, "a$b", "~lead", "mid~dle", "#lead", "mid#dle", "a\tb", "a\nb",
		"é", "naïve dir", "a,b", "a=b:c@d%e+f", "(x)", "[x]", "{x}", "a;b|c&d", "a<b>c", "a*b?c", "back\\slash", "tick`s", "a!b", "a^b", "\x01\x7f", "a\x1bb"}
	for i := 1; i < 127; i++ {
		cases = append(cases, "x"+string(rune(i))+"y")
	}
	for _, s := range cases {
		if strings.ContainsRune(s, 0) {
			continue
		}
		want := archiveBashOut(t, `printf %q "$1"`, s)
		if got := archiveQuote(s, true); got != want {
			t.Errorf("archiveQuote(%q) = %s, bash %s", s, got, want)
		}
	}
	// outside a UTF-8 locale non-ASCII bytes are escaped
	if got := archiveQuote("é", false); got != `$'\303\251'` {
		t.Errorf("C locale: %s", got)
	}
}

func TestArchiveUTF8Locale(t *testing.T) {
	env := func(m map[string]string) func(string) string { return func(k string) string { return m[k] } }
	for _, c := range []struct {
		m    map[string]string
		want bool
	}{{map[string]string{"LANG": "C.UTF-8"}, true}, {map[string]string{"LC_ALL": "C", "LANG": "C.UTF-8"}, false},
		{map[string]string{"LC_CTYPE": "en_US.utf8"}, true}, {nil, false}} {
		if got := archiveUTF8Locale(env(c.m)); got != c.want {
			t.Errorf("%v: %v", c.m, got)
		}
	}
}

func TestArchiveParseArgs(t *testing.T) {
	cases := []struct {
		args []string
		want archiveArgs
	}{
		{[]string{"d"}, archiveArgs{target: "d"}},
		{[]string{"d", "--dry-run", "--focus", "x", "--allow-unreciprocated-corrections"}, archiveArgs{target: "d", dry: true, focus: "x", allowVC: true}},
		{[]string{"--focus"}, archiveArgs{errLine: "research-sdd-archive: --focus requires a focus name"}},
		{[]string{"--focus", ""}, archiveArgs{errLine: "research-sdd-archive: --focus requires a focus name"}},
		{[]string{"--nope"}, archiveArgs{errLine: "research-sdd-archive: unknown flag: --nope"}},
		{[]string{"-"}, archiveArgs{errLine: "research-sdd-archive: unknown flag: -"}},
		{[]string{"a", "b"}, archiveArgs{target: "a", errLine: "research-sdd-archive: unexpected extra arg: b"}},
		{[]string{"", "b"}, archiveArgs{target: "b"}}, // an empty first positional leaves the slot free, as in the bash
		{[]string{"--toolbelt", "/x/", "d"}, archiveArgs{target: "d", toolbelt: "/x"}},
		{[]string{"--toolbelt"}, archiveArgs{errLine: "research-sdd-archive: --toolbelt requires a directory"}},
	}
	for _, c := range cases {
		if got := archiveParseArgs(c.args); got != c.want {
			t.Errorf("%q: %+v, want %+v", c.args, got, c.want)
		}
	}
}

func TestArchiveBlockPrefixMatchesSed(t *testing.T) {
	for _, p := range []string{"/x/alpha-block7.md", "beta-block1.md", "a-b-block12-x.md", "foo-block1-block2.md", "x-bloque003.md", "plain.md", "/d/alpha-block9-dir/t-block1.md", "a-blockx.md", "-block1.md"} {
		want := archiveBashOut(t, `basename "$1" | sed -E 's/^(.*)-(block|bloque)0*[0-9]+.*/\1/'`, p)
		if got := archiveBlockPrefix(p); got != strings.TrimSuffix(want, "\n") {
			t.Errorf("archiveBlockPrefix(%q) = %q, sed %q", p, got, want)
		}
	}
}

func TestArchivePSAScan(t *testing.T) {
	state := "# S\n\n## Iteration history\n\n| # | d |\n|---|---|\n| 1 | a |\n| 2 | b | method: per-section-agent · 4 sections |\n```\n| 3 | c | method: per-section-agent · 40 sections |\n```\n> | 4 | x\n| n/a | y | method: per-section-agent · 50 sections |\n2 | z | method: per-section-agent · 60 sections\n| 5 | method: per-section-agent - 6 sections |\n\n## Next\n| 9 | late | method: per-section-agent · 99 sections |\n"
	ns, rows := archivePSAScan(state, true, 0)
	if !reflect.DeepEqual(ns, []int{4}) || rows != 3 { // rows 1, 2 and the fenced-out row are not counted: 1, 2, 5
		t.Errorf("psa: %v rows %d", ns, rows)
	}
	if ns, _ := archivePSAScan(state, true, 2); len(ns) != 0 {
		t.Errorf("skip 2 must hide the row 2 marker: %v", ns)
	}
	// the histrows reading needs no leading pipe and ignores fences: 1, 2, 3, "2 |", 5
	if _, rows := archivePSAScan(state, false, 0); rows != 5 {
		t.Errorf("histrows = %d", rows)
	}
	if ns, _ := archivePSAScan("## Iteration history\n| 1 | x | method: per-section-agent · 007 sections |\n", true, 0); !reflect.DeepEqual(ns, []int{7}) {
		t.Errorf("leading zeros: %v", ns)
	}
}

func TestArchiveRetroHelpersMatchBash(t *testing.T) {
	lib, err := filepath.Abs(archiveKitRel + "/toolbelt/lib/retro-status.sh")
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	files := map[string]string{
		"ok.md":        "<!-- review-status: pending -->\n# R\n",
		"upper.md":     "\n\n<!-- REVIEW-STATUS:  Applied -->\n",
		"noword.md":    "<!-- review-status: -->\n",
		"late.md":      "# heading\n<!-- review-status: pending -->\n",
		"bare.md":      "# R\n\nreview-status: pending\n",
		"bare11.md":    strings.Repeat("x\n", 10) + "review-status: pending\n",
		"none.md":      "# R\nbody\n",
		"excl.md":      "<!-- kit-retro: exclude -->\n# client\n",
		"exclspace.md": "  <!--  kit-retro:   EXCLUDE  -->  \n# client\n",
		"exclnot.md":   "<!-- kit-retro: exclude --> trailing\n",
		"bom.md":       "\xef\xbb\xbf<!-- review-status: pending -->\n",
		"empty.md":     "",
		"second.md":    "<!-- other -->\n<!-- review-status: done -->\n<!-- review-status: pending -->\n",
	}
	for n, c := range files {
		if err := os.WriteFile(filepath.Join(dir, n), []byte(c), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.Mkdir(filepath.Join(dir, "dir.md"), 0o755); err != nil {
		t.Fatal(err)
	}
	files["dir.md"] = ""
	files["missing.md"] = ""
	script := `. "$1"; f="$2"; retro_is_excluded "$f" && echo excl=1 || echo excl=0; echo "status=$(retro_review_status "$f")"; retro_has_bare_marker "$f" && echo bare=1 || echo bare=0`
	for n := range files {
		p := filepath.Join(dir, n)
		want := archiveBashOut(t, script, lib, p)
		ex := "0"
		if archiveRetroExcluded(p) {
			ex = "1"
		}
		bare := "0"
		if archiveRetroBareMarker(p) {
			bare = "1"
		}
		got := "excl=" + ex + "\nstatus=" + archiveRetroStatus(p) + "\nbare=" + bare + "\n"
		if got != want {
			t.Errorf("%s: got %q, bash %q", n, got, want)
		}
	}
}

func TestArchiveFindRules(t *testing.T) {
	for p, want := range map[string]bool{"/a/retros/x.md": true, "/a/retros/.md": true, "/a/retros/x.txt": false, "/a/retros/": false,
		"/retros/x/y.md": true, "/a/retrosx/x.md": false, "/tmp/retros/corp/anything.md": true} {
		if got := archiveRetroPathMatch(p); got != want {
			t.Errorf("archiveRetroPathMatch(%q) = %v", p, got)
		}
	}
	for b, want := range map[string]bool{"RETROS-INDEX.md": true, "index.md": true, "Index-2.md": true, "notindex.txt": false, "idx.md": false, "x.INDEX": false} {
		if got := archiveIndexName(b); got != want {
			t.Errorf("archiveIndexName(%q) = %v", b, got)
		}
	}
}

// Case 36b of the retired suite: every `git log ... --diff-filter=A` call passes --no-renames (kit issue #1401). A fake
// git on the PATH records the calls the command makes.
func TestArchiveGitLogCallsPassNoRenames(t *testing.T) {
	f := archiveNewFx(t)
	root := f.root
	bin := filepath.Join(root, "bin")
	if err := os.Mkdir(bin, 0o755); err != nil {
		t.Fatal(err)
	}
	logf := filepath.Join(root, "calls")
	real, err := exec.LookPath("git")
	if err != nil {
		t.Skip("git not found")
	}
	script := "#!/bin/bash\nprintf '%s\\n' \"$*\" >> '" + logf + "'\nexec '" + real + "' \"$@\"\n"
	execfile.Write(t, filepath.Join(bin, "git"), script)
	d := f.path("c")
	f.mkrunGit(d, true, "")
	env := append(archiveBaseEnv(t, root), "PATH="+bin+":"+os.Getenv("PATH"))
	_, _, code := archiveRunGo(f.tb, root, []string{d, "--dry-run"}, env, nil)
	if code != 0 {
		t.Fatalf("exit %d", code)
	}
	b, _ := os.ReadFile(logf)
	n := 0
	for _, l := range strings.Split(string(b), "\n") {
		if strings.Contains(l, " log ") && strings.Contains(l, "--diff-filter=A") {
			n++
			if !strings.Contains(l, "--no-renames") {
				t.Errorf("git log --diff-filter=A without --no-renames: %s", l)
			}
		}
	}
	if n == 0 {
		t.Fatal("no `git log --diff-filter=A` call was recorded: the check looked at nothing")
	}
	if !strings.Contains(string(b), "show --diff-filter=A -M --name-only") {
		t.Error("the added-block detector must force rename detection with -M")
	}
}

// INDEX.md is touched with the clock of the Stdio, not the wall clock (a dry run touches nothing).
func TestArchiveIndexIsTouchedWithTheStdioClock(t *testing.T) {
	if why := archiveHaveTools(); why != "" {
		t.Skip(why)
	}
	f := archiveNewFx(t)
	root := f.root
	d := f.path("c")
	f.mkgood(d)
	f.chtimes(filepath.Join(d, "INDEX.md"), "2001-01-01")
	run := func(extra ...string) {
		_, _, code := archiveRunGo(f.tb, root, append([]string{d}, extra...), archiveBaseEnv(t, root), nil)
		if code != 0 {
			t.Fatalf("exit %d", code)
		}
	}
	mtime := func() time.Time { st, _ := os.Stat(filepath.Join(d, "INDEX.md")); return st.ModTime().UTC() }
	run("--dry-run")
	if got := mtime(); got.Year() != 2001 {
		t.Errorf("--dry-run touched INDEX.md: %v", got)
	}
	run()
	if got := mtime(); !got.Equal(archiveClock) {
		t.Errorf("INDEX.md mtime = %v, want the Stdio clock %v", got, archiveClock)
	}
}

// A run without --toolbelt and without a resolvable kit is an operational failure, never a silent pass.
func TestArchiveNoToolbeltIsOperational(t *testing.T) {
	root := t.TempDir()
	var o, e bytes.Buffer
	env := map[string]string{"HOME": root}
	s := cli.Stdio{In: strings.NewReader(""), Out: &o, Err: &e, Env: func(k string) string { return env[k] },
		Environ: func() []string { return nil }, Clock: func() time.Time { return archiveClock }, Cwd: root}
	if code := archiveRun([]string{root}, s); code != 1 || !strings.Contains(e.String(), "cannot find the toolbelt") {
		t.Errorf("code %d, stderr %q", code, e.String())
	}
}
