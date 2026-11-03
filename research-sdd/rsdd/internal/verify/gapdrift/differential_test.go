//go:build !nodiff && unix

package gapdrift

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"math/rand"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

// Differential tests: the frozen legacy script (testdata/legacy, the bytes of check-gap-drift.sh and its libs before
// the port) and the Go command must print the same stdout and stderr and exit with the same code on the same corpus.
// A host lacking bash, find, grep or GNU awk, or the C.UTF-8 locale, FAILS the differential with a typed message: a
// skipped differential proves nothing.

var (
	oracleOnce sync.Once
	oracleErr  error
)

func requireOracleHost(t *testing.T) {
	t.Helper()
	oracleOnce.Do(func() {
		for _, tool := range []string{"bash", "find", "grep", "awk"} {
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
		t.Fatalf("differential: the oracle host is incomplete; the Go port is NOT proven against check-gap-drift.sh: %v", oracleErr)
	}
}

var legacyScript, legacyScriptErr = filepath.Abs(filepath.Join("testdata", "legacy", "check-gap-drift.sh"))

// runLegacy runs the frozen script in cwd.
func runLegacy(t *testing.T, cwd string, args ...string) observed {
	t.Helper()
	requireOracleHost(t)
	if legacyScriptErr != nil {
		t.Fatalf("differential: cannot resolve the oracle path; the Go port is NOT proven against check-gap-drift.sh: %v", legacyScriptErr)
	}
	cmd := exec.Command("bash", append([]string{legacyScript}, args...)...)
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

// assertSame runs both implementations in dir with args ({D} is replaced by dir) and compares everything observable.
func assertSame(t *testing.T, name, dir string, args ...string) observed {
	t.Helper()
	a := make([]string, len(args))
	for i, x := range args {
		a[i] = strings.ReplaceAll(x, "{D}", dir)
	}
	want := runLegacy(t, dir, a...)
	want.stderr = withoutInterpreterNoise(want.stderr)
	got := runGo(dir, a...)
	if got != want {
		t.Errorf("%s: Go differs from the legacy script\n legacy exit %d stdout %q stderr %q\n     go exit %d stdout %q stderr %q",
			name, want.code, want.stdout, want.stderr, got.code, got.stdout, got.stderr)
	}
	return got
}

// withoutInterpreterNoise drops the diagnostics bash and awk print on their own before the script's message (the `[`
// "integer expression expected" line, awk's "cannot open file" line). They are the interpreters' text, not the
// tool's report, and the Go command has no interpreter to print them (divergence D7 in tool-registry.d).
func withoutInterpreterNoise(s string) string {
	var keep []string
	for _, l := range strings.SplitAfter(s, "\n") {
		if strings.HasPrefix(l, legacyScript+": ") || strings.HasPrefix(l, "awk: ") {
			continue
		}
		keep = append(keep, l)
	}
	return strings.Join(keep, "")
}

const bullets1 = "# Block 1\n\n## Child gaps\n- **B1-G1** widgets frobnicate sprockets under load\n- **B1-G2** how does the gizmo calibrate\n- **B1-G3** alpha beta gamma delta epsilon\n- **B1-G10** unrelated ten\n"

func TestDifferentialOutcomes(t *testing.T) {
	lorem := strings.Repeat("lorem ipsum dolor ", 8)
	cases := []struct {
		name  string
		files map[string]string
		args  []string
	}{
		{"clean: every row matches", map[string]string{"RESEARCH-STATE.md": state(row("high", "B1-G1 widgets frobnicate sprockets under load", "pending")), "t-block1.md": bullets1}, []string{"{D}"}},
		{"single row drift", map[string]string{"RESEARCH-STATE.md": state(row("high", "B1-G1 cats and dogs and birds", "pending")), "t-block1.md": bullets1}, []string{"{D}"}},
		{"drift at first, middle and last", map[string]string{"RESEARCH-STATE.md": state(
			row("high", "B1-G1 cats dogs birds", "pending"), row("low", "B1-G2 how does the gizmo calibrate", "pending"),
			row("medium", "B1-G3 alpha beta gamma delta epsilon", "pending"), row("high", "B1-G3 zebra yak xylophone walrus", "pending"),
			row("high", "B1-G2 fish frogs newts", "pending")), "t-block1.md": bullets1}, []string{"{D}"}},
		{"threshold 0 flags nothing", map[string]string{"RESEARCH-STATE.md": state(row("high", "B1-G1 cats dogs birds", "pending")), "t-block1.md": bullets1}, []string{"{D}", "--threshold", "0"}},
		{"threshold 100 flags a partial overlap", map[string]string{"RESEARCH-STATE.md": state(row("high", "B1-G1 widgets frobnicate cats", "pending")), "t-block1.md": bullets1}, []string{"{D}", "--threshold", "100"}},
		{"threshold boundary 67 (2 of 3 shared = 66%)", map[string]string{"RESEARCH-STATE.md": state(row("high", "B1-G1 widgets frobnicate cats", "pending")), "t-block1.md": bullets1}, []string{"{D}", "--threshold", "67"}},
		{"threshold boundary 66", map[string]string{"RESEARCH-STATE.md": state(row("high", "B1-G1 widgets frobnicate cats", "pending")), "t-block1.md": bullets1}, []string{"{D}", "--threshold", "66"}},
		{"non-pending skipped by default", map[string]string{"RESEARCH-STATE.md": state(row("high", "B1-G1 cats dogs birds", "done"), row("low", "B1-G2 how does the gizmo calibrate", "done")), "t-block1.md": bullets1}, []string{"{D}"}},
		{"--all checks non-pending rows", map[string]string{"RESEARCH-STATE.md": state(row("high", "B1-G1 cats dogs birds", "done"), row("low", "B1-G2 how does the gizmo calibrate", "pending")), "t-block1.md": bullets1}, []string{"{D}", "--all"}},
		{"--state names another file", map[string]string{"RESEARCH-STATE.md": state(row("high", "B1-G1 widgets frobnicate sprockets", "pending")), "other.md": state(row("high", "B1-G1 cats dogs birds", "pending")), "t-block1.md": bullets1}, []string{"{D}", "--state", "{D}/other.md"}},
		{"--state relative to cwd", map[string]string{"RESEARCH-STATE.md": "", "other.md": state(row("high", "B1-G1 cats dogs birds", "pending")), "t-block1.md": bullets1}, []string{".", "--state", "other.md"}},
		{"relative target", map[string]string{"RESEARCH-STATE.md": state(row("high", "B1-G1 cats dogs birds", "pending")), "t-block1.md": bullets1}, []string{"."}},
		{"options in any order", map[string]string{"RESEARCH-STATE.md": state(row("high", "B1-G1 cats dogs birds", "done")), "t-block1.md": bullets1}, []string{"{D}", "--all", "--threshold", "50", "--state", "{D}/RESEARCH-STATE.md"}},
		{"repeated --state keeps the last", map[string]string{"RESEARCH-STATE.md": "", "a.md": state(row("high", "B1-G1 cats dogs birds", "pending")), "b.md": state(row("high", "B1-G2 how does the gizmo calibrate", "pending")), "t-block1.md": bullets1}, []string{"{D}", "--state", "{D}/a.md", "--state", "{D}/b.md"}},
		{"CRLF state and block", map[string]string{"RESEARCH-STATE.md": strings.ReplaceAll(state(row("high", "B1-G1 cats dogs birds", "pending"), row("high", "B1-G2 how does the gizmo calibrate", "pending")), "\n", "\r\n"), "t-block1.md": strings.ReplaceAll(bullets1, "\n", "\r\n")}, []string{"{D}"}},
		{"escaped pipes in the row", map[string]string{"RESEARCH-STATE.md": state(row("high", `B1-G1 widgets \| frobnicate sprockets under \| load`, "pending")), "t-block1.md": bullets1}, []string{"{D}"}},
		{"long row text is cut at 90 characters", map[string]string{"RESEARCH-STATE.md": state(row("high", "B1-G1 "+lorem+lorem, "pending")), "t-block1.md": bullets1}, []string{"{D}"}},
		{"non-ASCII text at the cut", map[string]string{"RESEARCH-STATE.md": state(row("high", "B1-G1 "+strings.Repeat("ñandú café ", 12), "pending")), "t-block1.md": bullets1}, []string{"{D}"}},
		{"NO-BULLET", map[string]string{"RESEARCH-STATE.md": state(row("high", "B1-G9 some prose-only gap", "pending")), "t-block1.md": bullets1}, []string{"{D}"}},
		{"NO-BLOCK", map[string]string{"RESEARCH-STATE.md": state(row("high", "B7-G1 gap in an absent block", "pending")), "t-block1.md": bullets1}, []string{"{D}"}},
		{"NO-WORDS", map[string]string{"RESEARCH-STATE.md": state(row("high", "B1-G1 9.5.0 1166", "pending")), "t-block1.md": bullets1}, []string{"{D}"}},
		{"UNPARSED", map[string]string{"RESEARCH-STATE.md": state(row("urgent", "B1-G1 x", "pending"), "| high | B1-G2 only three cells |"), "t-block1.md": bullets1}, []string{"{D}"}},
		{"closed-class rows are skipped", map[string]string{"RESEARCH-STATE.md": state(row("—", "B1-G1 closed", "done"), row("~~low~~", "B1-G2 struck", "done"), row("4", "B1-G3 history", "done")), "t-block1.md": bullets1}, []string{"{D}"}},
		{"only closed-class rows: not applicable", map[string]string{"RESEARCH-STATE.md": state(row("—", "B1-G1 closed", "done")), "t-block1.md": bullets1}, []string{"{D}", "--all"}},
		{"pending row with a numeric priority is compared", map[string]string{"RESEARCH-STATE.md": state(row("3", "B1-G1 cats dogs birds", "pending")), "t-block1.md": bullets1}, []string{"{D}"}},
		{"DEGRADED: rows in scope, none comparable", map[string]string{"RESEARCH-STATE.md": state(row("high", "B7-G1 a", "pending"), row("high", "B1-G9 b", "pending"), row("high", "B1-G1 9.5.0", "pending")), "t-block1.md": bullets1}, []string{"{D}"}},
		{"no backlog rows: not applicable", map[string]string{"RESEARCH-STATE.md": "# s\n\nno gap table\n", "t-block1.md": bullets1}, []string{"{D}"}},
		{"empty state file", map[string]string{"RESEARCH-STATE.md": "", "t-block1.md": bullets1}, []string{"{D}"}},
		{"no pending rows", map[string]string{"RESEARCH-STATE.md": state(row("high", "B1-G1 x", "done"), row("low", "B1-G2 y", "closed")), "t-block1.md": bullets1}, []string{"{D}"}},
		{"no block files at all", map[string]string{"RESEARCH-STATE.md": state(row("high", "B1-G1 widgets", "pending"))}, []string{"{D}"}},
		{"B1-G1 never reads the B1-G10 bullet", map[string]string{"RESEARCH-STATE.md": state(row("high", "B1-G1 unrelated ten", "pending")), "t-block1.md": "- **B1-G10** unrelated ten\n"}, []string{"{D}"}},
		{"bloque files and a suffix", map[string]string{"RESEARCH-STATE.md": state(row("high", "B2-G1 cats dogs birds", "pending")), "x-bloque2-notes.md": "- **B2-G1** cats dogs birds\n"}, []string{"{D}"}},
		{"block files three levels deep, not four", map[string]string{"RESEARCH-STATE.md": state(row("high", "B1-G1 widgets", "pending"), row("high", "B2-G1 widgets", "pending")), "a/b/t-block1.md": bullets1, "a/b/c/t-block2.md": bullets1}, []string{"{D}"}},
		{".git and template files are ignored", map[string]string{"RESEARCH-STATE.md": state(row("high", "B1-G1 widgets", "pending"), row("high", "B2-G1 widgets", "pending")), ".git/t-block1.md": bullets1, "t-block2.template.md": bullets1}, []string{"{D}"}},
		{"nested worktrees are ignored", map[string]string{"RESEARCH-STATE.md": state(row("high", "B1-G1 widgets", "pending")), ".claude/worktrees/w/t-block1.md": bullets1}, []string{"{D}"}},
		{"the first block file with the bullet wins", map[string]string{"RESEARCH-STATE.md": state(row("high", "B1-G1 widgets frobnicate", "pending")), "a-block1.md": "# no bullet here\n", "b-block1.md": bullets1}, []string{"{D}"}},
		{"bullet forms", map[string]string{"RESEARCH-STATE.md": state(row("high", "B3-G1 aaa bbb ccc", "pending"), row("high", "B3-G2 aaa bbb ccc", "pending"), row("high", "B3-G3 aaa bbb ccc", "pending"), row("high", "B3-G4 aaa bbb ccc", "pending")),
			"t-block3.md": "- **[B3-G1]** aaa bbb ccc\n* **B3-G2 (open, note)** aaa bbb ccc\n- **B3-G3**: aaa bbb ccc\n  - **B3-G4** aaa\ncontinued bbb ccc\n"}, []string{"{D}"}},
		{"state with a different name in a subdir", map[string]string{"sub/STATE.md": state(row("high", "B1-G1 cats dogs birds", "pending")), "t-block1.md": bullets1}, []string{"{D}", "--state", "{D}/sub/STATE.md"}},
		// operational failures
		{"usage: no arguments", nil, []string{}},
		{"usage: empty target", nil, []string{""}},
		{"usage: target is not a directory", map[string]string{"f": "x"}, []string{"{D}/f"}},
		{"usage: missing directory", nil, []string{"{D}/nope"}},
		{"usage: unknown option", map[string]string{"RESEARCH-STATE.md": ""}, []string{"{D}", "--bogus"}},
		{"usage: --state without a value", map[string]string{"RESEARCH-STATE.md": ""}, []string{"{D}", "--state"}},
		{"usage: --state with an empty value", map[string]string{"RESEARCH-STATE.md": ""}, []string{"{D}", "--state", ""}},
		{"usage: --threshold without a value", map[string]string{"RESEARCH-STATE.md": ""}, []string{"{D}", "--threshold"}},
		{"usage: a stray positional argument", map[string]string{"RESEARCH-STATE.md": ""}, []string{"{D}", "extra"}},
		{"threshold: not a number", map[string]string{"RESEARCH-STATE.md": ""}, []string{"{D}", "--threshold", "abc"}},
		{"threshold: empty", map[string]string{"RESEARCH-STATE.md": ""}, []string{"{D}", "--threshold", ""}},
		{"threshold: negative", map[string]string{"RESEARCH-STATE.md": ""}, []string{"{D}", "--threshold", "-5"}},
		{"threshold: decimal point", map[string]string{"RESEARCH-STATE.md": ""}, []string{"{D}", "--threshold", "1.5"}},
		{"threshold: over 100", map[string]string{"RESEARCH-STATE.md": ""}, []string{"{D}", "--threshold", "101"}},
		{"threshold: out of integer range", map[string]string{"RESEARCH-STATE.md": ""}, []string{"{D}", "--threshold", "99999999999999999999999"}},
		{"threshold is checked before the state file", nil, []string{"{D}", "--threshold", "x"}},
		{"state file absent", map[string]string{"t-block1.md": bullets1}, []string{"{D}"}},
		{"state file is a directory", map[string]string{"RESEARCH-STATE.md/": ""}, []string{"{D}"}},
		{"--state names a missing file", map[string]string{"RESEARCH-STATE.md": ""}, []string{"{D}", "--state", "{D}/missing.md"}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			dir := corpus(t, c.files)
			got := assertSame(t, c.name, dir, c.args...)
			if got.stdout == "" && got.stderr == "" {
				t.Errorf("%s: both implementations printed nothing; the case proves nothing", c.name)
			}
		})
	}
}

func TestDifferentialUnreadableInputs(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("running as root: a mode 000 file is still readable, so the unreadable-input cases cannot be built")
	}
	t.Run("block file", func(t *testing.T) {
		dir := corpus(t, map[string]string{"RESEARCH-STATE.md": state(row("high", "B1-G1 widgets", "pending")), "t-block1.md": bullets1})
		if err := os.Chmod(filepath.Join(dir, "t-block1.md"), 0); err != nil {
			t.Fatal(err)
		}
		got := assertSame(t, "unreadable block file", dir, "{D}")
		if got.code != 2 || !strings.Contains(got.stderr, "check-gap-drift: cannot read ") {
			t.Errorf("got %+v, want exit 2 and the cannot-read message", got)
		}
	})
	t.Run("directory", func(t *testing.T) {
		dir := corpus(t, map[string]string{"RESEARCH-STATE.md": state(row("high", "B1-G1 widgets", "pending")), "t-block1.md": bullets1, "sub/x.md": "x"})
		sub := filepath.Join(dir, "sub")
		if err := os.Chmod(sub, 0); err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { _ = os.Chmod(sub, 0o755) })
		got := assertSame(t, "unreadable directory", dir, "{D}")
		if got.code != 2 || !strings.Contains(got.stderr, "cannot list block files under") {
			t.Errorf("got %+v, want exit 2 and the cannot-list message", got)
		}
	})
	t.Run("state file", func(t *testing.T) {
		dir := corpus(t, map[string]string{"RESEARCH-STATE.md": state(row("high", "B1-G1 widgets", "pending")), "t-block1.md": bullets1})
		if err := os.Chmod(filepath.Join(dir, "RESEARCH-STATE.md"), 0); err != nil {
			t.Fatal(err)
		}
		assertSame(t, "unreadable state file", dir, "{D}")
	})
}

