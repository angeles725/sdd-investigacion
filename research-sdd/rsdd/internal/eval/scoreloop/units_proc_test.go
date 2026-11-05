package scoreloop

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/proc"
)

// Guard-to-test table:
//   statusRunnerWith stdout trim, rc, stderr ..... TestStatusRunner
//   statusRunnerWith bash missing, timeout, cap .. TestStatusRunnerProblems
//   exitCode, firstLine, runProblem .............. TestExitCode, TestFirstLine, TestRunProblem
//   statusScriptPath precedence .................. TestStatusScriptPath
//   readable ..................................... TestReadable
//   jqRunnerWith missing, failure, cap ........... TestJQRunner
//   parseVerdicts, jqProgram, setJQFailure ....... TestParseVerdicts, TestJQProgram, TestSetJQFailure

func writeScript(t *testing.T, body string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "s.sh")
	if err := os.WriteFile(p, []byte("#!/usr/bin/env bash\n"+body), 0o644); err != nil {
		t.Fatal(err)
	}
	return p
}

var hostEnv = []string{"PATH=" + os.Getenv("PATH")}

func TestStatusRunner(t *testing.T) {
	script := writeScript(t, `if [ "${2:-}" = "--next" ]; then echo "STOP | x"; echo "n-err" >&2; exit 4; fi
printf 'line1\nline2\n\n\n'; echo "d-err1" >&2; echo "d-err2" >&2
`)
	out := statusRunnerWith(hostEnv, time.Minute, 1<<20)(script, "corpus-dir")
	if out.problem != "" || out.def != "line1\nline2" || out.next != "STOP | x" || out.rcDef != 0 || out.rcNext != 4 {
		t.Errorf("outcome: %+v", out)
	}
	if out.stderrFirstLine != "d-err1" {
		t.Errorf("the first stderr line comes from the first run: %q", out.stderrFirstLine)
	}
	// The corpus is the first argument after the script; the signal exit is the shell's 128+N.
	killed := writeScript(t, `echo "$1" > "$(dirname "$0")/corpus-arg"; kill -9 $$`)
	out = statusRunnerWith(hostEnv, time.Minute, 1<<20)(killed, "the-corpus")
	if out.rcDef != 137 || out.rcNext != 137 {
		t.Errorf("signal exit codes: %+v", out)
	}
	if b, _ := os.ReadFile(filepath.Join(filepath.Dir(killed), "corpus-arg")); string(b) != "the-corpus\n" {
		t.Errorf("corpus argument %q", b)
	}
}

func TestStatusRunnerProblems(t *testing.T) {
	ok := writeScript(t, "echo fine\n")
	out := statusRunnerWith([]string{"PATH=" + t.TempDir()}, time.Minute, 1<<20)(ok, "c")
	if out.problem != "bash not found in PATH — cannot run research-sdd-status.sh" {
		t.Errorf("bash missing: %q", out.problem)
	}
	slow := writeScript(t, "sleep 30\n")
	start := time.Now()
	out = statusRunnerWith(hostEnv, 300*time.Millisecond, 1<<20)(slow, "c")
	if out.problem != "research-sdd-status.sh stopped (timeout)" || time.Since(start) > 20*time.Second {
		t.Errorf("timeout: %q after %v", out.problem, time.Since(start))
	}
	loud := writeScript(t, "head -c 100000 /dev/zero | tr '\\0' x\n")
	out = statusRunnerWith(hostEnv, time.Minute, 1024)(loud, "c")
	if out.problem != "research-sdd-status.sh stopped (output-cap)" {
		t.Errorf("output cap: %q", out.problem)
	}
}

func TestRunProblem(t *testing.T) {
	if got := runProblem(proc.Result{}, nil); got != "" {
		t.Errorf("clean run: %q", got)
	}
	if got := runProblem(proc.Result{ReturnCode: 3}, nil); got != "" {
		t.Errorf("a non-zero exit is the caller's to judge: %q", got)
	}
	if got := runProblem(proc.Result{}, fmt.Errorf("lookup: %w", exec.ErrNotFound)); got != "bash not found in PATH — cannot run research-sdd-status.sh" {
		t.Errorf("not found: %q", got)
	}
	if got := runProblem(proc.Result{}, errors.New("boom")); got != "cannot run research-sdd-status.sh: boom" {
		t.Errorf("spawn failure: %q", got)
	}
	if got := runProblem(proc.Result{Reason: proc.ReasonTimeout}, nil); got != "research-sdd-status.sh stopped (timeout)" {
		t.Errorf("stopped: %q", got)
	}
}

func TestExitCode(t *testing.T) {
	for in, want := range map[int]int{0: 0, 1: 1, 126: 126, -9: 137, -15: 143, -1: 129} {
		if got := exitCode(in); got != want {
			t.Errorf("exitCode(%d) = %d, want %d", in, got, want)
		}
	}
}

func TestFirstLine(t *testing.T) {
	for _, c := range []struct {
		in   string
		max  int
		want string
	}{{"", 5, ""}, {"abc", 5, "abc"}, {"abcde", 5, "abcde"}, {"abcdef", 5, "abcde"}, {"ab\ncd", 5, "ab"}, {"\nabc", 5, ""}, {"abcdefgh\nx", 3, "abc"}} {
		if got := firstLine(c.in, c.max); got != c.want {
			t.Errorf("firstLine(%q, %d) = %q, want %q", c.in, c.max, got, c.want)
		}
	}
}

