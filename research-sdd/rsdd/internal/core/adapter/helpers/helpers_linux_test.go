//go:build linux

package helpers

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/proc"
)

func mustWrite(t *testing.T, path, data string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(data), 0o644); err != nil {
		t.Fatal(err)
	}
}

func realTemp(t *testing.T) string {
	t.Helper()
	d, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	return d
}

func asKind(t *testing.T, err error, kind Kind, msg string) *Error {
	t.Helper()
	var he *Error
	if !errors.As(err, &he) || he.Kind != kind || he.Error() != msg {
		t.Fatalf("got %v, want %s %q", err, kind, msg)
	}
	return he
}

func TestRealpathNeedsAWorkingDirectoryForRelativePaths(t *testing.T) {
	if got, err := realpath("a/b", ""); got != "" || err == nil || err.Error() != "helpers: a relative path needs an injected working directory" {
		t.Fatalf("a relative path with no cwd resolved: %v", err)
	}
	if got, err := realpath("/a/b", ""); err != nil || got != "/a/b" {
		t.Fatalf("absolute path: %q %v", got, err)
	}
	var he *Error
	if err := errNil(VenvRootFor(Env{}, "rel/bin/tool")); !errors.Is(err, errNeedCwd) || errors.As(err, &he) {
		t.Fatalf("a relative tool with no cwd: %v", err)
	}
	// A relative Home with no cwd fails the belt check raw, not as a VenvBindError.
	if err := errNil(VenvRootFor(Env{Home: "rel"}, "/a/b/c/bin/tool")); !errors.Is(err, errNeedCwd) || errors.As(err, &he) {
		t.Fatalf("a relative home with no cwd: %v", err)
	}
	if err := AssertSafeBindRoot(Env{Home: "rel"}, "/a/b/c"); !errors.Is(err, errNeedCwd) {
		t.Fatalf("AssertSafeBindRoot with a relative home: %v", err)
	}
}

func TestVenvRootForExactMessages(t *testing.T) {
	dir := realTemp(t)
	mustWrite(t, dir+"/ok/bin/tool", "")
	mustWrite(t, dir+"/ok/pyvenv.cfg", "x")
	mustWrite(t, dir+"/nocfg/bin/tool", "")
	e := Env{Cwd: dir, Home: "/nonexistent/h"}
	root, err := VenvRootFor(e, dir+"/ok/bin/tool")
	if err != nil || root != dir+"/ok" {
		t.Fatalf("happy path: %q %v", root, err)
	}
	const msg = "tool is not inside a Python venv (wrapper script?); point RSDD_<TOOL> at the venv's bin/<tool>"
	asKind(t, errNil(VenvRootFor(e, dir+"/nocfg/bin/tool")), KindVenvBind, msg)
	asKind(t, errNil(VenvRootFor(e, dir+"/ok/tool")), KindVenvBind, "tool executable is not inside a 'bin/' directory: "+dir+"/ok/tool")
	asKind(t, errNil(VenvRootFor(e, "/")), KindVenvBind, "tool executable is not inside a 'bin/' directory: /")
	he := asKind(t, errNil(VenvRootFor(e, "/usr/bin/tool")), KindVenvBind, msg)
	asKind(t, he.Unwrap(), KindBindScope, "path is a blocked system root: '/usr'")
	// A relative tool resolves against the injected cwd.
	if root, err := VenvRootFor(e, "ok/bin/tool"); err != nil || root != dir+"/ok" {
		t.Fatalf("relative: %q %v", root, err)
	}
	// pyvenv.cfg must be a file the stat can see, a directory is not one.
	if err := os.MkdirAll(dir+"/dircfg/bin", 0o755); err != nil {
		t.Fatal(err)
	}
	mustWrite(t, dir+"/dircfg/bin/tool", "")
	if err := os.Mkdir(dir+"/dircfg/pyvenv.cfg", 0o755); err != nil {
		t.Fatal(err)
	}
	asKind(t, errNil(VenvRootFor(e, dir+"/dircfg/bin/tool")), KindVenvBind, msg)
}

// errNil returns the error of a call that must have failed, checking that it
// returned the zero string too.
func errNil(s string, err error) error {
	if s != "" {
		return fmt.Errorf("returned %q alongside the error %v", s, err)
	}
	return err
}

