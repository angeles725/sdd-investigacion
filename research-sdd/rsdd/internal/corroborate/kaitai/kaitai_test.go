package kaitai

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/adapter"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/proc"
)

const tmpfsMountinfo = "1 0 0:1 / / rw - tmpfs tmpfs rw\n"

// world is a hermetic machine: fake bwrap, ksc, JDK, venv and driver, with the two stages answered by run.
type world struct {
	t        *testing.T
	dir      string
	env      map[string]string
	out      bytes.Buffer
	errb     bytes.Buffer
	ksc      func(sp proc.Spec) proc.Result // stage 1
	driver   proc.Result                    // stage 2
	argvs    [][]string
	binSeen  bool // input/binary.bin existed while ksc ran
	genFiles []string
}

func write(t *testing.T, p, body string, mode os.FileMode) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(body), mode); err != nil {
		t.Fatal(err)
	}
}

func newWorld(t *testing.T) *world {
	t.Helper()
	d := t.TempDir()
	w := &world{t: t, dir: d, genFiles: []string{"demo.py"}}
	write(t, d+"/bin/bwrap", "#!/bin/sh\nexit 0\n", 0o755)
	write(t, d+"/jdk/bin/java", "x", 0o755)
	write(t, d+"/jdk/release", "x", 0o644)
	write(t, d+"/ksc/kaitai-struct-compiler", "#!/bin/sh\n", 0o755)
	write(t, d+"/pyhome/bin/python3", "x", 0o755)
	write(t, d+"/venv/bin/python", "x", 0o755)
	write(t, d+"/venv/pyvenv.cfg", "home = "+d+"/pyhome/bin\nexecutable = "+d+"/pyhome/bin/python3\n", 0o644)
	write(t, d+"/driver.py", "# driver\n", 0o644)
	write(t, d+"/in/sample.bin", "KS\x03\x00\xef\xbe\xad\xde", 0o644)
	write(t, d+"/in/demo.ksy", "meta:\n  id: demo\n", 0o644)
	if err := os.MkdirAll(d+"/out", 0o755); err != nil {
		t.Fatal(err)
	}
	w.env = map[string]string{
		"PATH": d + "/bin", "HOME": d + "/home", "RSDD_JAVA": d + "/jdk/bin/java", "RSDD_KSC": d + "/ksc/kaitai-struct-compiler",
		"RSDD_KAITAI_PY": d + "/venv/bin/python",
	}
	w.ksc = func(proc.Spec) proc.Result { return proc.Result{} }
	w.driver = proc.Result{Stdout: []byte(driverJSON(3, 3, ""))}
	return w
}

// driverJSON is the driver's stdout for a demo.ksy parse of 3 fields, sampled of total.
func driverJSON(total, sampled int, extra string) string {
	fields := `[{"path":"magic","name":"magic","start":0,"end":2,"size":2,"type":"bytes","value":{"hex":"4b53","sha256":"sha256:aa","size":2,"value_truncated":false}}]`
	return `{"root_type":"Demo","module":"demo","fields":` + fields + `,"counts":{"total_fields":` + itoa(total) + `,"sampled":` + itoa(sampled) +
		`},"truncated":` + boolStr(sampled < total) + `,"depth_cap":false,"value_trunc":false,"memory_cap":false,"parse_error":null,"runtime_version":"0.11"` + extra + `}`
}

func itoa(n int) string { b, _ := json.Marshal(n); return string(b) }
func boolStr(b bool) string {
	if b {
		return "true"
	}
	return "false"
}