func TestStatusScriptPath(t *testing.T) {
	getenv := envMap()
	cfg := &Config{StatusEnv: "/env/status.sh"}
	if got := statusScriptPath(cfg, options{toolbelt: "/tb"}, getenv); got != "/env/status.sh" {
		t.Errorf("RSDD_STATUS_SCRIPT wins: %q", got)
	}
	if got := statusScriptPath(&Config{}, options{toolbelt: "/tb/"}, getenv); got != "/tb/research-sdd-status.sh" {
		t.Errorf("--toolbelt: %q", got)
	}
	kit := t.TempDir()
	if err := os.MkdirAll(filepath.Join(kit, "toolbelt"), 0o755); err != nil {
		t.Fatal(err)
	}
	script := filepath.Join(kit, "toolbelt", "research-sdd-status.sh")
	if err := os.WriteFile(script, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	if got := statusScriptPath(&Config{}, options{}, envMap("RESEARCH_SDD_KIT", kit)); got != script {
		t.Errorf("kit resolution: %q", got)
	}
	empty := t.TempDir()
	if got := statusScriptPath(&Config{}, options{}, envMap("RESEARCH_SDD_KIT", empty, "HOME", empty)); got != "<kit>/toolbelt/research-sdd-status.sh" {
		t.Errorf("unresolved: %q", got)
	}
}

func TestReadable(t *testing.T) {
	dir := t.TempDir()
	file := filepath.Join(dir, "f")
	if err := os.WriteFile(file, nil, 0o644); err != nil {
		t.Fatal(err)
	}
	if !readable(file) || !readable(dir) || readable(filepath.Join(dir, "nope")) {
		t.Error("readable: a file and a directory open, a missing path does not")
	}
}

func TestJQProgram(t *testing.T) {
	p := jqProgram(&Config{})
	if !strings.Contains(p, defaultOperatorJQ) || !strings.Contains(p, defaultCompactJQ) {
		t.Errorf("defaults missing: %s", p)
	}
	p = jqProgram(&Config{OperatorJQ: ".op", CompactJQ: ".cx"})
	if !strings.Contains(p, "[ (.op) ]") || !strings.Contains(p, "[ (.cx) ]") || strings.Contains(p, defaultOperatorJQ) {
		t.Errorf("overrides missing: %s", p)
	}
	p = jqProgram(&Config{OperatorJQ: ".op"})
	if !strings.Contains(p, defaultCompactJQ) {
		t.Errorf("an unset filter keeps its default: %s", p)
	}
}

func TestParseVerdicts(t *testing.T) {
	v, err := parseVerdicts([]byte(`[{"i":0,"op":[true],"cx":[false]},{"i":2,"op":[false],"cx":[true]},{"i":3,"op":[],"cx":[true]},{"i":4,"op":["x"],"cx":[1]},{"i":5,"op":[true],"cx":[]}]`))
	if err != nil || len(v) != 3 || !v[0].operator || v[0].compact || v[2].operator || !v[2].compact || v[4].operator || v[4].compact {
		t.Errorf("verdicts %+v, %v", v, err)
	}
	if _, ok := v[3]; ok {
		t.Error("a filter with no output drops its record")
	}
	if _, ok := v[5]; ok {
		t.Error("a filter with no output drops its record (compaction side)")
	}
	if _, err := parseVerdicts([]byte(`[{"i":0,"op":[true,true],"cx":[true]}]`)); err == nil {
		t.Error("several operator values accepted")
	}
	if _, err := parseVerdicts([]byte(`[{"i":0,"op":[true],"cx":[true,false]}]`)); err == nil {
		t.Error("several compaction values accepted")
	}
	if _, err := parseVerdicts([]byte(`not json`)); err == nil {
		t.Error("garbage accepted")
	}
}

func TestJQRunner(t *testing.T) {
	file := filepath.Join(t.TempDir(), "t.jsonl")
	if err := os.WriteFile(file, []byte(`{"type":"user","timestamp":"2026-06-01T00:00:00Z","origin":{"kind":"human"}}`+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	cfg := &Config{CompactJQ: ".isCompactSummary // false"}
	v, err := jqRunnerWith(hostEnv, time.Minute, 1<<20)(file, cfg)
	if err != nil || len(v) != 1 || !v[0].operator || v[0].compact {
		t.Errorf("verdicts %+v, %v", v, err)
	}
	if _, err := jqRunnerWith([]string{"PATH=" + t.TempDir()}, time.Minute, 1<<20)(file, cfg); err != errJQMissing {
		t.Errorf("jq missing: %v", err)
	}
	if _, err := jqRunnerWith(hostEnv, time.Minute, 1<<20)(file, &Config{CompactJQ: ".x |"}); err == nil || err == errJQMissing {
		t.Errorf("an invalid program fails: %v", err)
	}
	if _, err := jqRunnerWith(hostEnv, time.Minute, 4)(file, cfg); err == nil || err == errJQMissing {
		t.Errorf("the output cap fails: %v", err)
	}
	if _, err := jqRunnerWith(hostEnv, time.Minute, 1<<20)(filepath.Join(t.TempDir(), "missing"), cfg); err == nil {
		t.Error("an unreadable transcript fails")
	}
}

func TestSetJQFailure(t *testing.T) {
	var f Facts
	f.setJQFailure(errJQMissing)
	if f.MissingTool != "jq" || f.ParseFailed {
		t.Errorf("missing: %+v", f)
	}
	f = Facts{}
	f.setJQFailure(os.ErrClosed)
	if f.MissingTool != "" || !f.ParseFailed {
		t.Errorf("failed: %+v", f)
	}
}