func TestBindVenvExactArgv(t *testing.T) {
	dir := realTemp(t)
	mustWrite(t, dir+"/v/bin/tool", "")
	mustWrite(t, dir+"/v/pyvenv.cfg", "x")
	if err := os.Mkdir(dir+"/w", 0o755); err != nil {
		t.Fatal(err)
	}
	e := Env{Cwd: dir, Home: "/nonexistent/h"}
	got, err := BindVenv(e, []string{"bwrap", "--ro-bind", "/a", "/a", "--"}, dir+"/v/bin/tool",
		[]string{"/etc/passwd", "/etc/group"}, []Writable{{dir + "/w/", "/tmp/rsdd//out/"}})
	if err != nil {
		t.Fatal(err)
	}
	var want []string
	want = append(want, "bwrap", "--ro-bind", "/a", "/a")
	parts := strings.Split(strings.TrimPrefix(dir+"/v", "/"), "/")
	for i := range parts {
		want = append(want, "--dir", "/"+strings.Join(parts[:i+1], "/"))
	}
	want = append(want, "--ro-bind", dir+"/v", dir+"/v",
		"--ro-bind-try", "/etc/passwd", "/etc/passwd",
		"--ro-bind-try", "/etc/group", "/etc/group",
		"--dir", "/tmp/rsdd/out", "--bind", dir+"/w", "/tmp/rsdd/out", "--")
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("argv\n got  %q\n want %q", got, want)
	}
	// The caller's slice has spare capacity: the result must not be built in it.
	in := append(make([]string, 0, 32), "bwrap", "--")
	out, err := BindVenv(e, in, dir+"/v/bin/tool", nil, nil)
	if err != nil || !reflect.DeepEqual(in, []string{"bwrap", "--"}) || !reflect.DeepEqual(in[:cap(in)][:2], []string{"bwrap", "--"}) || out[0] != "bwrap" {
		t.Fatalf("prefix was modified or result wrong: %v %v", in, err)
	}
}

func TestBindVenvRefusals(t *testing.T) {
	dir := realTemp(t)
	mustWrite(t, dir+"/v/bin/tool", "")
	mustWrite(t, dir+"/v/pyvenv.cfg", "x")
	mustWrite(t, dir+"/w/file", "")
	if err := os.Symlink(dir, dir+"/lnk"); err != nil {
		t.Fatal(err)
	}
	e := Env{Cwd: dir, Home: "/nonexistent/h"}
	tool := dir + "/v/bin/tool"
	pre := []string{"bwrap", "--"}
	const endMsg = "bwrap prefix must end with '--' (produced by adapter_core.sandbox())"
	for _, p := range [][]string{nil, {}, {"bwrap"}, {"--", "x"}} {
		_, err := BindVenv(e, p, tool, nil, nil)
		asKind(t, err, KindVenvBind, endMsg)
	}
	_, err := BindVenv(e, pre, tool, []string{"/etc/shadow"}, nil)
	asKind(t, err, KindVenvBind, "etc_ro_bind_try entry '/etc/shadow' is not in the allowed set ['/etc/group', '/etc/passwd']; only /etc/passwd and /etc/group are permitted (required by vivisect's getpwuid call)")
	_, err = BindVenv(e, pre, tool, nil, []Writable{{dir + "/w", "/tmp/rsdd/../x"}})
	asKind(t, err, KindVenvBind, "writable sandbox_path must start with '/tmp/rsdd/': '/tmp/x'")
	_, err = BindVenv(e, pre, tool, nil, []Writable{{dir + "/nope", "/tmp/rsdd/x"}})
	asKind(t, err, KindVenvBind, "writable host_dir does not exist or is not accessible: "+dir+"/nope")
	_, err = BindVenv(e, pre, tool, nil, []Writable{{dir + "/lnk", "/tmp/rsdd/x"}})
	asKind(t, err, KindVenvBind, "writable host_dir must not be a symlink: "+dir+"/lnk")
	_, err = BindVenv(e, pre, tool, nil, []Writable{{dir + "/w/file", "/tmp/rsdd/x"}})
	asKind(t, err, KindVenvBind, "writable host_dir must be a directory: "+dir+"/w/file")
	_, err = BindVenv(e, pre, "/usr/bin/tool", nil, nil)
	asKind(t, err, KindVenvBind, "tool is not inside a Python venv (wrapper script?); point RSDD_<TOOL> at the venv's bin/<tool>")
}

// fakeRun records each spec and answers from results (the last one repeats).
type fakeRun struct {
	specs   []proc.Spec
	results []proc.Result
	err     error
	onCall  func(i int, s proc.Spec)
}