func (w *world) fake(sp proc.Spec) (proc.Result, error) {
	w.argvs = append(w.argvs, sp.Argv)
	joined := strings.Join(sp.Argv, " ")
	switch {
	case len(sp.Argv) == 2 && sp.Argv[1] == "--version":
		return proc.Result{Stdout: []byte("kaitai-struct-compiler 0.11\n")}, nil
	case strings.Contains(joined, "--target python"):
		_, err := os.Stat(sp.Dir + "/input/binary.bin")
		w.binSeen = err == nil
		for i, a := range sp.Argv {
			if a == "--bind" && sp.Argv[i+2] == "/tmp/rsdd/gen" {
				for _, f := range w.genFiles {
					write(w.t, sp.Argv[i+1]+"/"+f, "# generated parser\n", 0o644)
				}
			}
		}
		return w.ksc(sp), nil
	case strings.Contains(joined, "driver.py"):
		r := w.driver
		r.Started = time.Date(2000, 1, 1, 0, 0, 0, 0, time.UTC)
		r.Ended = r.Started.Add(5 * time.Millisecond)
		r.Duration = 5 * time.Millisecond
		return r, nil
	}
	w.t.Fatalf("unexpected run: %v", sp.Argv)
	return proc.Result{}, nil
}

func (w *world) run(args ...string) int {
	w.t.Helper()
	s := cli.Stdio{
		Out: &w.out, Err: &w.errb, Cwd: w.dir,
		Env:     func(k string) string { return w.env[k] },
		Environ: func() []string { return nil },
		Clock:   func() time.Time { return time.Date(2000, 1, 1, 0, 0, 0, 0, time.UTC) },
	}
	e := &env{
		s: s, cwd: w.dir, home: w.env["HOME"],
		host:       adapter.Host{Root: w.dir + "/rsdd", UID: os.Getuid(), Cwd: w.dir},
		run:        w.fake,
		mountinfo:  func() (string, error) { return tmpfsMountinfo, nil },
		driverPath: func() (string, error) { return w.dir + "/driver.py", nil },
	}
	return e.main(args)
}

func (w *world) args(extra ...string) []string {
	return append([]string{"--input", w.dir + "/in/sample.bin", "--ksy", w.dir + "/in/demo.ksy", "--output", w.dir + "/out/res"}, extra...)
}

func (w *world) evidence() map[string]any {
	w.t.Helper()
	b, err := os.ReadFile(w.dir + "/out/res/kaitai-evidence.v1.json")
	if err != nil {
		w.t.Fatalf("evidence not published: %v\nstderr: %s", err, w.errb.String())
	}
	var m map[string]any
	if err := json.Unmarshal(b, &m); err != nil {
		w.t.Fatal(err)
	}
	return m
}

func (w *world) noEvidence() {
	w.t.Helper()
	for _, p := range []string{"/out/res", "/out/.res.stage"} {
		if _, err := os.Lstat(w.dir + p); err == nil {
			w.t.Errorf("%s must not exist after a fatal error", p)
		}
	}
}

func strs(v any) []string {
	var out []string
	for _, x := range v.([]any) {
		out = append(out, x.(string))
	}
	return out
}

func hasPrefix(list []string, p string) bool {
	for _, s := range list {
		if strings.HasPrefix(s, p) {
			return true
		}
	}
	return false
}