var gdWords = strings.Fields("widgets frobnicate sprockets gizmo calibrate alpha beta gamma delta load month months class bosses 9.5.0 the of café ñandú x.y a")

func gdText(r *rand.Rand, n int) string {
	w := make([]string, n)
	for i := range w {
		w[i] = gdWords[r.Intn(len(gdWords))]
	}
	return strings.Join(w, " ")
}

// TestDifferentialGenerated runs seeded random corpora: several block files, a state with random rows, thresholds and
// the --all flag. The seed is fixed so a failure reproduces.
func TestDifferentialGenerated(t *testing.T) {
	r := rand.New(rand.NewSource(2645))
	prios := []string{"high", "medium", "low", "deferred", "—", "urgent", "7"}
	stats := []string{"pending", "pending", "Pending (wait)", "done", "closed"}
	for i := 0; i < 40; i++ {
		files := map[string]string{}
		for b := 1; b <= 3; b++ {
			if r.Intn(6) == 0 {
				continue // a block with no file
			}
			var sb strings.Builder
			for g := 1; g <= 6; g++ {
				if r.Intn(5) == 0 {
					continue
				}
				fmt.Fprintf(&sb, "- **B%d-G%d** %s\n", b, g, gdText(r, 2+r.Intn(5)))
				if r.Intn(3) == 0 {
					fmt.Fprintf(&sb, "%s\n", gdText(r, 3))
				}
			}
			name := fmt.Sprintf("t-block%d.md", b)
			if r.Intn(4) == 0 {
				name = fmt.Sprintf("sub/t-bloque%d-extra.md", b)
			}
			files[name] = sb.String()
		}
		var rows []string
		for n := r.Intn(8); n > 0; n-- {
			rows = append(rows, row(prios[r.Intn(len(prios))], fmt.Sprintf("B%d-G%d %s", 1+r.Intn(4), 1+r.Intn(7), gdText(r, r.Intn(6))), stats[r.Intn(len(stats))]))
		}
		files["RESEARCH-STATE.md"] = state(rows...)
		dir := corpus(t, files)
		args := []string{"{D}", "--threshold", fmt.Sprint(r.Intn(101))}
		if r.Intn(2) == 0 {
			args = append(args, "--all")
		}
		assertSame(t, fmt.Sprintf("generated-%d", i), dir, args...)
	}
}

// The frozen oracle is pinned by hash, so an edit to it cannot go unnoticed. Updating a hash is a deliberate act.
func TestLegacyOracleIsPinned(t *testing.T) {
	sums, err := os.ReadFile(filepath.Join("testdata", "legacy", "SHA256SUMS"))
	if err != nil {
		t.Fatal(err)
	}
	n := 0
	for _, line := range strings.Split(strings.TrimSpace(string(sums)), "\n") {
		want, rel, ok := strings.Cut(line, "  ")
		if !ok || len(want) != 64 {
			t.Fatalf("malformed SHA256SUMS line %q", line)
		}
		b, err := os.ReadFile(filepath.Join("testdata", "legacy", rel))
		if err != nil {
			t.Fatalf("pinned file missing: %v", err)
		}
		if got := sha256.Sum256(b); hex.EncodeToString(got[:]) != want {
			t.Errorf("%s changed: sha256 %x, pinned %s", rel, got, want)
		}
		n++
	}
	if n != 3 {
		t.Errorf("%d files pinned; the oracle has 3 (the script, lib/gap-rows.sh and lib/block-files.sh)", n)
	}
}