func (f *fakeRun) run(s proc.Spec) (proc.Result, error) {
	i := len(f.specs)
	f.specs = append(f.specs, s)
	if f.onCall != nil {
		f.onCall(i, s)
	}
	if f.err != nil {
		return proc.Result{}, f.err
	}
	if len(f.results) == 0 {
		return proc.Result{}, nil
	}
	r := f.results[min(i, len(f.results)-1)]
	return r, nil
}

func emitFixture(t *testing.T) (EmitConfig, string) {
	t.Helper()
	root := realTemp(t)
	if err := os.MkdirAll(root+"/stage/engine", 0o755); err != nil {
		t.Fatal(err)
	}
	return EmitConfig{
		Stage: root + "/stage", Schema: "e.v1", Domain: map[string]any{"d": 1}, InputIdentity: map[string]any{"i": 1},
		Isolation: map[string]any{"l": 2}, ManifestSpec: map[string]any{"spec": true}, ManifestCLI: []string{"/py", "/cli.py"},
		Destination: root + "/dest", Timeout: 7, Env: []string{"A=b"},
	}, root
}

func TestEmitEvidenceRunsTheThreeVerbsInOrder(t *testing.T) {
	cfg, root := emitFixture(t)
	f := &fakeRun{}
	f.onCall = func(i int, s proc.Spec) {
		_, err := os.Stat(root + "/stage/engine/manifest-spec.json")
		if i < 1 && err != nil {
			t.Errorf("call %d: the spec must exist until create ran: %v", i, err)
		}
		if i >= 1 && err == nil {
			t.Errorf("call %d: the spec must be gone after create", i)
		}
	}
	cfg.Run = f.run
	var stderr bytes.Buffer
	cfg.Stderr = &stderr
	if err := EmitEvidence(cfg); err != nil {
		t.Fatal(err)
	}
	m := root + "/stage/engine/analysis-manifest.v1.json"
	want := [][]string{
		{"/py", "/cli.py", "create", "--root", root + "/stage", "--spec", root + "/stage/engine/manifest-spec.json", "--output", m},
		{"/py", "/cli.py", "validate", m},
		{"/py", "/cli.py", "verify", "--root", root + "/stage", m},
	}
	if len(f.specs) != 3 {
		t.Fatalf("%d runs", len(f.specs))
	}
	for i, s := range f.specs {
		if !reflect.DeepEqual(s.Argv, want[i]) {
			t.Errorf("argv %d\n got  %q\n want %q", i, s.Argv, want[i])
		}
		if s.Timeout != 7*time.Second || s.MaxBytes != manifestMaxBytes || !reflect.DeepEqual(s.Env, []string{"A=b"}) || s.Dir != "" {
			t.Errorf("spec %d = %+v", i, s)
		}
	}
	// Published: the stage became the destination, which holds the envelope.
	b, err := os.ReadFile(root + "/dest/e.v1.json")
	if err != nil {
		t.Fatal(err)
	}
	if string(b) != `{"d":1,"errors":[],"input":{"i":1},"isolation":{"l":2},"limitations":[],"schema":"e.v1","status":"complete"}`+"\n" {
		t.Errorf("envelope = %s", b)
	}
	if stderr.Len() != 0 {
		t.Errorf("stderr = %q", stderr.String())
	}
	if _, err := os.Stat(root + "/stage"); err == nil {
		t.Error("the stage still exists after publish")
	}
}