func TestHappyPathEvidence(t *testing.T) {
	w := newWorld(t)
	if rc := w.run(w.args()...); rc != 0 {
		t.Fatalf("rc=%d stderr=%s", rc, w.errb.String())
	}
	ev := w.evidence()
	if ev["schema"] != "kaitai-evidence.v1" || ev["status"] != "complete" || len(ev["errors"].([]any)) != 0 {
		t.Fatalf("envelope: %v", ev)
	}
	st := ev["structure"].(map[string]any)
	if st["truncated"] != false || st["parse_error"] != nil || st["root_type"] != "Demo" || st["module"] != "demo" {
		t.Errorf("structure: %v", st)
	}
	cp := ev["compile"].(map[string]any)
	gp := cp["generated_parser"].(map[string]any)
	if gp["path"] != "engine/gen/demo.py" || !strings.HasPrefix(gp["sha256"].(string), "sha256:") || cp["ksc_version"] != "kaitai-struct-compiler 0.11" {
		t.Errorf("compile: %v", cp)
	}
	if ev["runtime_version"] != "0.11" || !strings.HasPrefix(ev["ksy_identity"].(map[string]any)["sha256"].(string), "sha256:") {
		t.Errorf("identity: %v", ev)
	}
	if !equalStrings(strs(ev["limitations"]), limitations) {
		t.Errorf("limitations: %v", ev["limitations"])
	}
	in := ev["input"].(map[string]any)
	if in["staged"].(map[string]any)["path"] != "input/binary.bin" || in["source"].(map[string]any)["size"].(float64) != 8 {
		t.Errorf("input: %v", in)
	}
	for _, f := range []string{"engine/analysis-manifest.v1.json", "engine/gen/demo.py", "engine/driver.py", "engine/compile-stdout.txt", "engine/compile-stderr.txt", "input/struct.ksy", "input/binary.bin"} {
		if _, err := os.Stat(w.dir + "/out/res/" + f); err != nil {
			t.Errorf("published tree misses %s", f)
		}
	}
	if _, err := os.Stat(w.dir + "/out/.res.stage"); err == nil {
		t.Error("stage directory survived publication")
	}
}

