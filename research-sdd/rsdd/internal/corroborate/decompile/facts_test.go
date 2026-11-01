package decompile

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/corroborate/classfile"
)

const (
	goodLine = "CLASSFILE major=52 lvt=yes classes=1 resugar_risk=no unreadable=0 partial=0 truncated=none"
	unknown  = "CLASSFILE major=unknown lvt=unknown classes=unknown resugar_risk=unknown unreadable=unknown partial=unknown truncated=unknown"
	warning  = "WARN: decompiled source is a reconstruction; syntax-level claims (string concatenation, lambdas, switch, records, generics) need bytecode evidence (javap -c -p, see --javap), not the decompiled text"
)

// TestClassfileHeader: the header the facts step puts on stderr BEFORE any engine runs, and every way it fails
// with the same field set and a typed reason (old H1, H2, H6, H6b, H7, H7b, H12, mCF1, mCF2, mCF4-mCF6, mCF10).
func TestClassfileHeader(t *testing.T) {
	for _, tt := range []struct {
		name  string
		facts factsResult
		env   map[string]string
		want  string // stderr up to the reconstruction warning
	}{
		{"H1 the line is printed as is", factsResult{line: goodLine}, nil, goodLine + "\n"},
		{"H6b a failing step: typed error plus its first stderr line", factsResult{rc: 3, firstErr: "rsdd exploded"}, nil,
			unknown + " reason=facts-error rc=3\nWARN: classfile-facts helper: rsdd exploded\n"},
		{"a failing step with nothing on stderr has no WARN", factsResult{rc: 1}, nil, unknown + " reason=facts-error rc=1\n"},
		{"a step that fails keeps no line", factsResult{rc: 3, line: goodLine}, nil, unknown + " reason=facts-error rc=3\n"},
		{"exit 0 with no line is an error, not unavailable", factsResult{rc: 0}, nil, unknown + " reason=facts-error rc=0\n"},
		{"H7 the budget ran out", factsResult{timedOut: true, rc: 9, line: goodLine}, nil, unknown + " reason=facts-timeout\n"},
	} {
		t.Run(tt.name, func(t *testing.T) {
			w := newWorld(t)
			w.facts = func(string, time.Duration, cli.Stdio) factsResult { return tt.facts }
			_, stderr, rc := w.exec(w.touch("Test.class"), filepath.Join(w.root, "out"))
			if rc != 0 || stderr != tt.want+warning+"\n" {
				t.Errorf("rc %d stderr:\n%q\nwant:\n%q", rc, stderr, tt.want+warning+"\n")
			}
		})
	}
	t.Run("H12 no timeout binary: the step is skipped, typed", func(t *testing.T) {
		w := newWorld(t)
		w.env["RSDD_TIMEOUT_BIN"] = filepath.Join(w.root, "no-such")
		_, stderr, _ := w.exec(w.touch("Test.class"), filepath.Join(w.root, "out"))
		want := "WARN: '" + w.env["RSDD_TIMEOUT_BIN"] + "' not found; engines run UNBOUNDED (typed degraded)\n" + unknown + " reason=facts-unbounded\n" + warning + "\n"
		if stderr != want || len(w.factsIn) != 0 {
			t.Errorf("stderr:\n%q\nwant:\n%q (facts ran: %v)", stderr, want, w.factsIn)
		}
	})
	t.Run("the step reads the input it was given", func(t *testing.T) {
		w := newWorld(t)
		var got string
		w.facts = func(in string, _ time.Duration, _ cli.Stdio) factsResult {
			got = in
			return factsResult{line: goodLine}
		}
		in := w.touch("Test.class")
		w.exec(in, filepath.Join(w.root, "out"))
		if got != in {
			t.Errorf("facts input %q, want %q", got, in)
		}
	})
	t.Run("the timeout warning comes first and only when --timeout > 0", func(t *testing.T) {
		w := newWorld(t)
		w.env["RSDD_TIMEOUT_BIN"] = filepath.Join(w.root, "no-such")
		_, stderr, _ := w.exec(w.touch("Test.class"), filepath.Join(w.root, "out"), "--timeout", "0")
		if strings.Contains(stderr, "UNBOUNDED") || !strings.Contains(stderr, "reason=facts-unbounded") {
			t.Errorf("stderr: %q", stderr)
		}
	})
}