func TestEmitEvidenceStatusFailedAndPointer(t *testing.T) {
	cfg, root := emitFixture(t)
	cfg.Run = (&fakeRun{}).run
	cfg.Errors = []string{"analyzer-exit:1", "timeout"}
	cfg.Limitations = []string{"l"}
	cfg.Destination = root + "//dest/"
	var stderr bytes.Buffer
	cfg.Stderr = &stderr
	if err := EmitEvidence(cfg); err != nil {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(root + "/dest/e.v1.json")
	if !strings.Contains(string(b), `"errors":["analyzer-exit:1","timeout"]`) || !strings.Contains(string(b), `"status":"failed"`) || !strings.Contains(string(b), `"limitations":["l"]`) {
		t.Errorf("envelope = %s", b)
	}
	want := "e.v1: completed with issues (analyzer-exit:1, timeout) — see " + root + "/dest/e.v1.json\n"
	if stderr.String() != want {
		t.Errorf("stderr %q, want %q", stderr.String(), want)
	}
}

func TestEmitEvidenceCliFailures(t *testing.T) {
	for _, tc := range []struct {
		name   string
		res    proc.Result
		failAt int
		want   string
	}{
		{"exit", proc.Result{ReturnCode: 3}, 1, "manifest-cli 'validate' failed (exit 3)"},
		{"signal", proc.Result{ReturnCode: -9}, 2, "manifest-cli 'verify' failed (exit -9)"},
		{"create", proc.Result{ReturnCode: 1}, 0, "manifest-cli 'create' failed (exit 1)"},
		{"timeout", proc.Result{Reason: proc.ReasonTimeout, ReturnCode: -9}, 0, "manifest-cli 'create' timed out after 7s"},
		{"output-cap", proc.Result{Reason: proc.ReasonOutputCap, ReturnCode: -9}, 1, "manifest-cli 'validate' output exceeded the capture limit"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			cfg, root := emitFixture(t)
			f := &fakeRun{}
			f.results = make([]proc.Result, tc.failAt+1)
			f.results[tc.failAt] = tc.res
			cfg.Run = f.run
			asKind(t, EmitEvidence(cfg), KindManifest, tc.want)
			if len(f.specs) != tc.failAt+1 {
				t.Errorf("%d runs, want %d (a failure stops the tail)", len(f.specs), tc.failAt+1)
			}
			if _, err := os.Stat(root + "/dest"); err == nil {
				t.Error("published despite the failure")
			}
		})
	}
}

func TestEmitEvidenceNonPositiveTimeoutIsATimeoutWithoutRunning(t *testing.T) {
	for _, secs := range []int{0, -1} {
		cfg, _ := emitFixture(t)
		f := &fakeRun{}
		cfg.Run, cfg.Timeout = f.run, secs
		asKind(t, EmitEvidence(cfg), KindManifest, "manifest-cli 'create' timed out after "+map[int]string{0: "0", -1: "-1"}[secs]+"s")
		if len(f.specs) != 0 {
			t.Errorf("timeout %d: ran %d times", secs, len(f.specs))
		}
	}
}

func TestEmitEvidenceSpawnFailureIsRaw(t *testing.T) {
	cfg, _ := emitFixture(t)
	spawn := &proc.SpawnError{Path: "/py", Err: syscall.ENOENT}
	cfg.Run = (&fakeRun{err: spawn}).run
	err := EmitEvidence(cfg)
	var he *Error
	if errors.As(err, &he) || !errors.Is(err, spawn) {
		t.Fatalf("got %v, want the raw spawn error", err)
	}
}

func TestEmitEvidenceForwardsChildOutput(t *testing.T) {
	cfg, _ := emitFixture(t)
	cfg.Run = (&fakeRun{results: []proc.Result{{Stdout: []byte("out1"), Stderr: []byte("err1")}, {Stdout: []byte("out2")}, {Stderr: []byte("err3")}}}).run
	var o, e bytes.Buffer
	cfg.Stdout, cfg.Stderr = &o, &e
	if err := EmitEvidence(cfg); err != nil {
		t.Fatal(err)
	}
	if o.String() != "out1out2" || e.String() != "err1err3" {
		t.Errorf("stdout %q stderr %q", o.String(), e.String())
	}
	cfg2, _ := emitFixture(t)
	cfg2.Run = (&fakeRun{results: []proc.Result{{Stdout: []byte("x"), Stderr: []byte("y")}}}).run
	if err := EmitEvidence(cfg2); err != nil { // nil writers discard
		t.Fatal(err)
	}
	// Output is forwarded even when the step failed.
	cfg3, _ := emitFixture(t)
	cfg3.Run = (&fakeRun{results: []proc.Result{{Stdout: []byte("o"), Stderr: []byte("e"), ReturnCode: 2}}}).run
	var o3, e3 bytes.Buffer
	cfg3.Stdout, cfg3.Stderr = &o3, &e3
	if err := EmitEvidence(cfg3); err == nil || o3.String() != "o" || e3.String() != "e" {
		t.Errorf("failed step: %v stdout %q stderr %q", err, o3.String(), e3.String())
	}
}

