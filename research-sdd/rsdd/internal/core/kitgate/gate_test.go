package kitgate

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/kitmaint"
)

type env struct {
	t         *testing.T
	root, wt  string
	state     string
	out       bytes.Buffer
	runner    *kitmaint.Runner
	probed    int
	probeSays bool
}

func newEnv(t *testing.T) *env {
	t.Helper()
	root, err := os.MkdirTemp("/tmp", "kg")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(root) })
	e := &env{t: t, root: root, wt: filepath.Join(root, "wt"), state: filepath.Join(root, "state"), probeSays: true}
	if err := os.MkdirAll(e.wt, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, a := range [][]string{{"init", "-q"}, {"-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "c"}} {
		c := exec.Command("git", append([]string{"-C", e.wt}, a...)...)
		c.Env = []string{"PATH=/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM=1", "GIT_CONFIG_GLOBAL=/dev/null"}
		if out, err := c.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v %s", a, err, out)
		}
	}
	e.runner = &kitmaint.Runner{Env: []string{"PATH=/usr/bin:/bin"}, Cwd: root, Now: time.Now, Err: &bytes.Buffer{},
		Getenv: func(string) string { return "" }, Sleep: time.Sleep}
	return e
}

func (e *env) opts(cmd string) Opts {
	return Opts{Out: &e.out, R: e.runner, Wt: e.wt, Label: "lbl", State: e.state, Cmd: cmd,
		Probe: func() bool { e.probed++; return e.probeSays }}
}

func (e *env) log() string {
	b, err := os.ReadFile(filepath.Join(e.state, "gate-lbl.log"))
	if err != nil {
		e.t.Fatal(err)
	}
	return string(b)
}

func TestGatePassAndFail(t *testing.T) {
	e := newEnv(t)
	res := Run(e.opts(`echo "noise"; echo "AGGREGATE RESULT: 3 passed"; echo "FAIL  x"`))
	if res.Code != ExitPassed || res.GateRC != 0 || res.Interrupted {
		t.Fatalf("res=%+v out=%s", res, e.out.String())
	}
	log := e.log()
	if !strings.HasPrefix(log, "head ") || len(strings.SplitN(log, "\n", 2)[0]) < len("head abc") || !strings.HasSuffix(log, "noise\nAGGREGATE RESULT: 3 passed\nFAIL  x\ngate rc=0\n") {
		t.Errorf("log = %q", log)
	}
	want := "AGGREGATE RESULT: 3 passed\nFAIL  x\nkit-gate: gate rc=0 log=" + filepath.Join(e.state, "gate-lbl.log") + "\n"
	if e.out.String() != want {
		t.Errorf("out = %q, want %q", e.out.String(), want)
	}
	if e.probed != 1 {
		t.Errorf("the dependency probe runs once: %d", e.probed)
	}
	if _, err := os.Stat(filepath.Join(e.state, "gate.lock")); err != nil {
		t.Error("the lock file is created in the state dir")
	}

	f := newEnv(t)
	res = Run(f.opts(`echo "AGGREGATE RESULT: 3 passed"; exit 7`))
	if res.Code != ExitGateFailed || res.GateRC != 7 {
		t.Errorf("res=%+v: any failing gate exits 16, the gate's own rc travels beside it", res)
	}
	if !strings.Contains(f.log(), "gate rc=7\n") || !strings.Contains(f.out.String(), "kit-gate: gate rc=7 log=") {
		t.Errorf("log=%q out=%q", f.log(), f.out.String())
	}
	// the gate runs inside the worktree with the lock inherited as fd 3
	g := newEnv(t)
	Run(g.opts(`pwd; [ -e /proc/self/fd/3 ] && echo FD3 || echo NOFD3; echo passed`))
	if !strings.Contains(g.log(), g.wt+"\n") || !strings.Contains(g.log(), "FD3\n") {
		t.Errorf("log = %q", g.log())
	}
}

func TestGateSummaryKeepsTheLastFifteen(t *testing.T) {
	e := newEnv(t)
	Run(e.opts(`i=1; while [ $i -le 20 ]; do echo "passed $i"; i=$((i+1)); done`))
	lines := strings.Split(strings.TrimRight(e.out.String(), "\n"), "\n")
	// 15 summary lines (passed 7..20 and the `gate rc=` line count as matching? it contains no keyword) + the final say
	if lines[0] != "passed 6" || lines[14] != "passed 20" || len(lines) != 16 {
		t.Errorf("summary = %q", lines)
	}
}

func TestGateDefaultAndSerialCommands(t *testing.T) {
	for _, c := range []struct {
		serial bool
		want   string
	}{{false, "-j 4 --prove-teeth"}, {true, "--prove-teeth"}} {
		e := newEnv(t)
		d := filepath.Join(e.wt, "research-sdd/toolbelt/tests")
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(d, "run-all.sh"), []byte("echo \"RUNALL $*\"\n"), 0o644); err != nil {
			t.Fatal(err)
		}
		o := e.opts("")
		o.Serial = c.serial
		if res := Run(o); res.Code != 0 || !strings.Contains(e.log(), "RUNALL "+c.want+"\n") || (c.serial && strings.Contains(e.log(), "-j 4")) {
			t.Errorf("serial=%v res=%+v log=%q", c.serial, res, e.log())
		}
	}
	// an explicit command wins over --serial (the caller refuses the combination before)
	e := newEnv(t)
	o := e.opts("echo CUSTOM")
	o.Serial = true
	Run(o)
	if !strings.Contains(e.log(), "CUSTOM\n") {
		t.Errorf("log = %q", e.log())
	}
}
