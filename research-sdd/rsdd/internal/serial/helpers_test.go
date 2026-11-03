package serial

import (
	"bytes"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

func testStdio(cwd string) (cli.Stdio, *bytes.Buffer, *bytes.Buffer) {
	var out, errb bytes.Buffer
	return cli.Stdio{
		In: strings.NewReader(""), Out: &out, Err: &errb,
		Env:     func(string) string { return "" },
		Environ: func() []string { return nil },
		Clock:   time.Now, Cwd: cwd,
	}, &out, &errb
}

// runCmd runs a command in process and bounds it: a hang is a test failure, not a stuck suite.
func runCmd(t *testing.T, run func([]string, cli.Stdio) int, args ...string) (rc int, stdout, stderr string) {
	t.Helper()
	s, out, errb := testStdio(t.TempDir())
	done := make(chan int, 1)
	go func() { done <- run(args, s) }()
	select {
	case rc = <-done:
	case <-time.After(30 * time.Second):
		t.Fatalf("%v did not finish within 30s", args)
	}
	return rc, out.String(), errb.String()
}

func analyze(t *testing.T, args ...string) (rc int, stdout, stderr string) {
	t.Helper()
	return runCmd(t, SerialFrameAnalyze, args...)
}

// abs makes a package-relative testdata path absolute.
func abs(t *testing.T, p string) string {
	t.Helper()
	a, err := filepath.Abs(p)
	if err != nil {
		t.Fatal(err)
	}
	return a
}

// obj and arr read a decoded JSON value without panicking, so a missing document fails an assertion with a
// message instead of crashing the whole test binary.
func obj(v any) map[string]any {
	m, _ := v.(map[string]any)
	if m == nil {
		m = map[string]any{}
	}
	return m
}

func arr(v any) []any {
	a, _ := v.([]any)
	return a
}
