package ensureremote

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/proc"
)

func TestExitStatus(t *testing.T) {
	for _, tt := range []struct {
		name string
		res  proc.Result
		want int
	}{
		{"zero", proc.Result{}, 0},
		{"three", proc.Result{ReturnCode: 3}, 3},
		{"bound-hit", proc.Result{Reason: proc.ReasonTimeout, ReturnCode: -9}, 124},
		{"signal", proc.Result{ReturnCode: -15}, 143},
		{"killed", proc.Result{ReturnCode: -9}, 137},
		{"output-cap-never-success", proc.Result{Reason: proc.ReasonOutputCap}, 1},
		{"output-cap-keeps-failure", proc.Result{Reason: proc.ReasonOutputCap, ReturnCode: 5}, 5},
	} {
		if got := exitStatus(tt.res); got != tt.want {
			t.Errorf("%s: %d, want %d", tt.name, got, tt.want)
		}
	}
}

func TestProcRun(t *testing.T) {
	sh := []string{"sh", "-c"}
	env := []string{"PATH=/bin:/usr/bin"}
	run := func(script string, timeout time.Duration) Out {
		return procRun(Cmd{Argv: append(append([]string{}, sh...), script), Env: env, Timeout: timeout})
	}
	if o := run("printf out; printf err >&2; exit 4", time.Minute); o.RC != 4 || string(o.Stdout) != "out" || string(o.Stderr) != "err" || o.Err != nil {
		t.Errorf("%+v", o)
	}
	if o := run("exit 0", time.Minute); o.RC != 0 {
		t.Errorf("%+v", o)
	}
	if o := run("exec sleep 30", 100*time.Millisecond); o.RC != 124 {
		t.Errorf("a run past its bound reads as 124: %+v", o)
	}
	o := procRun(Cmd{Argv: []string{"definitely-not-installed-xyz"}, Env: env, Timeout: time.Minute})
	if o.RC != 127 || o.Err == nil {
		t.Errorf("an unstartable program is 127 with its error: %+v", o)
	}
	if o := procRun(Cmd{Argv: []string{"sh", "-c", "exit 0"}, Env: env}); o.RC != 127 || o.Err == nil {
		t.Errorf("an invalid spec (no timeout) is refused, never run unbounded: %+v", o)
	}
}

func TestOnPath(t *testing.T) {
	dir := t.TempDir()
	os.WriteFile(filepath.Join(dir, "gh"), []byte("#!/bin/sh\n"), 0o755)
	os.WriteFile(filepath.Join(dir, "plain"), []byte("x"), 0o644)
	os.Mkdir(filepath.Join(dir, "adir"), 0o755)
	env := []string{"HOME=/x", "PATH=/nonexistent:" + dir}
	for name, want := range map[string]bool{"gh": true, "plain": false, "adir": false, "missing": false} {
		if got := onPath(name, env); got != want {
			t.Errorf("onPath(%q) = %v, want %v", name, got, want)
		}
	}
	if onPath("gh", []string{"PATH=/nonexistent"}) || onPath("definitely-not-installed-xyz", nil) {
		t.Error("a name absent from PATH must not be found")
	}
	if !onPath("gh", []string{"PATH=" + dir, "PATH=/nonexistent:" + dir}) {
		t.Error("the last PATH entry wins")
	}
}

func TestRunWiresTheRealDependencies(t *testing.T) {
	var out, errb bytes.Buffer
	s := cli.Stdio{Out: &out, Err: &errb, Cwd: t.TempDir(), Env: func(string) string { return "" }, Environ: func() []string { return nil }}
	if rc := Run([]string{"--bogus"}, s); rc != 2 || errb.String() != "unknown flag: --bogus\n" {
		t.Errorf("rc=%d err=%q", rc, errb.String())
	}
	if d := realDeps(); d.run == nil || d.gh.Run == nil || d.gh.Probe == nil || d.hasTool == nil {
		t.Error("realDeps leaves a seam unset")
	}
}

func TestOnPathEmptyElementIsTheCurrentDirectory(t *testing.T) {
	dir := t.TempDir()
	os.WriteFile(filepath.Join(dir, "gh"), []byte("#!/bin/sh\n"), 0o755)
	t.Chdir(dir)
	if !onPath("gh", []string{"PATH=/nonexistent::/also-missing"}) {
		t.Error("an empty PATH element means the current directory")
	}
}
