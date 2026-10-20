// Package golden runs `testdata/golden/<case>/` directories against a Main
// function. Each case holds cmd.json, stdin, stdout, stderr, exit and
// intended.json; a case missing any of them FAILS (never skipped), and so
// does a golden directory with no cases (anti-silent-zero).
package golden

import (
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

var update = flag.Bool("update", false, "rewrite golden stdout/stderr/exit files from the actual run")

// Fixed ambient values every case runs under.
const fixedCwd = "/work"

var fixedClock = time.Date(2000, 1, 1, 0, 0, 0, 0, time.UTC)

var requiredFiles = []string{"cmd.json", "stdin", "stdout", "stderr", "exit", "intended.json"}

type cmdSpec struct {
	Args []string          `json:"args"`
	Env  map[string]string `json:"env"`
}

// Run executes every case directory under dir as a subtest.
func Run(t *testing.T, dir string, main func([]string, cli.Stdio) int) {
	t.Helper()
	cases, err := listCases(dir)
	if err != nil {
		t.Fatal(err)
	}
	for _, c := range cases {
		t.Run(filepath.Base(c), func(t *testing.T) {
			for _, p := range runCase(c, main, *update) {
				t.Error(p)
			}
		})
	}
}

func listCases(dir string) ([]string, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, fmt.Errorf("golden: cannot read case dir %s: %w", dir, err)
	}
	var out []string
	for _, e := range entries {
		if e.IsDir() {
			out = append(out, filepath.Join(dir, e.Name()))
		}
	}
	if len(out) == 0 {
		return nil, fmt.Errorf("golden: no cases under %s (an empty corpus proves nothing)", dir)
	}
	sort.Strings(out)
	return out, nil
}

// runCase returns the list of problems; empty means the case passed.
func runCase(dir string, main func([]string, cli.Stdio) int, rewrite bool) []string {
	var problems []string
	for _, f := range requiredFiles {
		if _, err := os.Stat(filepath.Join(dir, f)); err != nil {
			problems = append(problems, fmt.Sprintf("%s: required file %s missing or unreadable: %v", dir, f, err))
		}
	}
	if len(problems) > 0 {
		return problems
	}
	read := func(f string) []byte {
		b, err := os.ReadFile(filepath.Join(dir, f))
		if err != nil {
			problems = append(problems, fmt.Sprintf("%s: %v", dir, err))
		}
		return b
	}
	var spec cmdSpec
	if err := strictJSON(read("cmd.json"), &spec); err != nil {
		return append(problems, fmt.Sprintf("%s: cmd.json: %v", dir, err))
	}
	if err := validateIntended(read("intended.json")); err != nil {
		return append(problems, fmt.Sprintf("%s: intended.json: %v", dir, err))
	}

	var out, errOut bytes.Buffer
	s := cli.Stdio{
		In:    bytes.NewReader(read("stdin")),
		Out:   &out,
		Err:   &errOut,
		Env:   func(k string) string { return spec.Env[k] },
		Clock: func() time.Time { return fixedClock },
		Cwd:   fixedCwd,
	}
	code := main(spec.Args, s)

	if rewrite {
		w := func(f string, b []byte) {
			if err := os.WriteFile(filepath.Join(dir, f), b, 0o644); err != nil {
				problems = append(problems, fmt.Sprintf("%s: update %s: %v", dir, f, err))
			}
		}
		w("stdout", out.Bytes())
		w("stderr", errOut.Bytes())
		w("exit", []byte(strconv.Itoa(code)+"\n"))
		return problems
	}

	if want := read("stdout"); !bytes.Equal(want, out.Bytes()) {
		problems = append(problems, fmt.Sprintf("%s: stdout mismatch\n  want %q\n  got  %q", dir, want, out.Bytes()))
	}
	if want := read("stderr"); !bytes.Equal(want, errOut.Bytes()) {
		problems = append(problems, fmt.Sprintf("%s: stderr mismatch\n  want %q\n  got  %q", dir, want, errOut.Bytes()))
	}
	want, err := strconv.Atoi(strings.TrimSpace(string(read("exit"))))
	switch {
	case err != nil:
		problems = append(problems, fmt.Sprintf("%s: exit file is not an integer: %v", dir, err))
	case want != code:
		problems = append(problems, fmt.Sprintf("%s: exit mismatch: want %d, got %d", dir, want, code))
	}
	return problems
}

func strictJSON(b []byte, v any) error {
	d := json.NewDecoder(bytes.NewReader(b))
	d.DisallowUnknownFields()
	return d.Decode(v)
}

type intended struct {
	Field  string `json:"field"`
	Reason string `json:"reason"`
}

// validateIntended enforces the intended.json schema: a list of
// {field, reason} where field is stdout|stderr|exit and reason is non-blank.
func validateIntended(b []byte) error {
	var list []intended
	if err := strictJSON(b, &list); err != nil {
		return err
	}
	for i, e := range list {
		switch e.Field {
		case "stdout", "stderr", "exit":
		default:
			return fmt.Errorf("entry %d: field %q is not one of stdout|stderr|exit", i, e.Field)
		}
		if strings.TrimSpace(e.Reason) == "" {
			return fmt.Errorf("entry %d (%s): every intended divergence needs a non-empty reason", i, e.Field)
		}
	}
	return nil
}
