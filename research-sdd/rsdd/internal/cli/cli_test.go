package cli_test

import (
	"bytes"
	"strings"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/testkit/golden"
)

func run(t *testing.T, table []cli.Command, args ...string) (code int, out, errOut string) {
	t.Helper()
	var o, e bytes.Buffer
	s := cli.Stdio{
		In:    strings.NewReader(""),
		Out:   &o,
		Err:   &e,
		Env:   func(string) string { return "" },
		Clock: func() time.Time { return time.Unix(0, 0).UTC() },
		Cwd:   "/work",
	}
	return cli.Run(table, args, s), o.String(), e.String()
}

func testTable() []cli.Command {
	return []cli.Command{
		{Name: "ok", Summary: "prints ok", Run: func(_ []string, s cli.Stdio) int {
			s.Out.Write([]byte("ok\n"))
			return cli.ExitOK
		}},
		{Name: "block", Group: "verify", Summary: "verify a block", Run: func(a []string, s cli.Stdio) int {
			s.Out.Write([]byte("block " + strings.Join(a, ",") + "\n"))
			return cli.ExitOK
		}},
		{Name: "boom", Group: "verify", Summary: "panics", Run: func([]string, cli.Stdio) int {
			panic("kaboom")
		}},
	}
}

func TestPanicIsOperationalFailureNotDegraded(t *testing.T) {
	code, out, errOut := run(t, testTable(), "verify", "boom")
	if code != cli.ExitOperational {
		t.Errorf("exit = %d, want %d (operational failure)", code, cli.ExitOperational)
	}
	if !strings.Contains(errOut, "rsdd: internal-error") {
		t.Errorf("stderr missing typed line: %q", errOut)
	}
	if strings.Contains(errOut, "degraded") || strings.Contains(errOut, "DEGRADED") {
		t.Errorf("a panic is not a degraded state: %q", errOut)
	}
	if out != "" {
		t.Errorf("stdout must stay empty on panic, got %q", out)
	}
	if strings.Contains(out+errOut, "goroutine ") {
		t.Errorf("Go stack trace leaked: %q", out+errOut)
	}
}

// A command that wrote part of its stdout and then panicked must not leave
// that fragment looking like a complete result. Stdout is buffered per
// command and discarded on panic; the cost is that a command's stdout appears
// only when it returns (rsdd commands emit one report, not a stream).
func TestPanicDiscardsPartialStdout(t *testing.T) {
	table := []cli.Command{{Name: "half", Summary: "x", Run: func(_ []string, s cli.Stdio) int {
		s.Out.Write([]byte("partial"))
		s.Err.Write([]byte("progress\n"))
		panic("mid-write")
	}}}
	code, out, errOut := run(t, table, "half")
	if code != 1 || out != "" {
		t.Errorf("got (%d, %q), want (1, empty stdout)", code, out)
	}
	if !strings.Contains(errOut, "rsdd: internal-error") || !strings.Contains(errOut, "progress") {
		t.Errorf("stderr should keep progress and add the typed line: %q", errOut)
	}
}

func TestExitMapTranslatesLegacyContract(t *testing.T) {
	table := []cli.Command{
		{Name: "stale", Summary: "legacy: 1 = stale", ExitMap: map[int]int{10: 1},
			Run: func([]string, cli.Stdio) int { return 10 }},
		{Name: "fresh", Summary: "legacy: 1 = stale", ExitMap: map[int]int{10: 1},
			Run: func([]string, cli.Stdio) int { return 0 }},
		{Name: "plain", Summary: "no map", Run: func([]string, cli.Stdio) int { return 10 }},
	}
	for name, want := range map[string]int{"stale": 1, "fresh": 0, "plain": 10} {
		if code, _, _ := run(t, table, name); code != want {
			t.Errorf("%s: exit = %d, want %d", name, code, want)
		}
	}
}

func TestDegradedExitCarriesDEGRADEDLine(t *testing.T) {
	table := []cli.Command{
		{Name: "silent", Summary: "x", Run: func([]string, cli.Stdio) int { return cli.ExitDegraded }},
		{Name: "typed", Summary: "x", Run: func(_ []string, s cli.Stdio) int {
			s.Err.Write([]byte("DEGRADED: jq missing\n"))
			return cli.ExitDegraded
		}},
	}
	code, _, errOut := run(t, table, "silent")
	if code != 3 || !strings.Contains(errOut, "DEGRADED:") {
		t.Errorf("silent degraded: got (%d, %q), want exit 3 and a DEGRADED: line", code, errOut)
	}
	code, _, errOut = run(t, table, "typed")
	if code != 3 || strings.Count(errOut, "DEGRADED:") != 1 {
		t.Errorf("typed degraded: got (%d, %q), want exit 3 and exactly one DEGRADED: line", code, errOut)
	}
}

func TestUsageErrorsExit2(t *testing.T) {
	for _, args := range [][]string{nil, {"nope"}, {"verify"}, {"verify", "nope"}} {
		if code, _, _ := run(t, testTable(), args...); code != cli.ExitUsage {
			t.Errorf("%v: exit = %d, want %d", args, code, cli.ExitUsage)
		}
	}
}

func TestDispatch(t *testing.T) {
	tests := []struct {
		name     string
		args     []string
		wantCode int
		wantOut  string
	}{
		{"ungrouped", []string{"ok"}, 0, "ok\n"},
		{"grouped passes args and exit code", []string{"verify", "block", "a", "b"}, 0, "block a,b\n"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			code, out, _ := run(t, testTable(), tt.args...)
			if code != tt.wantCode || out != tt.wantOut {
				t.Errorf("got (%d, %q), want (%d, %q)", code, out, tt.wantCode, tt.wantOut)
			}
		})
	}
}

func TestUnknownCommand(t *testing.T) {
	for _, args := range [][]string{{"nope"}, {"verify", "nope"}} {
		code, out, errOut := run(t, testTable(), args...)
		if code != 2 || out != "" {
			t.Errorf("%v: got (%d, %q), want (2, empty stdout)", args, code, out)
		}
		if !strings.Contains(errOut, "unknown command") || !strings.Contains(errOut, "--help") {
			t.Errorf("%v: stderr lacks unknown-command hint: %q", args, errOut)
		}
	}
}

func TestHelpGeneratedFromTable(t *testing.T) {
	code, out, _ := run(t, testTable(), "--help")
	if code != 0 {
		t.Fatalf("exit = %d, want 0", code)
	}
	for _, want := range []string{"ok", "prints ok", "verify", "block", "verify a block"} {
		if !strings.Contains(out, want) {
			t.Errorf("--help missing %q:\n%s", want, out)
		}
	}
	code, out, _ = run(t, testTable(), "verify", "--help")
	if code != 0 {
		t.Fatalf("group help exit = %d, want 0", code)
	}
	if !strings.Contains(out, "block") || !strings.Contains(out, "boom") || strings.Contains(out, "prints ok") {
		t.Errorf("group help must list only the group's commands:\n%s", out)
	}
}

func TestNoArgsPrintsUsageAndExits2(t *testing.T) {
	code, out, errOut := run(t, testTable())
	if code != 2 || out != "" {
		t.Errorf("got (%d, %q), want (2, empty stdout)", code, out)
	}
	if !strings.Contains(errOut, "Usage:") {
		t.Errorf("stderr lacks usage: %q", errOut)
	}
}

func TestGolden(t *testing.T) {
	golden.Run(t, "testdata/golden", func(a []string, s cli.Stdio) int { return cli.Run(testTable(), a, s) })
}
