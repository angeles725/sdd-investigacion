package decompile

import (
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/proc"
)

// engineCalls are the runner calls that were engine runs.
func engineCalls(w *world) []Cmd {
	var out []Cmd
	for _, c := range w.calls {
		if c.Argv[0] == w.java {
			out = append(out, c)
		}
	}
	return out
}

func timeouts(cs []Cmd) []time.Duration {
	out := make([]time.Duration, len(cs))
	for i, c := range cs {
		out[i] = c.Timeout
	}
	return out
}

func sec(n ...int) []time.Duration {
	out := make([]time.Duration, len(n))
	for i, v := range n {
		out[i] = time.Duration(v) * time.Second
	}
	return out
}

func TestExitStatus(t *testing.T) {
	for _, tt := range []struct {
		name string
		res  proc.Result
		want int
	}{
		{"clean exit", proc.Result{}, 0},
		{"exit code", proc.Result{ReturnCode: 7}, 7},
		{"stopped by TERM at the bound", proc.Result{Reason: proc.ReasonTimeout, ReturnCode: -15}, statusTimeout},
		{"trapped TERM and exited 0 at the bound", proc.Result{Reason: proc.ReasonTimeout}, statusTimeout},
		{"ended by the KILL after the grace", proc.Result{Reason: proc.ReasonTimeout, ReturnCode: -9}, statusKilled},
		{"killed by somebody else", proc.Result{ReturnCode: -9}, 137},
		{"terminated by somebody else", proc.Result{ReturnCode: -15}, 143},
		{"output cap, exit 0 is not a success", proc.Result{Reason: proc.ReasonOutputCap}, 1},
		{"output cap keeps a failing code", proc.Result{Reason: proc.ReasonOutputCap, ReturnCode: 3}, 3},
	} {
		if got := exitStatus(tt.res); got != tt.want {
			t.Errorf("%s: exitStatus = %d, want %d", tt.name, got, tt.want)
		}
	}
}

func TestReasonOf(t *testing.T) {
	for rc, want := range map[int]string{124: "timeout", 137: "killed", 1: "error", 0: "error", 7: "error", 127: "error"} {
		if got := reasonOf(rc); got != want {
			t.Errorf("reasonOf(%d) = %q, want %q", rc, got, want)
		}
	}
}

func TestProcRunner(t *testing.T) {
	var got proc.Spec
	fake := func(res proc.Result, err error) func(proc.Spec) (proc.Result, error) {
		return func(s proc.Spec) (proc.Result, error) { got = s; return res, err }
	}
	cmd := Cmd{Argv: []string{"/bin/x", "a"}, Dir: "/d", Env: []string{"K=V"}, Timeout: 7 * time.Second, Grace: 3 * time.Second}

	r := newProcRunner(fake(proc.Result{Stdout: []byte("o"), Stderr: []byte("e"), ReturnCode: 2}, nil))(cmd)
	want := proc.Spec{Argv: cmd.Argv, Dir: "/d", Env: cmd.Env, Timeout: 7 * time.Second, MaxBytes: maxOutput, Grace: 3 * time.Second}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("spec = %+v, want %+v", got, want)
	}
	if r.RC != 2 || string(r.Stdout) != "o" || string(r.Stderr) != "e" {
		t.Errorf("result = %+v", r)
	}

	cmd.Timeout = 0
	newProcRunner(fake(proc.Result{}, nil))(cmd)
	if got.Timeout != unbounded {
		t.Errorf("an unbounded command got timeout %v, want %v", got.Timeout, unbounded)
	}

	for _, err := range []error{&proc.SpawnError{Path: "/bin/x", Err: errors.New("nope")}, proc.ErrInvalidSpec} {
		r = newProcRunner(fake(proc.Result{ReturnCode: 9}, err))(cmd)
		if r.RC != statusSpawn || !strings.Contains(string(r.Stderr), err.Error()) || !strings.HasSuffix(string(r.Stderr), "\n") {
			t.Errorf("%v: result = %+v", err, r)
		}
	}
	// A group the guard refused to stop is not a spawn failure: the run's own result stands.
	r = newProcRunner(fake(proc.Result{ReturnCode: 4}, errors.New("proc: stop process group")))(cmd)
	if r.RC != 4 {
		t.Errorf("a stop error replaced the result: %+v", r)
	}
}

