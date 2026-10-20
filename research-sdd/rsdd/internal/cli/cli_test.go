package cli_test

import (
	"bytes"
	"strings"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
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
			return cli.ExitFindings
		}},
		{Name: "boom", Group: "verify", Summary: "panics", Run: func([]string, cli.Stdio) int {
			panic("kaboom")
		}},
	}
}

func TestPanicBoundary(t *testing.T) {
	code, out, errOut := run(t, testTable(), "verify", "boom")
	if code != 2 {
		t.Errorf("exit = %d, want 2", code)
	}
	if !strings.Contains(errOut, "degraded: internal-error") {
		t.Errorf("stderr missing typed reason: %q", errOut)
	}
	if out != "" {
		t.Errorf("stdout must stay empty on panic, got %q", out)
	}
	if strings.Contains(out+errOut, "goroutine ") {
		t.Errorf("Go stack trace leaked: %q", out+errOut)
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
		{"grouped passes args and exit code", []string{"verify", "block", "a", "b"}, 1, "block a,b\n"},
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
