//go:build unix

package floss

// Edge tests for the helpers of run_unix.go. None needs bwrap, Python or the floss tool, so `make teeth`
// (-tags nodiff, a bare CI runner) kills the mutants on these boundaries.

import (
	"math/big"
	"strings"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/proc"
)

func envOf(m map[string]string) cli.Stdio {
	return cli.Stdio{Env: func(k string) string { return m[k] }}
}

func TestTerminalWidthFollowsCOLUMNS(t *testing.T) {
	for _, tc := range []struct {
		cols string
		want int
	}{
		{"", 78}, {"abc", 78}, {"0", 78}, {"-5", 78},
		{"1", -1}, {"100", 98}, {"1048575", 1048573}, {"1048576", 78}, {"99999999999999999999999", 78},
	} {
		if got := terminalWidth(envOf(map[string]string{"COLUMNS": tc.cols})); got != tc.want {
			t.Errorf("COLUMNS=%q: width %d, want %d", tc.cols, got, tc.want)
		}
	}
}

func TestRunValidatesCapsInclusivelyAtOne(t *testing.T) {
	one := func() *big.Int { return big.NewInt(1) }
	zero := big.NewInt(0)
	// A canonical-path refusal comes after the cap checks, so reaching it proves the caps were accepted.
	reaches := func(o options) string {
		var stage string
		_, err := run(o, envOf(nil), &stage)
		if err == nil {
			t.Fatal("want an error from the unusable output path")
		}
		return err.Error()
	}
	base := func() options {
		return options{input: "in", output: "a/../b", timeout: one(), maxStrings: one(), maxStringLen: one()}
	}
	if got := reaches(base()); !strings.Contains(got, "canonical path") {
		t.Errorf("caps of 1: want the output-path refusal, got %q", got)
	}
	for name, mod := range map[string]func(*options){
		"--timeout":        func(o *options) { o.timeout = zero },
		"--max-strings":    func(o *options) { o.maxStrings = zero },
		"--max-string-len": func(o *options) { o.maxStringLen = zero },
	} {
		o := base()
		mod(&o)
		if got := reaches(o); !strings.Contains(got, name+" must be >= 1") {
			t.Errorf("%s 0: got %q", name, got)
		}
	}
}

func TestRunRecordSeparatesExitCodeFromSignal(t *testing.T) {
	rec := runRecordOf(proc.Result{ReturnCode: 0})
	if rec["exit_code"] != 0 || rec["signal"] != nil {
		t.Errorf("exit 0: exit_code=%v signal=%v, want 0 and nil", rec["exit_code"], rec["signal"])
	}
	rec = runRecordOf(proc.Result{ReturnCode: 3})
	if rec["exit_code"] != 3 || rec["signal"] != nil {
		t.Errorf("exit 3: exit_code=%v signal=%v, want 3 and nil", rec["exit_code"], rec["signal"])
	}
	rec = runRecordOf(proc.Result{ReturnCode: -9})
	if rec["exit_code"] != nil || rec["signal"] != 9 {
		t.Errorf("signal 9: exit_code=%v signal=%v, want nil and 9", rec["exit_code"], rec["signal"])
	}
}

func TestCompletenessIsFailedOnlyWithErrors(t *testing.T) {
	if got := completenessOf(nil); got != "complete" {
		t.Errorf("no errors: %q, want complete", got)
	}
	if got := completenessOf([]string{"timeout"}); got != "failed" {
		t.Errorf("one error: %q, want failed", got)
	}
}

func TestConfiguredReturnsOnlyNonEmptyValues(t *testing.T) {
	s := envOf(map[string]string{"SET": "v"})
	if p := configured(s, "SET"); p == nil || *p != "v" {
		t.Errorf("set key: got %v, want pointer to v", p)
	}
	if p := configured(s, "UNSET"); p != nil {
		t.Errorf("unset key: got %q, want nil", *p)
	}
}

func TestClampSecondsCapsAtOneHundredYears(t *testing.T) {
	const hundredYears = 100 * 365 * 24 * 3600
	want := time.Duration(hundredYears) * time.Second
	huge := new(big.Int).Lsh(big.NewInt(1), 80)
	for name, n := range map[string]*big.Int{
		"huge": huge, "max int64": big.NewInt(1<<63 - 1), "one past the cap": big.NewInt(hundredYears + 1),
		"the cap": big.NewInt(hundredYears),
	} {
		if got := clampSeconds(n); got != want {
			t.Errorf("%s: %v, want %v", name, got, want)
		}
	}
	if got := clampSeconds(big.NewInt(hundredYears - 1)); got != want-time.Second {
		t.Errorf("one under the cap: %v, want %v", got, want-time.Second)
	}
	if got := clampSeconds(big.NewInt(7)); got != 7*time.Second {
		t.Errorf("7: %v, want 7s", got)
	}
}

func TestIsoZPrintsMicrosecondsOnlyWhenNonZero(t *testing.T) {
	whole := time.Date(2026, 1, 2, 3, 4, 5, 0, time.UTC)
	if got := isoZ(whole); got != "2026-01-02T03:04:05Z" {
		t.Errorf("whole second: %q", got)
	}
	if got := isoZ(whole.Add(123456 * time.Microsecond)); got != "2026-01-02T03:04:05.123456Z" {
		t.Errorf("with microseconds: %q", got)
	}
	if got := isoZ(whole.Add(999 * time.Nanosecond)); got != "2026-01-02T03:04:05Z" {
		t.Errorf("sub-microsecond only: %q", got)
	}
}

func TestHomeDirFallsBackToRoot(t *testing.T) {
	if got := homeDir(envOf(map[string]string{"HOME": "/home/u/"})); got != "/home/u" {
		t.Errorf("HOME=/home/u/: %q, want /home/u", got)
	}
	if got := homeDir(envOf(nil)); got != "/" {
		t.Errorf("no HOME: %q, want /", got)
	}
	if got := homeDir(envOf(map[string]string{"HOME": "/"})); got != "/" {
		t.Errorf("HOME=/: %q, want /", got)
	}
}

func TestSplitPathOfEmptyAndRootPaths(t *testing.T) {
	for _, tc := range []struct{ in, name, parent string }{
		{"", "", "."}, {"/", "", "/"}, {"a", "a", "."}, {"/a", "a", "/"}, {"a/b", "b", "a"}, {"/a/b/c", "c", "/a/b"},
	} {
		if name, parent := splitPath(tc.in); name != tc.name || parent != tc.parent {
			t.Errorf("splitPath(%q) = (%q, %q), want (%q, %q)", tc.in, name, parent, tc.name, tc.parent)
		}
	}
}

func TestJoinCwdKeepsAbsoluteAndCwdlessPaths(t *testing.T) {
	for _, tc := range []struct{ cwd, p, want string }{
		{"/w", "x", "/w/x"}, {"/w/", "x", "/w/x"}, {"/w", "/abs", "/abs"}, {"", "x", "x"}, {"", "/abs", "/abs"},
	} {
		if got := joinCwd(tc.cwd, tc.p); got != tc.want {
			t.Errorf("joinCwd(%q, %q) = %q, want %q", tc.cwd, tc.p, got, tc.want)
		}
	}
}