func TestProcRunnerReal(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("proc.Run needs a unix host")
	}
	r := newProcRunner(proc.Run)(Cmd{Argv: []string{"/bin/sh", "-c", "echo out; echo err >&2; exit 3"}, Env: []string{"PATH=/bin:/usr/bin"}, Timeout: time.Minute})
	if r.RC != 3 || string(r.Stdout) != "out\n" || string(r.Stderr) != "err\n" {
		t.Errorf("result = %+v", r)
	}
	r = newProcRunner(proc.Run)(Cmd{Argv: []string{"/nonexistent/prog"}, Timeout: time.Minute})
	if r.RC != statusSpawn {
		t.Errorf("an unstartable program: %+v", r)
	}
}

func TestCanonical(t *testing.T) {
	dir := t.TempDir()
	real := filepath.Join(dir, "real")
	for p, mode := range map[string]os.FileMode{real: 0o755, filepath.Join(dir, "plain"): 0o644} {
		if err := os.WriteFile(p, nil, mode); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.Symlink(real, filepath.Join(dir, "link")); err != nil {
		t.Fatal(err)
	}
	resolved, _ := filepath.EvalSymlinks(real)
	for _, tt := range []struct {
		name, path, want string
	}{
		{"executable file", real, resolved},
		{"symlink is resolved", filepath.Join(dir, "link"), resolved},
		{"not executable", filepath.Join(dir, "plain"), ""},
		{"a directory", dir, ""},
		{"missing", filepath.Join(dir, "gone"), ""},
	} {
		got, ok := canonical(tt.path)
		if got != tt.want || ok != (tt.want != "") {
			t.Errorf("%s: canonical = %q, %v", tt.name, got, ok)
		}
	}
}

// TestEngineArgv pins the command line of every engine and input shape (old cases a-e) and the options that shape it.
func TestEngineArgv(t *testing.T) {
	for _, tt := range []struct {
		name  string
		in    string
		args  []string
		env   map[string]string
		after func(w *world, in, out string) []string // everything after the java launcher
	}{
		{"a procyon + .class: the class is a bare positional, -o first", "T.class", []string{"--engine", "procyon"}, nil,
			func(w *world, in, out string) []string { return []string{"-jar", w.env["PROCYON_JAR"], "-o", out, in} }},
		{"b procyon + .jar: -jar <jar>", "t.jar", []string{"--engine", "procyon"}, nil,
			func(w *world, in, out string) []string {
				return []string{"-jar", w.env["PROCYON_JAR"], "-jar", in, "-o", out}
			}},
		{"e procyon + .JAR: the extension test ignores case", "T.JAR", []string{"--engine", "procyon"}, nil,
			func(w *world, in, out string) []string {
				return []string{"-jar", w.env["PROCYON_JAR"], "-jar", in, "-o", out}
			}},
		{"c vineflower + .class", "T.class", []string{"--engine", "vineflower"}, nil,
			func(w *world, in, out string) []string { return []string{"-jar", w.env["VINEFLOWER_JAR"], in, out} }},
		{"d cfr + .class: <in> --outputdir <out>", "T.class", []string{"--engine", "cfr"}, nil,
			func(w *world, in, out string) []string {
				return []string{"-jar", w.env["CFR_JAR"], in, "--outputdir", out}
			}},
		{"thread count reaches vineflower", "T.class", []string{"--thread-count", "4"}, nil,
			func(w *world, in, out string) []string {
				return []string{"-jar", w.env["VINEFLOWER_JAR"], "--thread-count=4", in, out}
			}},
		{"thread count is ignored by cfr", "T.class", []string{"--engine", "cfr", "--thread-count", "4"}, nil,
			func(w *world, in, out string) []string {
				return []string{"-jar", w.env["CFR_JAR"], in, "--outputdir", out}
			}},
		{"heap limit comes before -jar", "T.class", nil, map[string]string{"RSDD_DECOMPILE_MAX_HEAP": "512m"},
			func(w *world, in, out string) []string {
				return []string{"-Xmx512m", "-jar", w.env["VINEFLOWER_JAR"], in, out}
			}},
		{"--jar overrides the primary engine's jar", "T.class", []string{"--engine", "cfr", "--jar", "@own"}, nil,
			func(w *world, in, out string) []string {
				return []string{"-jar", filepath.Join(w.root, "own.jar"), in, "--outputdir", out}
			}},
	} {
		t.Run(tt.name, func(t *testing.T) {
			w := newWorld(t)
			for k, v := range tt.env {
				w.env[k] = v
			}
			w.hook = func(Cmd) (Result, bool) { return Result{}, true } // only the command line matters here
			w.touch("own.jar")
			in := w.input(tt.in, jarSpec{})
			out := filepath.Join(w.root, "out")
			args := append([]string{in, out}, tt.args...)
			for i, a := range args {
				if a == "@own" {
					args[i] = filepath.Join(w.root, "own.jar")
				}
			}
			w.exec(args...)
			c := engineCalls(w)[0]
			want := append([]string{w.java}, tt.after(w, in, out)...)
			if !reflect.DeepEqual(c.Argv, want) {
				t.Errorf("argv:\n%q\nwant:\n%q", c.Argv, want)
			}
			if c.Dir != w.root || !reflect.DeepEqual(c.Env, w.environ()) {
				t.Errorf("the engine must run in the caller's directory and environment: dir=%q env=%q", c.Dir, c.Env)
			}
		})
	}
}

// TestJarOverrideIsPrimaryOnly: the fallback engine keeps its own jar.
func TestJarOverrideIsPrimaryOnly(t *testing.T) {
	w := newWorld(t)
	own := w.touch("my-vineflower.jar")
	w.env["STUB_VF_RC"] = "7"
	w.exec(w.touch("Test.class"), filepath.Join(w.root, "out"), "--jar", own)
	cs := engineCalls(w)
	if len(cs) != 2 || cs[0].Argv[2] != own || cs[1].Argv[2] != w.env["CFR_JAR"] {
		t.Errorf("jars used: %v", cs)
	}
}

// TestEngineBounds: the bound and the grace handed to the process runner (old A4, A5b, mA4, F5).
func TestEngineBounds(t *testing.T) {
	for _, tt := range []struct {
		name           string
		args           []string
		env            map[string]string
		timeout, grace time.Duration
	}{
		{"defaults are 240 s and 5 s", nil, map[string]string{"RSDD_DECOMPILE_TIMEOUT": ""}, 240 * time.Second, 5 * time.Second},
		{"environment timeout and grace", nil, map[string]string{"RSDD_DECOMPILE_TIMEOUT": "9", "RSDD_KILL_AFTER": "3"}, 9 * time.Second, 3 * time.Second},
		{"--timeout wins over the environment", []string{"--timeout", "2"}, map[string]string{"RSDD_DECOMPILE_TIMEOUT": "9"}, 2 * time.Second, 5 * time.Second},
		{"--timeout 0 is unbounded", []string{"--timeout", "0"}, nil, 0, 0},
		{"no timeout binary: unbounded", nil, map[string]string{"RSDD_TIMEOUT_BIN": "@missing"}, 0, 0},
	} {
		t.Run(tt.name, func(t *testing.T) {
			w := newWorld(t)
			for k, v := range tt.env {
				w.env[k] = strings.ReplaceAll(v, "@missing", filepath.Join(w.root, "no-such"))
			}
			w.exec(append([]string{w.touch("Test.class"), filepath.Join(w.root, "out")}, tt.args...)...)
			c := engineCalls(w)[0]
			if c.Timeout != tt.timeout || c.Grace != tt.grace {
				t.Errorf("timeout %v grace %v, want %v %v", c.Timeout, c.Grace, tt.timeout, tt.grace)
			}
		})
	}
}

// TestIsolationClamp: while a jar is being isolated every engine run is capped at the REMAINING isolation budget
// (old J1-J4, P1, mJ1, mJ3, mN2, mN3a): inside a unit, in the coverage sweep, and on the success path, but not for
// the whole-artifact fallback after the budget is spent, nor for the marker scan, nor with an unlimited budget.
func TestIsolationClamp(t *testing.T) {
	hang := map[string]string{"STUB_FAIL_WHOLE": "1", "STUB_SLEEP_CLASSES": "A", "STUB_SLEEP": "15", "RSDD_DECOMPILE_TIMEOUT": "60"}
	for _, tt := range []struct {
		name  string
		jar   string
		env   map[string]string
		extra []string
		want  []time.Duration // the timeout of every engine run, in order
	}{
		{"J1 a package rerun is cut at the remaining budget; the whole-artifact fallback is not clamped", "jar3",
			merge(hang, "RSDD_DECOMPILE_ISOLATE_BUDGET", "2"), nil, sec(60, 2, 60)},
		{"an unlimited budget clamps nothing", "jar3",
			merge(hang, "RSDD_DECOMPILE_ISOLATE_BUDGET", "0", "STUB_SLEEP", "70"), nil, sec(60, 60, 60, 60, 60)},
		{"a budget longer than the timeout leaves the timeout", "jar3",
			map[string]string{"STUB_FAIL_WHOLE": "1", "RSDD_DECOMPILE_TIMEOUT": "60", "RSDD_DECOMPILE_ISOLATE_BUDGET": "100"}, nil, sec(60, 60, 60, 60)},
		{"the remaining budget, not the whole budget, is the cap", "jar3",
			merge(hang, "RSDD_DECOMPILE_ISOLATE_BUDGET", "100", "STUB_SLEEP", "70"), nil, sec(60, 60, 40, 40, 40)},
		{"--timeout 0: the budget alone bounds the isolation runs", "jar3",
			map[string]string{"STUB_FAIL_WHOLE": "1", "RSDD_DECOMPILE_ISOLATE_BUDGET": "5"}, []string{"--timeout", "0"}, sec(0, 5, 5, 5)},
		{"J2 the coverage sweep's fallback is capped too", "jarp",
			map[string]string{"STUB_OMIT_CLASSES": "A2", "RSDD_DECOMPILE_TIMEOUT": "60", "RSDD_DECOMPILE_ISOLATE_BUDGET": "3"}, nil, sec(60, 3)},
		{"the marker scan after a success is not clamped", "jar3",
			map[string]string{"STUB_MARKER_CLASSES": "B", "RSDD_DECOMPILE_TIMEOUT": "60", "RSDD_DECOMPILE_ISOLATE_BUDGET": "2"}, nil, sec(60, 60)},
		{"no timeout binary: nothing to clamp", "jar3",
			map[string]string{"STUB_FAIL_WHOLE": "1", "RSDD_DECOMPILE_ISOLATE_BUDGET": "2", "RSDD_TIMEOUT_BIN": "@missing"}, nil, sec(0, 0, 0, 0)},
	} {
		t.Run(tt.name, func(t *testing.T) {
			w := newWorld(t)
			for k, v := range tt.env {
				w.env[k] = strings.ReplaceAll(v, "@missing", filepath.Join(w.root, "no-such"))
			}
			in := w.input(tt.jar+".jar", inputs[tt.jar])
			w.exec(append([]string{in, filepath.Join(w.root, "out"), "--engine", "vineflower"}, tt.extra...)...)
			if got := timeouts(engineCalls(w)); !reflect.DeepEqual(got, tt.want) {
				t.Errorf("engine timeouts %v, want %v", got, tt.want)
			}
		})
	}
}

func merge(base map[string]string, kv ...string) map[string]string {
	out := map[string]string{}
	for k, v := range base {
		out[k] = v
	}
	for i := 0; i < len(kv); i += 2 {
		out[kv[i]] = kv[i+1]
	}
	return out
}

// TestBudgetEdge: the budget counts WHOLE seconds since the isolation phase began, from the moment isolation starts
// (not the program), and a unit whose run ate the budget leaves the next one unrun.
func TestBudgetEdge(t *testing.T) {
	for _, tt := range []struct {
		budget    string
		spent     time.Duration
		exhausted bool
	}{
		{"1", 999 * time.Millisecond, false},
		{"1", time.Second, true},
		{"2", 1999 * time.Millisecond, false},
		{"2", 2 * time.Second, true},
	} {
		w := newWorld(t)
		w.env["STUB_FAIL_WHOLE"], w.env["RSDD_DECOMPILE_ISOLATE_BUDGET"] = "1", tt.budget
		in := w.input("two.jar", jarSpec{entries: []string{"a/A.class", "b/B.class"}})
		w.hook = func(c Cmd) (Result, bool) {
			if strings.HasSuffix(c.Argv[len(c.Argv)-2], "/pin/1") {
				w.clock.advance(tt.spent)
			}
			return Result{}, false
		}
		stdout, _, _ := w.exec(in, filepath.Join(w.root, "out"))
		if got := strings.Contains(stdout, "total_budget_exhausted"); got != tt.exhausted {
			t.Errorf("budget %s spent %v: exhausted = %v\n%s", tt.budget, tt.spent, got, stdout)
		}
	}
}

// TestBudgetStartsWithIsolation: time the failed whole-jar run took does not count against the isolation budget,
// on the failure path (isolateJar) and on the success path (the sweep).
func TestBudgetStartsWithIsolation(t *testing.T) {
	for _, tt := range []struct {
		name string
		env  map[string]string
		jar  jarSpec
		want string
	}{
		{"failure path", map[string]string{"STUB_FAIL_WHOLE": "1"}, jarSpec{entries: []string{"a/A.class"}}, "DEGRADED: IN -> OUT  (engine=vineflower units=0 primary=error isolation=package)\n"},
		{"success path", map[string]string{"STUB_OMIT_CLASSES": "A"}, jarSpec{entries: []string{"a/A.class", "a/B.class"}}, "DEGRADED: IN -> OUT  (engine=vineflower units=1)\nUNIT: a/A reason=missing fallback=cfr result=ok\n"},
	} {
		w := newWorld(t)
		w.env["RSDD_DECOMPILE_ISOLATE_BUDGET"] = "5"
		for k, v := range tt.env {
			w.env[k] = v
		}
		in := w.input("one.jar", tt.jar)
		out := filepath.Join(w.root, "out")
		w.hook = func(c Cmd) (Result, bool) {
			if c.Argv[len(c.Argv)-2] == in {
				w.clock.advance(100 * time.Second)
			}
			return Result{}, false
		}
		stdout, _, _ := w.exec(in, out)
		if got := w.norm(stdout, in, out); got != tt.want {
			t.Errorf("%s:\n%s\nwant:\n%s", tt.name, got, tt.want)
		}
	}
}

// TestBudgetFloor: a fallback that starts after its unit's run ate the whole budget still gets one second, never
// "no bound".
func TestBudgetFloor(t *testing.T) {
	w := newWorld(t)
	w.env["STUB_FAIL_WHOLE"], w.env["RSDD_DECOMPILE_ISOLATE_BUDGET"], w.env["RSDD_DECOMPILE_TIMEOUT"] = "1", "2", "60"
	in := w.input("two.jar", jarSpec{entries: []string{"a/A.class", "a/B.class"}})
	w.hook = func(c Cmd) (Result, bool) {
		switch dir := c.Argv[len(c.Argv)-2]; {
		case strings.HasSuffix(dir, "/pin/1"):
			return Result{RC: 1}, true
		case strings.HasSuffix(dir, "/cin/1-1"):
			w.clock.advance(5 * time.Second) // the unit's run overran the 2 s budget
			return Result{RC: 1}, true
		}
		return Result{}, false
	}
	w.exec(in, filepath.Join(w.root, "out"))
	cs := engineCalls(w)
	if len(cs) < 4 || cs[3].Argv[2] != w.env["CFR_JAR"] || cs[3].Timeout != time.Second {
		t.Errorf("the fallback after an overrun: %v", timeouts(cs))
	}
}

// TestUnzipFailures: what unzip's status and result mean (old M1, M2, B8, B9, mM1-mM3).
func TestUnzipFailures(t *testing.T) {
	for _, tt := range []struct {
		name string
		rc   int
		want string
	}{
		{"rc 1 is a warning: nothing was extracted here, so no class entries", 1, "isolation=no-class-entries"},
		{"rc 11: no matching entries", 11, "isolation=no-class-entries"},
		{"rc 9 is a real failure", 9, "isolation=unavailable"},
		{"rc 2", 2, "isolation=unavailable"},
	} {
		w := newWorld(t)
		w.env["STUB_FAIL_WHOLE"] = "1"
		w.unzipRC = tt.rc
		stdout, _, _ := w.exec(w.input("p.jar", inputs["jarp"]), filepath.Join(w.root, "out"))
		if !strings.Contains(stdout, "UNIT: <whole-artifact> reason=error fallback=cfr result=ok "+tt.want+"\n") {
			t.Errorf("%s:\n%s", tt.name, stdout)
		}
	}
}
