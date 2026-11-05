//go:build !nodiff && unix

package gapdrift

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
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

func TestDifferentialOutcomes(t *testing.T) {
	t.Parallel()
	for _, c := range outcomeCases() {
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
	t.Parallel()
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

// TestDifferentialGenerated runs the seeded random corpora (genSeeds); the same corpora are recorded as goldens.
func TestDifferentialGenerated(t *testing.T) {
	t.Parallel()
	for _, c := range generatedCases() {
		assertSame(t, c.name, corpus(t, c.files), c.args...)
	}
}

// The frozen oracle is pinned by hash, so an edit to it cannot go unnoticed. Updating a hash is a deliberate act.
func TestLegacyOracleIsPinned(t *testing.T) {
	t.Parallel()
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
