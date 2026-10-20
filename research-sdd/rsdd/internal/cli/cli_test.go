package cli_test

import (
	"bytes"
	"errors"
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

type failWriter struct{}

func (failWriter) Write([]byte) (int, error) { return 0, errors.New("broken pipe") }

// A failed release of the buffered stdout is an operational failure: exit 1
// plus a typed stderr line, whatever code the command returned.
func TestStdoutWriteFailureIsOperational(t *testing.T) {
	for _, ret := range []int{cli.ExitOK, cli.ExitDegraded} {
		table := []cli.Command{{Name: "w", Summary: "x", Run: func(_ []string, s cli.Stdio) int {
			s.Out.Write([]byte("result\n"))
			return ret
		}}}
		var e bytes.Buffer
		s := cli.Stdio{In: strings.NewReader(""), Out: failWriter{}, Err: &e,
			Env: func(string) string { return "" }, Clock: time.Now, Cwd: "/work"}
		code := cli.Run(table, []string{"w"}, s)
		if code != cli.ExitOperational {
			t.Errorf("ret=%d: exit = %d, want %d", ret, code, cli.ExitOperational)
		}
		if !strings.Contains(e.String(), "rsdd: stdout-write-failed: broken pipe") {
			t.Errorf("ret=%d: stderr = %q, want the typed stdout-write-failed line", ret, e.String())
		}
	}
}

// Precedence: ExitMap translates the code Run returned, then the degraded
// contract judges the FINAL code. A degraded 3 is never remapped unless the
// map explicitly lists 3; a command that maps onto 3 gets the DEGRADED: line.
func TestExitMapDegradedPrecedence(t *testing.T) {
	deg := func([]string, cli.Stdio) int { return cli.ExitDegraded }
	table := []cli.Command{
		{Name: "unmapped", Summary: "x", ExitMap: map[int]int{1: 0}, Run: deg},
		{Name: "remapped", Summary: "x", ExitMap: map[int]int{3: 1}, Run: deg},
		{Name: "tothree", Summary: "x", ExitMap: map[int]int{10: 3},
			Run: func([]string, cli.Stdio) int { return 10 }},
	}
	code, _, errOut := run(t, table, "unmapped")
	if code != 3 || !strings.Contains(errOut, "DEGRADED:") {
		t.Errorf("unmapped: got (%d, %q), want 3 with DEGRADED: line", code, errOut)
	}
	if code, _, _ = run(t, table, "remapped"); code != 1 {
		t.Errorf("remapped: exit = %d, want 1 (map lists 3 explicitly)", code)
	}
	code, _, errOut = run(t, table, "tothree")
	if code != 3 || !strings.Contains(errOut, "DEGRADED:") {
		t.Errorf("tothree: got (%d, %q), want 3 with DEGRADED: line", code, errOut)
	}
}

// The DEGRADED: contract is about LINES of stderr: a line split across writes
// still counts, and the marker in the middle of a line does not.
func TestDegradedMarkerIsJudgedPerLine(t *testing.T) {
	split := cli.Command{Name: "split", Summary: "x", Run: func(_ []string, s cli.Stdio) int {
		s.Err.Write([]byte("DEGRA"))
		s.Err.Write([]byte("DED: jq missing\n"))
		return cli.ExitDegraded
	}}
	unterminated := cli.Command{Name: "unterminated", Summary: "x", Run: func(_ []string, s cli.Stdio) int {
		s.Err.Write([]byte("DEGRADED: jq missing"))
		return cli.ExitDegraded
	}}
	midline := cli.Command{Name: "midline", Summary: "x", Run: func(_ []string, s cli.Stdio) int {
		s.Err.Write([]byte("note: DEGRADED: only quoted\n"))
		return cli.ExitDegraded
	}}
	afterShort := cli.Command{Name: "aftershort", Summary: "x", Run: func(_ []string, s cli.Stdio) int {
		s.Err.Write([]byte("x\nDEGRADED: jq missing\n"))
		return cli.ExitDegraded
	}}
	table := []cli.Command{split, unterminated, midline, afterShort}
	for name, want := range map[string]int{"split": 1, "unterminated": 1, "midline": 2, "aftershort": 1} {
		code, _, errOut := run(t, table, name)
		if code != 3 || strings.Count(errOut, "DEGRADED:") != want {
			t.Errorf("%s: got (%d, %q), want exit 3 and %d DEGRADED: marker(s)", name, code, errOut, want)
		}
	}
}

// A bare group name is a usage error that lists the group's commands on
// stderr and prints nothing on stdout.
func TestBareGroupIsUsageErrorWithGroupHelp(t *testing.T) {
	code, out, errOut := run(t, testTable(), "verify")
	if code != cli.ExitUsage || out != "" {
		t.Fatalf("got (%d, %q), want (2, empty stdout)", code, out)
	}
	if !strings.Contains(errOut, "rsdd verify <command>") || !strings.Contains(errOut, "verify a block") {
		t.Errorf("stderr lacks the group usage: %q", errOut)
	}
}

func TestValidateDuplicateIsTyped(t *testing.T) {
	run := func([]string, cli.Stdio) int { return 0 }
	err := cli.Validate([]cli.Command{{Name: "n", Group: "g", Run: run}, {Name: "n", Group: "g", Run: run}})
	var dup *cli.DuplicateError
	if !errors.As(err, &dup) || dup.Group != "g" || dup.Name != "n" {
		t.Fatalf("err = %v, want *DuplicateError{g, n}", err)
	}
}
