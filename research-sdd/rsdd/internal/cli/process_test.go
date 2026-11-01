package cli

import (
	"bytes"
	"errors"
	"os"
	"slices"
	"strings"
	"testing"
)

func TestOSStdioSurfacesGetwdError(t *testing.T) {
	boom := errors.New("getwd boom")
	s, err := osStdio(func() (string, error) { return "", boom })
	if err == nil || !errors.Is(err, boom) {
		t.Fatalf("err = %v, want it to wrap the Getwd error", err)
	}
	if s.Cwd != "" {
		t.Errorf("Cwd must not be fabricated, got %q", s.Cwd)
	}
}

func TestOSStdioReturnsCwd(t *testing.T) {
	s, err := osStdio(func() (string, error) { return "/here", nil })
	if err != nil || s.Cwd != "/here" {
		t.Fatalf("got (%q, %v)", s.Cwd, err)
	}
}

func TestRunProcessGetwdFailureIsOperational(t *testing.T) {
	ran := false
	table := []Command{{Name: "x", Summary: "x", Run: func([]string, Stdio) int { ran = true; return 0 }}}
	var errBuf bytes.Buffer
	code := runProcess(table, []string{"x"}, func() (string, error) { return "", errors.New("gone") }, &errBuf)
	if code != ExitOperational {
		t.Errorf("exit = %d, want %d", code, ExitOperational)
	}
	if !strings.Contains(errBuf.String(), "rsdd: cannot determine working directory") {
		t.Errorf("stderr lacks typed line: %q", errBuf.String())
	}
	if ran {
		t.Error("the command must not run with an unknown cwd")
	}
}

func TestValidateRejectsShadowing(t *testing.T) {
	run := func([]string, Stdio) int { return 0 }
	ok := Command{Name: "a", Group: "g", Summary: "s", Run: run}
	tests := []struct {
		name  string
		table []Command
		want  string
	}{
		{"valid", []Command{ok, {Name: "b", Group: "g", Summary: "s", Run: run}, {Name: "top", Summary: "s", Run: run}}, ""},
		{"duplicate grouped", []Command{ok, ok}, "duplicate"},
		{"duplicate ungrouped", []Command{{Name: "x", Summary: "s", Run: run}, {Name: "x", Summary: "s", Run: run}}, "duplicate"},
		{"group shadows command", []Command{{Name: "g", Summary: "s", Run: run}, ok}, "collides"},
		{"empty name", []Command{{Summary: "s", Run: run}}, "empty name"},
		{"nil run", []Command{{Name: "n", Summary: "s"}}, "no Run"},
		{"ungrouped help alias", []Command{{Name: "help", Summary: "s", Run: run}}, "help"},
		{"ungrouped --help", []Command{{Name: "--help", Summary: "s", Run: run}}, "help"},
		{"ungrouped -h", []Command{{Name: "-h", Summary: "s", Run: run}}, "help"},
		{"grouped help alias", []Command{{Name: "help", Group: "g", Summary: "s", Run: run}}, "help"},
		{"group named help", []Command{{Name: "a", Group: "help", Summary: "s", Run: run}}, "help"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := Validate(tt.table)
			switch {
			case tt.want == "" && err != nil:
				t.Fatalf("unexpected error: %v", err)
			case tt.want != "" && (err == nil || !strings.Contains(err.Error(), tt.want)):
				t.Fatalf("err = %v, want it to mention %q", err, tt.want)
			}
		})
	}
}

func TestRunRefusesInvalidTable(t *testing.T) {
	run := func([]string, Stdio) int { return 0 }
	table := []Command{{Name: "x", Summary: "s", Run: run}, {Name: "x", Summary: "s", Run: run}}
	var out, errBuf bytes.Buffer
	code := Run(table, []string{"x"}, Stdio{Out: &out, Err: &errBuf})
	if code != ExitOperational || !strings.Contains(errBuf.String(), "rsdd: invalid command table") {
		t.Errorf("got (%d, %q), want exit 1 and the typed line", code, errBuf.String())
	}
}

// #2387: the boundary hands commands the whole environment list for child processes, as os.Environ
// returns it, so no package below cli needs os.Environ.
func TestOSStdioCarriesEnviron(t *testing.T) {
	t.Setenv("RSDD_STDIO_ENVIRON_PROBE", "x=y")
	s, err := osStdio(func() (string, error) { return "/here", nil })
	if err != nil {
		t.Fatal(err)
	}
	if s.Environ == nil {
		t.Fatal("Stdio.Environ is nil")
	}
	got := s.Environ()
	if !slices.Contains(got, "RSDD_STDIO_ENVIRON_PROBE=x=y") {
		t.Fatalf("Environ() lacks the probe variable: %d entries", len(got))
	}
	if !slices.Equal(got, os.Environ()) {
		t.Fatal("Environ() differs from the process environment")
	}
}
