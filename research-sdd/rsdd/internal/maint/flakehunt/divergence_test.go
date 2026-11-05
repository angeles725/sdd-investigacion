package flakehunt

import (
	"os"
	"strings"
	"testing"
)

// The intended divergences from the frozen bash script, each listed in tool-registry.d/kit-flake-hunt.md. The
// differential test compares exit codes only for the scenarios that touch them; these tests pin what Go does instead.

func TestHelpGoesToStdoutAndExitsZero(t *testing.T) {
	for _, flag := range []string{"-h", "--help"} {
		w := newWorld(t)
		r := w.goRun(flag)
		if r.rc != 0 || r.err != "" || !strings.Contains(r.out, "Usage:") || !strings.Contains(r.out, "--file-issues[=apply]") {
			t.Errorf("%s: rc %d err=%q out=%.80q", flag, r.rc, r.err, r.out)
		}
	}
}

func TestNumbersWithLeadingZerosAreDecimal(t *testing.T) {
	w := newWorld(t)
	w.standard()
	r := w.goRun("--repo", w.repo, "--out", w.root+"/o1", "--runs", "02", "--load", "00", "--suite", "s/stable.test.sh")
	if r.rc != 0 || !strings.Contains(r.out, "Flake hunt: runs=2 suites=1 load=0 ") {
		t.Errorf("rc %d out=%q err=%q (the bash read 02 as octal inside its arithmetic)", r.rc, r.out, r.err)
	}
}

func TestAnOverflowingNumberIsOneUsageLine(t *testing.T) {
	w := newWorld(t)
	w.standard()
	r := w.goRun("--repo", w.repo, "--out", w.root+"/o1", "--runs", "99999999999999999999", "--suite", "s/stable.test.sh")
	want := "kit-flake-hunt: --runs must be an integer >= 1 (got '99999999999999999999')\n"
	if r.rc != 2 || r.err != want {
		t.Errorf("rc %d err=%q, want %q (the bash also leaked `[: integer expression expected`)", r.rc, r.err, want)
	}
}

func TestSummaryCountsBeyondSixtyFourBitsAreJudgedAsDigits(t *testing.T) {
	w := newWorld(t)
	w.suite("big-pass.test.sh", `echo '== 99999999999999999999 passed · 0 failed =='`)
	w.suite("big-fail.test.sh", `echo '== 1 passed · 99999999999999999999 failed =='`)
	r := w.goRun("--repo", w.repo, "--out", w.root+"/o1", "--runs", "1", "--load", "0", "--suite", "s/big-pass.test.sh", "--suite", "s/big-fail.test.sh")
	if r.rc != 1 || !strings.Contains(r.out, "broken: s/big-fail.test.sh failed 1/1 — exit 0 but the summary reports 99999999999999999999 failed\n") ||
		!strings.Contains(r.out, "stable=1 ") {
		t.Errorf("rc %d out=%q err=%q", r.rc, r.out, r.err)
	}
}

func TestATrailingSlashOnOutIsDropped(t *testing.T) {
	w := newWorld(t)
	w.standard()
	r := w.goRun("--repo", w.repo, "--out", w.root+"/o1/", "--runs", "1", "--load", "0", "--suite", "s/stable.test.sh")
	if r.rc != 0 || !strings.Contains(r.out, "Results: "+w.root+"/o1/results.tsv\n") {
		t.Errorf("rc %d out=%q err=%q", r.rc, r.out, r.err)
	}
}

func TestWithoutRepoTheKitCheckoutAroundTheWorkingDirectoryIsHunted(t *testing.T) {
	w := newWorld(t)
	w.standard()
	w.stubRunAll("s/stable.test.sh\n", "s/stable.test.sh\ns/skip.test.sh\n")
	w.cwd = w.repo + "/research-sdd/toolbelt"
	r := w.goRun("--out", w.root+"/o1", "--runs", "1", "--load", "0")
	if r.rc != 0 || !strings.Contains(r.out, "suites=2 ") {
		t.Errorf("rc %d out=%q err=%q", r.rc, r.out, r.err)
	}
	if b, _ := os.ReadFile(w.rec + "/ra.log"); !strings.Contains(string(b), "--list-suites") {
		t.Errorf("the repo's own run-all.sh was not asked for the list: %q", b)
	}
}

func TestAnOutPathThatCannotBeCreatedIsOneTypedLine(t *testing.T) {
	w := newWorld(t)
	w.standard()
	w.file("ext/old.txt", "x")
	r := w.goRun("--repo", w.repo, "--out", w.root+"/ext/old.txt", "--runs", "1", "--load", "0", "--suite", "s/stable.test.sh")
	want := "degraded: kit-flake-hunt: cannot create output directory " + w.root + "/ext/old.txt\n"
	if r.rc != 2 || r.err != want {
		t.Errorf("rc %d err=%q, want %q (the bash also leaked mkdir's own message)", r.rc, r.err, want)
	}
}

func TestWithoutRepoOrKitLayoutTheWorkingDirectoryIsHunted(t *testing.T) {
	w := newWorld(t)
	w.standard()
	w.cwd = w.repo
	r := w.goRun("--out", w.root+"/o1", "--runs", "1", "--load", "0", "--suite", "s/stable.test.sh")
	if r.rc != 0 {
		t.Errorf("rc %d out=%q err=%q", r.rc, r.out, r.err)
	}
}