func equalStrings(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// TestIsolationAndStageOrder pins the containment contract: both stages run in a network-denied bwrap, the profile
// is recorded, and the untrusted binary is not in the tree while the JVM runs.
func TestIsolationAndStageOrder(t *testing.T) {
	w := newWorld(t)
	if rc := w.run(w.args()...); rc != 0 {
		t.Fatalf("rc=%d %s", rc, w.errb.String())
	}
	if w.binSeen {
		t.Error("binary was staged before Stage 1 finished: untrusted bytes reached the JVM sandbox")
	}
	for _, argv := range w.argvs {
		j := strings.Join(argv, " ")
		if (strings.Contains(j, "--target python") || strings.Contains(j, "driver.py")) &&
			(!strings.Contains(j, "--unshare-net") || !strings.Contains(j, "--cap-drop ALL") || !strings.Contains(j, "--die-with-parent")) {
			t.Errorf("sandbox flags missing: %v", argv)
		}
	}
	prof := w.evidence()["isolation"].(map[string]any)["profile"].(map[string]any)
	if prof["name"] != "bubblewrap-kaitai-offline" || prof["network_access"] != false || prof["static_only"] != true || prof["target_execution"] != false {
		t.Errorf("profile: %v", prof)
	}
	if w.evidence()["isolation"].(map[string]any)["launcher"].(map[string]any)["path"] == "" {
		t.Error("launcher path missing")
	}
}

func TestDriverOutcomes(t *testing.T) {
	cases := []struct {
		name       string
		res        proc.Result
		args       []string
		wantRC     int
		wantStatus string
		errPrefix  []string // prefixes that must appear in errors
		limPrefix  []string // prefixes that must appear in limitations
		truncated  bool
	}{
		{name: "field cap is complete but truncated", res: proc.Result{Stdout: []byte(driverJSON(3, 2, ""))},
			wantStatus: "complete", limPrefix: []string{"field count cap fired — 2 of 3 fields sampled"}, truncated: true},
		{name: "parse error fails the run and keeps the evidence",
			res:    proc.Result{Stdout: []byte(strings.Replace(driverJSON(3, 3, ""), `"parse_error":null`, `"parse_error":"ValidationNotEqualError: wrong magic"`, 1))},
			wantRC: 1, wantStatus: "failed", errPrefix: []string{"parse-error: ValidationNotEqualError"}},
		{name: "memory cap is a first-class resource signal",
			res:    proc.Result{Stdout: []byte(strings.Replace(driverJSON(0, 0, ""), `"memory_cap":false`, `"memory_cap":true,"truncated":true`, 1))},
			wantRC: 1, wantStatus: "failed", errPrefix: []string{"memory-cap"}, limPrefix: []string{"kaitai-driver run truncated: memory-cap reached"}, truncated: true},
		{name: "timeout without output",
			res:    proc.Result{Reason: proc.ReasonTimeout, ReturnCode: -9},
			wantRC: 1, wantStatus: "failed", errPrefix: []string{"timeout", "driver-output-error: driver produced no output"},
			limPrefix: []string{"kaitai-driver run truncated"}, truncated: true},
		{name: "output cap",
			res:    proc.Result{Stdout: []byte(driverJSON(3, 3, "")), Reason: proc.ReasonOutputCap, ReturnCode: 0},
			wantRC: 1, wantStatus: "failed", errPrefix: []string{"output-cap"}, limPrefix: []string{"kaitai-driver run truncated"}, truncated: true},
		{name: "analyzer exit alone is not truncation",
			res:    proc.Result{Stdout: []byte(driverJSON(3, 3, "")), ReturnCode: 1},
			wantRC: 1, wantStatus: "failed", errPrefix: []string{"analyzer-exit:1"}},
		{name: "invalid driver JSON",
			res:    proc.Result{Stdout: []byte("not json")},
			wantRC: 1, wantStatus: "failed", errPrefix: []string{"driver-output-error: driver output is not valid JSON"}, truncated: true},
		{name: "driver JSON that is not an object",
			res:    proc.Result{Stdout: []byte("[1,2]")},
			wantRC: 1, wantStatus: "failed", errPrefix: []string{"driver-output-error: driver output is not a JSON object: list"}, truncated: true},
		{name: "depth and value caps",
			res:        proc.Result{Stdout: []byte(strings.Replace(driverJSON(3, 3, ""), `"truncated":false,"depth_cap":false,"value_trunc":false`, `"truncated":true,"depth_cap":true,"value_trunc":true`, 1))},
			wantStatus: "complete", limPrefix: []string{"structure walk depth cap fired", "field value bytes cap fired"}, truncated: true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			w := newWorld(t)
			w.driver = c.res
			if rc := w.run(w.args(c.args...)...); rc != c.wantRC {
				t.Fatalf("rc=%d want %d stderr=%s", rc, c.wantRC, w.errb.String())
			}
			ev := w.evidence()
			if ev["status"] != c.wantStatus {
				t.Errorf("status=%v want %s", ev["status"], c.wantStatus)
			}
			for _, p := range c.errPrefix {
				if !hasPrefix(strs(ev["errors"]), p) {
					t.Errorf("errors %v lack %q", ev["errors"], p)
				}
			}
			for _, p := range c.limPrefix {
				if !hasPrefix(strs(ev["limitations"]), p) {
					t.Errorf("limitations %v lack %q", ev["limitations"], p)
				}
			}
			if got := ev["structure"].(map[string]any)["truncated"]; got != c.truncated {
				t.Errorf("structure.truncated=%v want %v", got, c.truncated)
			}
			if c.wantRC == 1 && !strings.Contains(w.errb.String(), "kaitai-evidence.v1: completed with issues") {
				t.Errorf("no pointer line on stderr: %q", w.errb.String())
			}
		})
	}
}

// TestCappedFixture checks the field-cap evidence against the golden captured from a real run
// (tests/fixtures/lane/kaitai/capped.json): the limitation list and the structure block are byte-identical.
func TestCappedFixture(t *testing.T) {
	raw, err := os.ReadFile("../../../../toolbelt/tests/fixtures/lane/kaitai/capped.json")
	if err != nil {
		t.Fatal(err)
	}
	var fx map[string]any
	if err := json.Unmarshal(raw, &fx); err != nil {
		t.Fatal(err)
	}
	st := fx["structure"].(map[string]any)
	drv := map[string]any{"root_type": st["root_type"], "module": st["module"], "fields": st["fields"], "counts": st["counts"],
		"truncated": true, "depth_cap": false, "value_trunc": false, "memory_cap": false, "parse_error": nil, "runtime_version": fx["runtime_version"]}
	b, _ := json.Marshal(drv)
	w := newWorld(t)
	w.driver = proc.Result{Stdout: b}
	if rc := w.run(w.args("--max-fields", "2")...); rc != 0 {
		t.Fatalf("rc=%d %s", rc, w.errb.String())
	}
	ev := w.evidence()
	for _, k := range []string{"limitations", "structure", "runtime_version", "errors", "status"} {
		want, _ := json.Marshal(fx[k])
		got, _ := json.Marshal(ev[k])
		if string(want) != string(got) {
			t.Errorf("%s:\n got  %s\n want %s", k, got, want)
		}
	}
}