func TestEmitEvidencePublishFailureMessages(t *testing.T) {
	cfg, root := emitFixture(t)
	cfg.Run = (&fakeRun{}).run
	if err := os.Mkdir(root+"/dest", 0o755); err != nil {
		t.Fatal(err)
	}
	cfg.Errors = []string{"e"}
	var stderr bytes.Buffer
	cfg.Stderr = &stderr
	he := asKind(t, EmitEvidence(cfg), KindManifest, "publish failed: [Errno 17] atomic publication failed: PosixPath('"+root+"/dest')")
	if !errors.Is(he, syscall.EEXIST) {
		t.Errorf("the errno is not reachable: %v", he.Unwrap())
	}
	if stderr.Len() != 0 {
		t.Errorf("a failed publish must not print the pointer: %q", stderr.String())
	}
	// A failure with no errno keeps its own text.
	cfg2, _ := emitFixture(t)
	cfg2.Run = (&fakeRun{}).run
	boom := errors.New("atomic no-replace publication is unavailable")
	old := publishFn
	publishFn = func(string, string) error { return boom }
	defer func() { publishFn = old }()
	he = asKind(t, EmitEvidence(cfg2), KindManifest, "publish failed: atomic no-replace publication is unavailable")
	if !errors.Is(he, boom) {
		t.Errorf("cause lost: %v", he.Unwrap())
	}
}

func TestEmitEvidenceGuardsRunBeforeAnyWrite(t *testing.T) {
	cfg, root := emitFixture(t)
	f := &fakeRun{}
	cfg.Run = f.run
	cfg.Schema = "../evil"
	asKind(t, EmitEvidence(cfg), KindManifest, `unsafe schema identifier (must match ^[A-Za-z0-9][A-Za-z0-9._-]*$): '../evil'`)
	cfg.Schema = "ok"
	cfg.Domain = map[string]any{"status": 1, "errors": 1, "fine": 1}
	asKind(t, EmitEvidence(cfg), KindManifest, `domain overrides reserved envelope key(s): ['errors', 'status']`)
	entries, _ := os.ReadDir(root + "/stage")
	if len(f.specs) != 0 || len(entries) != 1 {
		t.Errorf("guards must refuse before touching anything: runs %d, stage %v", len(f.specs), entries)
	}
}

func TestEmitEvidenceRawFilesystemErrors(t *testing.T) {
	cfg, root := emitFixture(t)
	cfg.Run = (&fakeRun{}).run
	cfg.Stage = root + "/missing"
	err := EmitEvidence(cfg)
	var he *Error
	if err == nil || errors.As(err, &he) {
		t.Fatalf("got %v, want a raw filesystem error", err)
	}
	cfg2, root2 := emitFixture(t)
	if err := os.Remove(root2 + "/stage/engine"); err != nil {
		t.Fatal(err)
	}
	cfg2.Run = (&fakeRun{}).run
	if err := EmitEvidence(cfg2); err == nil || errors.As(err, &he) {
		t.Fatalf("got %v, want a raw filesystem error", err)
	}
	cfg3, _ := emitFixture(t)
	cfg3.ManifestSpec = make(chan int)
	cfg3.Run = (&fakeRun{}).run
	if err := EmitEvidence(cfg3); err == nil || errors.As(err, &he) {
		t.Fatalf("got %v, want a raw encoding error", err)
	}
	cfg4, _ := emitFixture(t)
	cfg4.InputIdentity = make(chan int)
	cfg4.Run = (&fakeRun{}).run
	if err := EmitEvidence(cfg4); err == nil || errors.As(err, &he) {
		t.Fatalf("got %v, want a raw encoding error", err)
	}
	// create deleting the spec makes the unlink fail raw.
	cfg5, root5 := emitFixture(t)
	cfg5.Run = (&fakeRun{onCall: func(i int, s proc.Spec) { _ = os.Remove(root5 + "/stage/engine/manifest-spec.json") }}).run
	if err := EmitEvidence(cfg5); err == nil || errors.As(err, &he) || !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("got %v, want a raw not-exist error", err)
	}
}

func TestEmitEvidenceNormalizesTheStagePathLikePathlib(t *testing.T) {
	cfg, root := emitFixture(t)
	t.Chdir(root + "/stage")
	f := &fakeRun{}
	cfg.Run, cfg.Stage, cfg.Destination = f.run, ".", "dest"
	old := publishFn
	publishFn = func(stage, dest string) error {
		if stage != "." || dest != "dest" {
			t.Errorf("publish(%q, %q)", stage, dest)
		}
		return nil
	}
	defer func() { publishFn = old }()
	if err := EmitEvidence(cfg); err != nil {
		t.Fatal(err)
	}
	want := []string{"/py", "/cli.py", "create", "--root", ".", "--spec", "engine/manifest-spec.json", "--output", "engine/analysis-manifest.v1.json"}
	if !reflect.DeepEqual(f.specs[0].Argv, want) {
		t.Errorf("argv\n got  %q\n want %q", f.specs[0].Argv, want)
	}
}