// TestFactsBudget: the facts step has its OWN small budget (old H8-H11, mCF8, mCF9).
func TestFactsBudget(t *testing.T) {
	invalid := func(v string) string {
		return "WARN: invalid RSDD_CLASSFACTS_TIMEOUT=" + v + " (positive seconds); using the derived default\n"
	}
	for _, tt := range []struct {
		name     string
		timeout  string // RSDD_DECOMPILE_TIMEOUT
		override string // RSDD_CLASSFACTS_TIMEOUT
		want     int
		warn     string
	}{
		{"240 s engines: capped at 30", "240", "", 30, ""},
		{"H8 --timeout 16: TIMEOUT/8", "16", "", 2, ""},
		{"31 s is 3", "31", "", 3, ""},
		{"239 s is 29", "239", "", 29, ""},
		{"248 s is 31 capped to 30", "248", "", 30, ""},
		{"never below 1 s", "7", "", 1, ""},
		{"1 s engines", "1", "", 1, ""},
		{"unbounded engines: 30", "0", "", 30, ""},
		{"H9 the override wins", "240", "1", 1, ""},
		{"the override is not capped", "240", "99999", 99999, ""},
		{"a valid override raises it past 30", "240", "45", 45, ""},
		{"six digits is invalid", "240", "100000", 30, invalid("100000")},
		{"zero is invalid", "240", "0", 30, invalid("0")},
		{"a leading zero is invalid", "240", "05", 30, invalid("05")},
		{"H10 text is invalid", "240", "abc", 30, invalid("abc")},
		{"negative is invalid", "240", "-5", 30, invalid("-5")},
		{"with a unit is invalid", "240", "5s", 30, invalid("5s")},
		{"H11 a Unicode digit is invalid", "240", "\u0663", 30, invalid("\u0663")},
		{"an invalid override still derives from the timeout", "16", "abc", 2, invalid("abc")},
	} {
		t.Run(tt.name, func(t *testing.T) {
			w := newWorld(t)
			w.env["RSDD_DECOMPILE_TIMEOUT"], w.env["RSDD_CLASSFACTS_TIMEOUT"] = tt.timeout, tt.override
			_, stderr, _ := w.exec(w.touch("Test.class"), filepath.Join(w.root, "out"))
			if len(w.factsIn) != 1 || w.factsIn[0] != time.Duration(tt.want)*time.Second {
				t.Errorf("budget %v, want %ds", w.factsIn, tt.want)
			}
			if !strings.HasPrefix(stderr, tt.warn+"CLASSFILE ") {
				t.Errorf("stderr %q, want prefix %q", stderr, tt.warn)
			}
		})
	}
}

func TestFactsRunner(t *testing.T) {
	never := func(time.Duration) <-chan time.Time { return nil }
	t.Run("collects the line, the first stderr line and the status", func(t *testing.T) {
		run := func(args []string, s cli.Stdio) int {
			if len(args) != 1 || args[0] != "in.jar" || s.Env("K") != "v" || s.Cwd != "/cwd" {
				t.Errorf("args %v cwd %q", args, s.Cwd)
			}
			s.Out.Write([]byte("line\n\n"))
			s.Err.Write([]byte("first\nsecond\n"))
			return 3
		}
		got := newFactsRunner(run, never)("in.jar", time.Second, cli.Stdio{Env: func(string) string { return "v" }, Cwd: "/cwd"})
		if got != (factsResult{line: "line", firstErr: "first", rc: 3}) {
			t.Errorf("result %+v", got)
		}
	})
	t.Run("only newlines are trimmed from the line", func(t *testing.T) {
		run := func(_ []string, s cli.Stdio) int { s.Out.Write([]byte("truncated=XX\n\n")); return 0 }
		if got := newFactsRunner(run, never)("x", time.Second, cli.Stdio{}); got.line != "truncated=XX" {
			t.Errorf("result %+v", got)
		}
	})
	t.Run("a stderr without a newline is one line", func(t *testing.T) {
		run := func(_ []string, s cli.Stdio) int { s.Err.Write([]byte("only")); return 1 }
		if got := newFactsRunner(run, never)("x", time.Second, cli.Stdio{}); got.firstErr != "only" {
			t.Errorf("result %+v", got)
		}
	})
	t.Run("a step past its budget is abandoned", func(t *testing.T) {
		release := make(chan struct{})
		t.Cleanup(func() { close(release) })
		run := func([]string, cli.Stdio) int { <-release; return 0 }
		var asked time.Duration
		after := func(d time.Duration) <-chan time.Time {
			asked = d
			c := make(chan time.Time, 1)
			c <- time.Time{}
			return c
		}
		got := newFactsRunner(run, after)("x", 7*time.Second, cli.Stdio{})
		if !got.timedOut || asked != 7*time.Second {
			t.Errorf("result %+v, asked %v", got, asked)
		}
	})
	t.Run("a panic is a failed step, as the rsdd panic boundary would make it", func(t *testing.T) {
		run := func([]string, cli.Stdio) int { panic("boom") }
		got := newFactsRunner(run, never)("x", time.Second, cli.Stdio{})
		if got != (factsResult{firstErr: "rsdd: internal-error", rc: 1}) {
			t.Errorf("result %+v", got)
		}
	})
}

// TestFactsRunnerReal runs the production wiring (the in-process classfile command) on a file that is not a class.
func TestFactsRunnerReal(t *testing.T) {
	p := filepath.Join(t.TempDir(), "T.class")
	if err := os.WriteFile(p, []byte("not a class"), 0o644); err != nil {
		t.Fatal(err)
	}
	got := newFactsRunner(classfile.Run, time.After)(p, time.Minute, cli.Stdio{Env: func(string) string { return "" }})
	want := "CLASSFILE major=unknown lvt=unknown classes=1 resugar_risk=unknown unreadable=1 partial=0 truncated=none"
	if got.rc != 0 || got.line != want {
		t.Errorf("result %+v, want line %q", got, want)
	}
}