func TestFatalStates(t *testing.T) {
	cases := []struct {
		name  string
		setup func(w *world) []string
		want  string
	}{
		{"ksc nonzero exit", func(w *world) []string {
			w.ksc = func(proc.Spec) proc.Result { return proc.Result{ReturnCode: 1, Stderr: []byte("syntax error")} }
			return w.args()
		}, "ksc compile failed (errors=['analyzer-exit:1'])"},
		{"ksc analyzer failure is reported with the ksc stderr", func(w *world) []string {
			w.ksc = func(proc.Spec) proc.Result { return proc.Result{ReturnCode: 3, Stderr: []byte("boom")} }
			return w.args()
		}, "boom"},
		{"ksc timeout", func(w *world) []string {
			w.ksc = func(proc.Spec) proc.Result { return proc.Result{Reason: proc.ReasonTimeout, ReturnCode: -9} }
			return w.args()
		}, "ksc compile failed (errors=['timeout'])"},
		{"two generated parsers", func(w *world) []string { w.genFiles = []string{"a.py", "b.py"}; return w.args() }, "expected exactly one generated .py"},
		{"no generated parser", func(w *world) []string { w.genFiles = nil; return w.args() }, "expected exactly one generated .py"},
		{"output exists", func(w *world) []string { _ = os.Mkdir(w.dir+"/out/res", 0o755); return w.args() }, "output directory must not exist"},
		{"ksy over 1 MiB", func(w *world) []string {
			write(w.t, w.dir+"/in/big.ksy", strings.Repeat("a", 1<<20+1), 0o644)
			return []string{"--input", w.dir + "/in/sample.bin", "--ksy", w.dir + "/in/big.ksy", "--output", w.dir + "/out/res"}
		}, ""},
		{"symlinked binary", func(w *world) []string {
			_ = os.Symlink(w.dir+"/in/sample.bin", w.dir+"/in/link.bin")
			return []string{"--input", w.dir + "/in/link.bin", "--ksy", w.dir + "/in/demo.ksy", "--output", w.dir + "/out/res"}
		}, ""},
		{"symlinked ksy", func(w *world) []string {
			_ = os.Symlink(w.dir+"/in/demo.ksy", w.dir+"/in/link.ksy")
			return []string{"--input", w.dir + "/in/sample.bin", "--ksy", w.dir + "/in/link.ksy", "--output", w.dir + "/out/res"}
		}, ""},
		{"non-positive timeout", func(w *world) []string { return w.args("--timeout", "0") }, "timeout values must be positive"},
		{"non-positive cap", func(w *world) []string { return w.args("--max-depth", "0") }, "cap values must be positive"},
		{"jdk home without release marker", func(w *world) []string {
			_ = os.Remove(w.dir + "/jdk/release")
			return w.args()
		}, "JDK home missing expected marker release"},
		{"venv without pyvenv.cfg", func(w *world) []string {
			_ = os.Remove(w.dir + "/venv/pyvenv.cfg")
			return w.args()
		}, "no pyvenv.cfg"},
		{"venv without executable key", func(w *world) []string {
			write(w.t, w.dir+"/venv/pyvenv.cfg", "home = x\n", 0o644)
			return w.args()
		}, "pyvenv.cfg missing 'executable' key"},
		{"ksc missing", func(w *world) []string { w.env["RSDD_KSC"] = ""; w.env["PATH"] = w.dir + "/bin"; return w.args() }, "kaitai-struct-compiler not found"},
		{"java missing", func(w *world) []string { w.env["RSDD_JAVA"] = ""; return w.args() }, "java executable not found"},
		{"bwrap missing", func(w *world) []string { w.env["PATH"] = w.dir + "/nowhere"; return w.args() }, "bwrap is missing"},
		{"kaitai python missing", func(w *world) []string { w.env["RSDD_KAITAI_PY"] = w.dir + "/nope/bin/python"; return w.args() }, "no such file"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			w := newWorld(t)
			args := c.setup(w)
			if rc := w.run(args...); rc != 2 {
				t.Fatalf("rc=%d want 2; stderr=%s", rc, w.errb.String())
			}
			if !strings.HasPrefix(w.errb.String(), "corroborate-kaitai: ") || !strings.Contains(w.errb.String(), c.want) {
				t.Errorf("stderr %q lacks %q", w.errb.String(), c.want)
			}
			if _, err := os.Stat(w.dir + "/out/res/kaitai-evidence.v1.json"); err == nil {
				t.Error("evidence published on a fatal error")
			}
			if _, err := os.Lstat(w.dir + "/out/.res.stage"); err == nil {
				t.Error("stage directory left behind")
			}
		})
	}
}

