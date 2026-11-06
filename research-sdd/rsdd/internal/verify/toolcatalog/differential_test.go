//go:build !nodiff && unix

package toolcatalog

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
	"syscall"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/hookenv"
)

// Differential tests: the frozen legacy scripts (testdata/legacy, the bytes of the two scripts and lib/hook-emit.sh
// before the port) and the Go commands must print the same stdout and stderr and exit with the same code on the same
// kit directory, in the C and the C.UTF-8 locale. A host lacking bash, grep, sed, awk, cut, paste or jq, or the
// C.UTF-8 locale, FAILS the differential with a typed message: a skipped differential proves nothing.

var (
	oracleOnce sync.Once
	oracleErr  error
)

func requireOracleHost(t *testing.T) {
	t.Helper()
	oracleOnce.Do(func() {
		for _, tool := range []string{"bash", "grep", "sed", "awk", "cut", "paste", "jq"} {
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
		t.Fatalf("differential: the oracle host is incomplete; the Go port is NOT proven against the legacy scripts: %v", oracleErr)
	}
}

// legacyDir is the frozen tree: both scripts and lib/hook-emit.sh.
var legacyDir, legacyDirErr = filepath.Abs(filepath.Join("testdata", "legacy"))

// stage copies the frozen scripts into dir (the scripts read their inputs beside themselves).
func stage(t *testing.T, dir string) {
	t.Helper()
	if legacyDirErr != nil {
		t.Fatalf("differential: cannot resolve the oracle path: %v", legacyDirErr)
	}
	for _, rel := range []string{"verify-tool-catalog.sh", "verify-tool-catalog-hook.sh", "lib/hook-emit.sh"} {
		b, err := os.ReadFile(filepath.Join(legacyDir, rel))
		if err != nil {
			t.Fatal(err)
		}
		if err := os.MkdirAll(filepath.Dir(filepath.Join(dir, rel)), 0o755); err != nil {
			t.Fatal(err)
		}
		writeExecutable(t, filepath.Join(dir, rel), b)
	}
}

// writeExecutable writes an executable file that a script of the oracle runs directly. syscall.ForkLock is held
// while the file is open for writing: a child forked by a parallel test in that window would inherit the descriptor
// and the exec of the file would fail with "text file busy".
func writeExecutable(t *testing.T, path string, b []byte) {
	t.Helper()
	syscall.ForkLock.RLock()
	defer syscall.ForkLock.RUnlock()
	if err := os.WriteFile(path, b, 0o755); err != nil {
		t.Fatal(err)
	}
}

// runLegacy runs a staged script under bash with the given locale.
func runLegacy(t *testing.T, dir, loc, script string, args ...string) observed {
	t.Helper()
	requireOracleHost(t)
	cmd := exec.Command("bash", append([]string{filepath.Join(dir, script)}, args...)...)
	cmd.Dir = dir
	cmd.Env = []string{"PATH=" + os.Getenv("PATH"), "HOME=" + t.TempDir(), "LC_ALL=" + loc}
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

func scriptOf(hook bool) string {
	if hook {
		return "verify-tool-catalog-hook.sh"
	}
	return "verify-tool-catalog.sh"
}

// compare runs one case in both implementations and compares everything observable.
func compare(t *testing.T, c runCase, loc string) observed {
	t.Helper()
	dir := kit(t, c.files)
	stage(t, dir)
	want := runLegacy(t, dir, loc, scriptOf(c.hook), c.args...)
	run := Run
	if c.hook {
		run = RunHook
	}
	got := runGo(dir, loc, run, append([]string{dir}, c.args...)...)
	if got != want {
		t.Errorf("%s [%s]: Go differs from the legacy script\n legacy exit %d stdout %q stderr %q\n     go exit %d stdout %q stderr %q",
			c.name, loc, want.code, want.stdout, want.stderr, got.code, got.stdout, got.stderr)
	}
	return got
}

func TestDifferentialCheck(t *testing.T) {
	t.Parallel()
	for _, c := range checkCases() {
		for _, loc := range locales {
			t.Run(c.name+" "+loc, func(t *testing.T) {
				t.Parallel()
				got := compare(t, c, loc)
				if got.stdout == "" && got.stderr == "" {
					t.Errorf("both implementations printed nothing; the case proves nothing")
				}
			})
		}
	}
}

func TestDifferentialHook(t *testing.T) {
	t.Parallel()
	for _, c := range hookCases() {
		for _, loc := range locales {
			t.Run(c.name+" "+loc, func(t *testing.T) {
				t.Parallel()
				compare(t, c, loc)
			})
		}
	}
}

// stubbed replaces the check beside the frozen hook by a script that prints out and exits rc, and returns what the
// frozen hook then prints.
func stubbed(t *testing.T, c stubCase) observed {
	t.Helper()
	dir := t.TempDir()
	stage(t, dir)
	if err := os.WriteFile(filepath.Join(dir, "canned.txt"), []byte(c.out), 0o644); err != nil {
		t.Fatal(err)
	}
	stub := fmt.Sprintf("#!/usr/bin/env bash\ncat %q\nexit %d\n", filepath.Join(dir, "canned.txt"), c.rc)
	writeExecutable(t, filepath.Join(dir, "verify-tool-catalog.sh"), []byte(stub))
	var args []string
	if c.full {
		args = []string{"--full"}
	}
	return runLegacy(t, dir, "C.UTF-8", "verify-tool-catalog-hook.sh", args...)
}

// TestDifferentialHookStates feeds the canned outputs to the frozen hook and to emitHook (the seam RunHook calls after
// the check ran): the states the real check never produces, and the long ones. Where the frozen hook's could-not-run
// context outgrows hookenv.FailureCap, the port caps it (kit issue #2631) and must keep the header and the last line.
func TestDifferentialHookStates(t *testing.T) {
	t.Parallel()
	for _, c := range stubCases() {
		t.Run(c.name, func(t *testing.T) {
			t.Parallel()
			want := stubbed(t, c)
			var buf bytes.Buffer
			emitHook(&buf, strings.TrimRight(c.out, "\n"), c.rc, c.full)
			got := observed{buf.String(), "", 0}
			if got == want {
				return
			}
			wantCtx, gotCtx := contextOf(t, want.stdout), contextOf(t, got.stdout)
			wantLines, gotLines := strings.Split(wantCtx, "\n"), strings.Split(gotCtx, "\n")
			if want.code != got.code || want.stderr != got.stderr || hookenv.Width(wantCtx) <= hookenv.FailureCap ||
				hookenv.Width(gotCtx) > hookenv.FailureCap || gotLines[0] != wantLines[0] || !keepsTheCause(wantLines, gotLines) {
				t.Errorf("Go differs from the legacy hook\n legacy exit %d stdout %q stderr %q\n     go exit %d stdout %q", want.code, want.stdout, want.stderr, got.code, got.stdout)
			}
		})
	}
}

// keepsTheCause is whether the capped lines still show what the whole ones end with: the last line of the output, or
// when the output is one line, the leading part of it.
func keepsTheCause(whole, capped []string) bool {
	if len(whole) == 2 {
		return strings.HasPrefix(whole[1], strings.TrimSuffix(capped[1], "…"))
	}
	return capped[len(capped)-1] == whole[len(whole)-1]
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
		t.Errorf("%d files pinned; the oracle has 3 (the two scripts and lib/hook-emit.sh)", n)
	}
}