func TestScopeGuard(t *testing.T) {
	e := &env{cwd: "/", home: "/home/u"}
	for _, p := range []string{"/", "/usr", "/home", "/home/u", "/opt"} {
		if err := e.scopeGuard(p); err == nil || !strings.HasPrefix(err.Error(), "path rejected by toolchain scope guard: ") {
			t.Errorf("%s: %v", p, err)
		}
	}
	if err := e.scopeGuard("/home/u/.local/share/rsdd-kaitai"); err != nil {
		t.Errorf("deep path rejected: %v", err)
	}
}

func TestUsage(t *testing.T) {
	for _, c := range []struct {
		args []string
		rc   int
		want string
	}{
		{nil, 2, "the following arguments are required: --input, --ksy, --output"},
		{[]string{"--bogus"}, 2, "flag provided but not defined"},
		{[]string{"--input", "a", "--ksy", "b", "--output", "c", "extra"}, 2, "unrecognized arguments: extra"},
		{[]string{"--timeout", "x"}, 2, "invalid value"},
		{[]string{"-h"}, 0, ""},
	} {
		w := newWorld(t)
		if rc := w.run(c.args...); rc != c.rc {
			t.Errorf("%v: rc=%d want %d", c.args, rc, c.rc)
		}
		if c.rc == 2 && !strings.Contains(w.errb.String(), c.want) {
			t.Errorf("%v: stderr %q lacks %q", c.args, w.errb.String(), c.want)
		}
		if c.rc == 0 && !strings.HasPrefix(w.out.String(), "usage: corroborate-kaitai") {
			t.Errorf("help not on stdout: %q", w.out.String())
		}
	}
}

func TestBindArgvShapes(t *testing.T) {
	got := bindTree("/a/b/c")
	want := []string{"--dir", "/a", "--dir", "/a/b", "--dir", "/a/b/c", "--ro-bind", "/a/b/c", "/a/b/c"}
	if !equalStrings(got, want) {
		t.Errorf("bindTree: %v", got)
	}
	if out := spliceBeforeDashes([]string{"bwrap", "--"}, []string{"--x"}); !equalStrings(out, []string{"bwrap", "--x", "--"}) {
		t.Errorf("splice: %v", out)
	}
}

func TestIsoZ(t *testing.T) {
	if got := isoZ(time.Date(2000, 1, 2, 3, 4, 5, 0, time.UTC)); got != "2000-01-02T03:04:05Z" {
		t.Error(got)
	}
	if got := isoZ(time.Date(2000, 1, 2, 3, 4, 5, 123456000, time.UTC)); got != "2000-01-02T03:04:05.123456Z" {
		t.Error(got)
	}
}
