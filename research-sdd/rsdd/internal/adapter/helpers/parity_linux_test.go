//go:build linux

package helpers

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"testing"
)

// pyOut is one case result of testdata/parity_driver.py.
type pyOut struct {
	OK      bool            `json:"ok"`
	Class   string          `json:"class"`
	Msg     string          `json:"msg"`
	Cause   string          `json:"cause"`
	Adapter bool            `json:"adapter"`
	Value   json.RawMessage `json:"value"`
	Stderr  string          `json:"stderr"`
}

const toolbeltDir = "../../../../toolbelt"

func pythonPath(t *testing.T) string {
	t.Helper()
	py, err := exec.LookPath("python3")
	if err != nil {
		t.Fatalf("python3 is required for the parity tests and was not found: %v", err)
	}
	return py
}

// runPy runs the real Python adapter_helpers through the driver for a batch of
// cases. A missing python3 FAILS the test: a skipped parity test proves nothing.
func runPy(t *testing.T, op string, cases any) []pyOut {
	t.Helper()
	py := pythonPath(t)
	tb, err := filepath.Abs(toolbeltDir)
	if err != nil {
		t.Fatal(err)
	}
	in, err := json.Marshal(cases)
	if err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command(py, "-I", "testdata/parity_driver.py", tb, op)
	var out, stderr bytes.Buffer
	cmd.Stdin, cmd.Stdout, cmd.Stderr = bytes.NewReader(in), &out, &stderr
	if err := cmd.Run(); err != nil {
		t.Fatalf("driver %s failed: %v\n%s", op, err, stderr.String())
	}
	var rs []pyOut
	if err := json.Unmarshal(out.Bytes(), &rs); err != nil {
		t.Fatalf("driver output %q: %v", out.String(), err)
	}
	if len(rs) != len(cases.([]map[string]any)) {
		t.Fatalf("driver %s returned %d results for %d cases", op, len(rs), len(cases.([]map[string]any)))
	}
	return rs
}

func value(t *testing.T, o pyOut, into any) {
	t.Helper()
	if !o.OK {
		t.Fatalf("python raised %s: %s", o.Class, o.Msg)
	}
	if err := json.Unmarshal(o.Value, into); err != nil {
		t.Fatal(err)
	}
}

// sameFailure requires the Go outcome to equal the Python one: success, or the
// same exception class and message. A Python class that is an AdapterError
// subclass must be a *Error of the same Kind; any other class must not be.
func sameFailure(t *testing.T, label string, py pyOut, goErr error, norm func(string) string) bool {
	t.Helper()
	if py.OK {
		if goErr != nil {
			t.Errorf("%s: python ok, go error %v", label, goErr)
		}
		return goErr == nil
	}
	if goErr == nil {
		t.Errorf("%s: python %s(%q), go ok", label, py.Class, py.Msg)
		return false
	}
	var he *Error
	if !errors.As(goErr, &he) {
		if py.Adapter {
			t.Errorf("%s: python %s, go %T (%v)", label, py.Class, goErr, goErr)
			return false
		}
		return true // a raw OSError: the class family is all Go can share
	}
	if string(he.Kind) != py.Class {
		t.Errorf("%s: class python %s, go %s", label, py.Class, he.Kind)
		return false
	}
	if he.Error() != norm(py.Msg) {
		t.Errorf("%s: message\n python %q\n go     %q", label, norm(py.Msg), he.Error())
		return false
	}
	var cause *Error
	goCause := ""
	if errors.As(he.Unwrap(), &cause) {
		goCause = string(cause.Kind)
	}
	switch Kind(py.Cause) {
	case KindManifest, KindVenvBind, KindBindScope:
		if goCause != py.Cause {
			t.Errorf("%s: cause python %s, go %q", label, py.Cause, goCause)
			return false
		}
	}
	if py.Cause == "" && he.Unwrap() != nil {
		t.Errorf("%s: python has no cause, go has %v", label, he.Unwrap())
	}
	return true
}

func ident(s string) string { return s }

func TestParityPathHelpers(t *testing.T) {
	strs := []string{"", ".", "/", "//", "///", "//a", "///a/b", "a", "a/", "a//b/./c", "/a/./b/", "/a/../b", "../a", "a/..",
		"/tmp/rsdd/../etc/evil", "/tmp/rsdd//subdir", "//tmp/rsdd/x", "///tmp/rsdd/x", "/tmp/rsdd/", "/tmp/rsdd", "/../x", "/..", "..", "a/../..",
		"it's", "say \"hi\"", "it's \"x\"", "tab\there", "nl\nx", "\\", "\x00", "\x7f", "é", "\u200b", " ", "\U0001F600", "\xc2\xa0", "x\x1fy",
		"\u00ad", "\u0378", "\ue000", "\U000e0001", "\u2028", "\U00010000", "Z", "/Z", "ZZ/Za", "a\rb", "\r", "Z/", "\u0080", "\u009f", "\u00a0", "\u00ff", "\u0100", "\uffff", "\uffff\U0010ffff", "\ufeff", "\U0001fffe"}
	var cases []map[string]any
	for _, s := range strs {
		cases = append(cases, map[string]any{"s": s})
	}
	eq := func(name string, got func(string) any) {
		rs := runPy(t, name, cases)
		for i, s := range strs {
			var want any
			value(t, rs[i], &want)
			gb, _ := json.Marshal(got(s))
			var gv any
			_ = json.Unmarshal(gb, &gv)
			if !reflect.DeepEqual(gv, want) {
				t.Errorf("%s(%q): python %v, go %v", name, s, want, gv)
			}
		}
	}
	nz := func(s []string) []string {
		if s == nil {
			return []string{}
		}
		return s
	}
	eq("parts", func(s string) any { return nz(pyParts(s)) })
	eq("norm", func(s string) any { return pyNorm(s) })
	eq("repr", func(s string) any { return pyRepr(s) })
	eq("normpath", func(s string) any { return pyNormpath(s) })
}

// tree is the symlink fixture shared by the realpath, venv and bind tests.
func tree(t *testing.T) string {
	t.Helper()
	dir, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	must := func(err error) {
		if err != nil {
			t.Fatal(err)
		}
	}
	must(os.MkdirAll(filepath.Join(dir, "real/sub"), 0o755))
	must(os.WriteFile(filepath.Join(dir, "real/file"), []byte("data"), 0o644))
	must(os.Symlink("real", filepath.Join(dir, "lnk")))
	must(os.Symlink(filepath.Join(dir, "real"), filepath.Join(dir, "abs")))
	must(os.Symlink("lnk", filepath.Join(dir, "chain")))
	must(os.Symlink("loop2", filepath.Join(dir, "loop1")))
	must(os.Symlink("loop1", filepath.Join(dir, "loop2")))
	must(os.Symlink("self", filepath.Join(dir, "self")))
	must(os.Symlink("nowhere", filepath.Join(dir, "dangling")))
	must(os.Symlink("real/file", filepath.Join(dir, "filelnk")))
	must(os.Symlink("../real", filepath.Join(dir, "real/sub/up")))
	must(os.Symlink("/", filepath.Join(dir, "toroot")))
	return dir
}

var pathProbes = []string{
	"", ".", "/", "//", "real", "real/", "real/file", "real/file/x", "real/./sub/../file", "real/sub/..",
	"lnk", "lnk/file", "lnk/", "abs", "abs/file", "chain/file", "loop1", "loop1/x", "self", "self/x", "dangling", "dangling/x",
	"dangling/../real", "nope", "nope/x", "nope/../real", "real/nope/../file", "filelnk", "filelnk/x", "real/sub/up", "real/sub/up/file",
	"real/sub/up/../lnk", "toroot", "toroot/usr", "..", "../x", "lnk/..", "lnk/../real", "lnk/../lnk/file", "loop1/../loop1",
	"abs/../abs/file", "real//file", "//real", "Z", "/Z", "nopeZ", "real/Z", "real/ZZ//", "/a/..", "/..", "/../..", "/a/b/../..", "/a/../b", "/a/b/../c", "/real/..", "/./",
}

func TestParityRealpath(t *testing.T) {
	dir := tree(t)
	var in []map[string]any
	var cwds []string
	add := func(p, cwd string) {
		in = append(in, map[string]any{"path": p, "cwd": cwd})
		cwds = append(cwds, cwd)
	}
	for _, p := range pathProbes {
		add(p, dir)
		add(filepath.Join(dir, "x")+"/../"+p, dir)
		if p != "" && !strings.HasPrefix(p, "/") && !strings.HasPrefix(p, "..") {
			add(dir+"/"+p, "/")
		}
	}
	add("/usr/bin/../lib", "/")
	rs := runPy(t, "realpath", in)
	for i, c := range in {
		got, err := realpath(c["path"].(string), cwds[i])
		if err != nil || !rs[i].OK {
			t.Errorf("realpath(%q, cwd %q): python ok=%v, go err=%v", c["path"], cwds[i], rs[i].OK, err)
			continue
		}
		var want string
		value(t, rs[i], &want)
		if got != want {
			t.Errorf("realpath(%q, cwd %q): python %q, go %q", c["path"], cwds[i], want, got)
		}
	}
}

func TestParitySchemaRegex(t *testing.T) {
	strs := []string{"", "a", "A9", "0", "a.b", "a_b-c", ".a", "-a", "_a", "a b", "a/b", "../x", "a\n", "a\n\n", "\na", "a\nb", "a\x00", "é", "aé", "\u0663", "a.v1", "x\r", "aB", "a_B", "a-B", "a.B", "zZ", "A", "Z9"}
	var cases []map[string]any
	for _, s := range strs {
		cases = append(cases, map[string]any{"s": s})
	}
	rs := runPy(t, "schema", cases)
	for i, s := range strs {
		var want bool
		value(t, rs[i], &want)
		if got := safeSchema(s); got != want {
			t.Errorf("schema %q: python %v, go %v", s, want, got)
		}
	}
}

func TestParityPcapMagic(t *testing.T) {
	rs := runPy(t, "consts", []map[string]any{{}})
	var want struct {
		Pcap   []string `json:"pcap"`
		Pcapng string   `json:"pcapng"`
	}
	value(t, rs[0], &want)
	var got []string
	for _, m := range PcapMagic {
		got = append(got, fmt.Sprintf("%x", m))
	}
	sort.Strings(got)
	if !reflect.DeepEqual(got, want.Pcap) || fmt.Sprintf("%x", PcapngMagic) != want.Pcapng {
		t.Errorf("python %v %s, go %v %x", want.Pcap, want.Pcapng, got, PcapngMagic)
	}
}

func TestParityRunTruncation(t *testing.T) {
	lists := [][]string{nil, {}, {"timeout"}, {"output-cap"}, {"process-cap"}, {"analyzer-exit:1"}, {"timeout", "output-cap", "process-cap"},
		{"process-cap", "timeout"}, {"timeout", "timeout"}, {"output-cap", "analyzer-exit:2"}, {"TIMEOUT"}, {"timeout "}, {"process-cap", "output-cap"}}
	var cases []map[string]any
	for _, l := range lists {
		if l == nil {
			l = []string{}
		}
		cases = append(cases, map[string]any{"errors": l, "tool": "té x"})
	}
	rs := runPy(t, "trunc", cases)
	for i, l := range lists {
		var want []any
		value(t, rs[i], &want)
		flag, lims := RunTruncation(l, "té x")
		gl := make([]any, len(lims))
		for j := range lims {
			gl[j] = lims[j]
		}
		if want[0].(bool) != flag || !reflect.DeepEqual(want[1], any(gl)) {
			t.Errorf("RunTruncation(%q): python %v, go %v %v", l, want, flag, gl)
		}
	}
}

func TestParityWarnEvidence(t *testing.T) {
	type c struct{ schema, dest, detail string }
	cs := []c{{"s.v1", "/d", ""}, {"s.v1", "/d", "analyzer-exit:1"}, {"é", "a//b/", "x, y"}, {"", "", ""}, {"s", ".", " "}}
	var cases []map[string]any
	for _, x := range cs {
		cases = append(cases, map[string]any{"schema": x.schema, "dest": x.dest, "detail": x.detail})
	}
	rs := runPy(t, "warn", cases)
	for i, x := range cs {
		var want string
		value(t, rs[i], &want)
		var buf bytes.Buffer
		WarnEvidence(&buf, x.schema, x.dest, x.detail)
		if buf.String() != want {
			t.Errorf("WarnEvidence(%+v): python %q, go %q", x, want, buf.String())
		}
	}
}

// safeBindCases are (path, HOME) pairs; the fixture-relative ones use the
// "@" prefix for the fixture directory.
func safeBindCases(dir string) [][2]string {
	var cs [][2]string
	for _, p := range []string{"/", "/home", "/home/someuser", "/root", "/usr", "/tmp", "/etc", "/bin", "/sbin", "/lib", "/lib64", "/proc", "/sys",
		"/dev", "/run", "/home/x/.local/share/y", "/home/linuxbrew/.linuxbrew/Cellar/python/3.11", "/opt/myapp/venvs/capa", "/home/alice/venvs",
		"/root/myvenv", "/a/b/c", "/a/b", "/a", "", ".", "a/b/c", "/home/u/", "/home/u/x/", "//home/u/x", "//a/b/c", "///a/b/c", "/tmp/",
		"/usr/", "/home/./u/x/y", "/home/u/../v/x", "/Home/u/x", "/homes/u/x", "/home//u/x", "/etc/../usr"} {
		for _, h := range []string{"/home/me", "/nonexistent/h/ome", "/home/u/x/y"} {
			cs = append(cs, [2]string{p, h})
		}
	}
	for _, p := range []string{dir + "/real", dir + "/abs", dir + "/lnk", dir + "/real/sub", dir + "/nope/x"} {
		for _, h := range []string{dir + "/real", dir + "/lnk", dir + "/abs", dir + "/chain", dir + "/real/", "/", dir + "/loop1", "relative/h"} {
			cs = append(cs, [2]string{p, h})
		}
	}
	return cs
}

func TestParityAssertSafeBindRoot(t *testing.T) {
	dir := tree(t)
	cs := safeBindCases(dir)
	var cases []map[string]any
	for _, c := range cs {
		cases = append(cases, map[string]any{"path": c[0], "home": c[1], "cwd": dir})
	}
	rs := runPy(t, "safe_bind", cases)
	for i, c := range cs {
		home := strings.TrimRight(c[1], "/")
		if home == "" {
			home = "/"
		}
		sameFailure(t, "safe_bind"+jsonString(c), rs[i], AssertSafeBindRoot(Env{Cwd: dir, Home: home}, c[0]), ident)
	}
}

func jsonString(v any) string { b, _ := json.Marshal(v); return string(b) }

// venv fixture: a real venv, a venv behind a symlinked bin/tool, and the
// shapes venv_root_for refuses.
func venvFixture(t *testing.T) string {
	t.Helper()
	dir := tree(t)
	must := func(err error) {
		if err != nil {
			t.Fatal(err)
		}
	}
	mkexe := func(rel string, cfg bool) {
		must(os.MkdirAll(filepath.Join(dir, rel, "bin"), 0o755))
		must(os.WriteFile(filepath.Join(dir, rel, "bin", "tool"), nil, 0o755))
		if cfg {
			must(os.WriteFile(filepath.Join(dir, rel, "pyvenv.cfg"), []byte("[python]\n"), 0o644))
		}
	}
	mkexe("v/ok", true)
	mkexe("v/nocfg", false)
	must(os.MkdirAll(filepath.Join(dir, "v/cfgdir/bin"), 0o755))
	must(os.MkdirAll(filepath.Join(dir, "v/cfgdir/pyvenv.cfg"), 0o755))
	must(os.WriteFile(filepath.Join(dir, "v/cfgdir/bin/tool"), nil, 0o755))
	must(os.MkdirAll(filepath.Join(dir, "v/cfgdev/bin"), 0o755))
	must(os.Symlink("/dev/null", filepath.Join(dir, "v/cfgdev/pyvenv.cfg")))
	must(os.WriteFile(filepath.Join(dir, "v/cfgdev/bin/tool"), nil, 0o755))
	must(os.MkdirAll(filepath.Join(dir, "v/cfglink/bin"), 0o755))
	must(os.Symlink("../ok/pyvenv.cfg", filepath.Join(dir, "v/cfglink/pyvenv.cfg")))
	must(os.Symlink(filepath.Join(dir, "v/ok/bin/tool"), filepath.Join(dir, "v/cfglink/bin/tool")))
	must(os.MkdirAll(filepath.Join(dir, "wrap"), 0o755))
	must(os.Symlink(filepath.Join(dir, "v/ok/bin/tool"), filepath.Join(dir, "wrap/tool")))
	must(os.Symlink(filepath.Join(dir, "v/ok/bin"), filepath.Join(dir, "binlink")))
	return dir
}

func TestParityVenvRootFor(t *testing.T) {
	dir := venvFixture(t)
	paths := []string{dir + "/v/ok/bin/tool", dir + "/v/ok/bin/missing", dir + "/v/nocfg/bin/tool", dir + "/v/cfgdir/bin/tool", dir + "/v/cfgdev/bin/tool", dir + "/v/cfglink/bin/tool",
		dir + "/wrap/tool", dir + "/binlink/tool", dir + "/v/ok/tool", dir + "/v/ok/bin", dir + "/v/ok/bin/", "v/ok/bin/tool", "./v/ok/bin/tool", "wrap/tool",
		dir + "/v/ok/../ok/bin/tool", dir + "//v/ok/bin/tool", "/usr/bin/tool", "/bin/tool", "/home/someuser/bin/tool", "/home/u/v/bin/tool", "/x/y/bin/tool",
		"/bin", "/", "", "tool", "/a/bin/tool", "/a/b/bin/tool", "/nonexistent/venvs/x/bin/tool", "/home/me/bin/tool", "/home/me/x/bin/tool",
		"/lib/bin/tool", "/sys/bin/x", "/root/bin/tool", "/dev/bin/tool"}
	for _, home := range []string{"/home/me", dir + "/v/ok"} {
		var cases []map[string]any
		for _, p := range paths {
			cases = append(cases, map[string]any{"path": p, "cwd": dir, "home": home})
		}
		rs := runPy(t, "venv_root", cases)
		for i, p := range paths {
			got, err := VenvRootFor(Env{Cwd: dir, Home: home}, p)
			if !sameFailure(t, "venv_root("+p+" home "+home+")", rs[i], err, func(s string) string { return strings.ReplaceAll(s, dir, dir) }) {
				continue
			}
			if rs[i].OK {
				var want string
				value(t, rs[i], &want)
				if got != want {
					t.Errorf("venv_root(%q): python %q, go %q", p, want, got)
				}
			}
		}
	}
}

func TestParityBindVenv(t *testing.T) {
	dir := venvFixture(t)
	must := func(err error) {
		if err != nil {
			t.Fatal(err)
		}
	}
	must(os.MkdirAll(filepath.Join(dir, "w/dir"), 0o755))
	must(os.WriteFile(filepath.Join(dir, "w/file"), nil, 0o644))
	must(os.Symlink("dir", filepath.Join(dir, "w/dlink")))
	tool := dir + "/v/ok/bin/tool"
	wd := dir + "/w/dir"
	type c struct {
		prefix []string
		tool   string
		etc    []string
		w      [][2]string
	}
	cs := []c{
		{[]string{"bwrap", "--"}, tool, nil, nil},
		{[]string{"bwrap", "--ro-bind", "/a", "/a", "--"}, tool, nil, nil},
		{[]string{"--"}, tool, nil, nil},
		{nil, tool, nil, nil},
		{[]string{}, tool, nil, nil},
		{[]string{"bwrap"}, tool, nil, nil},
		{[]string{"bwrap", "--", "x"}, tool, nil, nil},
		{[]string{"bwrap", "--"}, "/usr/bin/tool", nil, nil},
		{[]string{"bwrap", "--"}, dir + "/v/nocfg/bin/tool", nil, nil},
		{[]string{"bwrap", "--"}, "/usr/bin/tool", []string{"/etc/shadow"}, nil},
		{[]string{"bwrap"}, "/usr/bin/tool", []string{"/etc/shadow"}, [][2]string{{wd, "/x"}}},
		{[]string{"bwrap", "--"}, tool, []string{"/etc/passwd"}, nil},
		{[]string{"bwrap", "--"}, tool, []string{"/etc/group", "/etc/passwd"}, nil},
		{[]string{"bwrap", "--"}, tool, []string{"/etc/passwd", "/etc/passwd"}, nil},
		{[]string{"bwrap", "--"}, tool, []string{"/etc/shadow"}, nil},
		{[]string{"bwrap", "--"}, tool, []string{"/etc/passwd", "/etc/shadow"}, nil},
		{[]string{"bwrap", "--"}, tool, []string{"/etc/shadow", "/etc/passwd"}, nil},
		{[]string{"bwrap", "--"}, tool, []string{"/etc/passwd/"}, nil},
		{[]string{"bwrap", "--"}, tool, []string{"it's"}, nil},
		{[]string{"bwrap", "--"}, tool, []string{"/etc/shadow"}, [][2]string{{wd, "/bad"}}},
		{[]string{"bwrap", "--"}, tool, nil, [][2]string{{wd, "/tmp/rsdd/out"}}},
		{[]string{"bwrap", "--"}, tool, []string{"/etc/passwd"}, [][2]string{{wd, "/tmp/rsdd/out"}, {wd + "/", "/tmp/rsdd/o2/"}}},
		{[]string{"bwrap", "--"}, tool, nil, [][2]string{{wd, "/tmp/rsdd/../etc/evil"}}},
		{[]string{"bwrap", "--"}, tool, nil, [][2]string{{wd, "/tmp/rsdd//subdir"}}},
		{[]string{"bwrap", "--"}, tool, nil, [][2]string{{wd, "/tmp/rsdd/./a/../b"}}},
		{[]string{"bwrap", "--"}, tool, nil, [][2]string{{wd, "/tmp/rsdd"}}},
		{[]string{"bwrap", "--"}, tool, nil, [][2]string{{wd, "/tmp/rsdd/"}}},
		{[]string{"bwrap", "--"}, tool, nil, [][2]string{{wd, "//tmp/rsdd/x"}}},
		{[]string{"bwrap", "--"}, tool, nil, [][2]string{{wd, "///tmp/rsdd/x"}}},
		{[]string{"bwrap", "--"}, tool, nil, [][2]string{{wd, "tmp/rsdd/x"}}},
		{[]string{"bwrap", "--"}, tool, nil, [][2]string{{wd, ""}}},
		{[]string{"bwrap", "--"}, tool, nil, [][2]string{{wd, "/tmp/rsddx/y"}}},
		{[]string{"bwrap", "--"}, tool, nil, [][2]string{{wd, "/tmp/rsdd/it's"}}},
		{[]string{"bwrap", "--"}, tool, nil, [][2]string{{dir + "/w/missing", "/tmp/rsdd/m"}}},
		{[]string{"bwrap", "--"}, tool, nil, [][2]string{{dir + "/w/file", "/tmp/rsdd/f"}}},
		{[]string{"bwrap", "--"}, tool, nil, [][2]string{{dir + "/w/dlink", "/tmp/rsdd/l"}}},
		{[]string{"bwrap", "--"}, tool, nil, [][2]string{{dir + "/w/dlink/", "/tmp/rsdd/l"}}},
		{[]string{"bwrap", "--"}, tool, nil, [][2]string{{dir + "/w/missing", "/bad"}}},
		{[]string{"bwrap", "--"}, tool, nil, [][2]string{{dir + "/w/file", "/bad"}}},
		{[]string{"bwrap", "--"}, tool, nil, [][2]string{{dir + "//w/./dir/", "/tmp/rsdd/n"}}},
		{[]string{"bwrap", "--"}, tool, nil, [][2]string{{wd, "/tmp/rsdd/a"}, {dir + "/w/file", "/tmp/rsdd/b"}, {wd, "/bad"}}},
		{[]string{"bwrap", "--"}, tool, nil, [][2]string{{wd, "/tmp/rsdd/a"}, {wd, "/tmp/rsdd/b"}}},
		{[]string{"bwrap", "--"}, dir + "/wrap/tool", nil, nil},
		{[]string{"bwrap", "--"}, "v/ok/bin/tool", nil, nil},
	}
	var cases []map[string]any
	for _, x := range cs {
		etc := x.etc
		if etc == nil {
			etc = []string{}
		}
		writable := make([][]string, 0, len(x.w))
		for _, p := range x.w {
			writable = append(writable, []string{p[0], p[1]})
		}
		cases = append(cases, map[string]any{"prefix": x.prefix, "path": x.tool, "etc": etc, "writable": writable, "cwd": dir, "home": "/home/me"})
	}
	rs := runPy(t, "bind", cases)
	for i, x := range cs {
		var w []Writable
		for _, p := range x.w {
			w = append(w, Writable{p[0], p[1]})
		}
		got, err := BindVenv(Env{Cwd: dir, Home: "/home/me"}, x.prefix, x.tool, x.etc, w)
		label := "bind" + jsonString(x)
		if !sameFailure(t, label, rs[i], err, ident) || !rs[i].OK {
			continue
		}
		var want []string
		value(t, rs[i], &want)
		if !reflect.DeepEqual(got, want) {
			t.Errorf("%s: argv\n python %q\n go     %q", label, want, got)
		}
	}
}

const stubScript = `import json, os, sys, time
d = os.path.dirname(os.path.abspath(__file__))
cfg = json.load(open(os.path.join(d, "cfg.json")))
verb = sys.argv[1]
with open(os.path.join(d, "log.jsonl"), "a") as f:
    f.write(json.dumps(sys.argv[1:]) + "\n")
act = cfg.get(verb)
if act == "sleep":
    time.sleep(30)
elif act == "kill":
    os.kill(os.getpid(), 9)
elif act == "rmspec":
    os.remove(sys.argv[sys.argv.index("--spec") + 1])
elif isinstance(act, int):
    sys.exit(act)
if verb == "create":
    open(sys.argv[sys.argv.index("--output") + 1], "w").write("{}")
`

type emitCase struct {
	name        string
	schema      string
	domain      map[string]any
	errors      []string
	limitations []string
	timeout     int
	cfg         map[string]any
	dest        string
	noStage     bool
	noEngine    bool
	destExists  bool
	noDestDir   bool
}

func (c emitCase) prep(t *testing.T, root string) {
	t.Helper()
	must := func(err error) {
		if err != nil {
			t.Fatal(err)
		}
	}
	must(os.MkdirAll(filepath.Join(root, "stub"), 0o755))
	must(os.WriteFile(filepath.Join(root, "stub/stub.py"), []byte(stubScript), 0o644))
	cfg, _ := json.Marshal(orEmpty(c.cfg))
	must(os.WriteFile(filepath.Join(root, "stub/cfg.json"), cfg, 0o644))
	if !c.noStage {
		must(os.MkdirAll(filepath.Join(root, "stage"), 0o755))
		must(os.WriteFile(filepath.Join(root, "stage/payload.txt"), []byte("payload\n"), 0o644))
		if !c.noEngine {
			must(os.MkdirAll(filepath.Join(root, "stage/engine"), 0o755))
		}
	}
	dest := c.destPath(root)
	if !c.noDestDir {
		must(os.MkdirAll(filepath.Dir(filepath.Clean(dest)), 0o755))
	}
	if c.destExists {
		must(os.MkdirAll(dest, 0o755))
	}
}

func (c emitCase) destPath(root string) string {
	d := c.dest
	if d == "" {
		d = "out/dest"
	}
	return root + "/" + d
}

// snapshot is every file under root, keyed by its root-relative path, with the
// root replaced by "<R>" in the contents.
func snapshot(t *testing.T, root string) map[string]string {
	t.Helper()
	m := map[string]string{}
	err := filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(root, p)
		if d.IsDir() {
			m[rel+"/"] = ""
			return nil
		}
		b, err := os.ReadFile(p)
		if err != nil {
			return err
		}
		m[rel] = strings.ReplaceAll(string(b), root, "<R>")
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	delete(m, "./")
	return m
}

func TestParityEmitEvidence(t *testing.T) {
	big := map[string]any{"z": 1, "a": []any{"é", "\U0001F600", 1.5, nil, true}, "m": map[string]any{"k": "v<>&"}}
	cases := []emitCase{
		{name: "success", schema: "pcap-evidence.v1", domain: map[string]any{"flows": 3, "name": "n"}, timeout: 30},
		{name: "success-non-ascii-and-nesting", schema: "x.v1", domain: big, limitations: []string{"lé", "two"}, timeout: 30},
		{name: "errors-warn-pointer", schema: "native-static.v1", errors: []string{"analyzer-exit:1", "timeout"}, timeout: 30},
		{name: "errors-warn-denormalized-dest", schema: "s.v1", errors: []string{"e"}, dest: "out//dest/", timeout: 30},
		{name: "dest-dot-segments", schema: "s.v1", dest: "out/./dest", timeout: 30, errors: []string{"e"}},
		{name: "default-timeout-sixty", schema: "s.v1", timeout: 60},
		{name: "create-fails", schema: "s.v1", cfg: map[string]any{"create": 3}, timeout: 30},
		{name: "validate-fails", schema: "s.v1", cfg: map[string]any{"validate": 4}, timeout: 30},
		{name: "verify-fails", schema: "s.v1", cfg: map[string]any{"verify": 5}, timeout: 30},
		{name: "validate-killed-by-signal", schema: "s.v1", cfg: map[string]any{"validate": "kill"}, timeout: 30},
		{name: "verify-times-out", schema: "s.v1", cfg: map[string]any{"verify": "sleep"}, timeout: 1},
		{name: "cli-removes-the-spec", schema: "s.v1", cfg: map[string]any{"create": "rmspec"}, timeout: 30},
		{name: "unsafe-schema-dotdot", schema: "../evil", timeout: 30},
		{name: "unsafe-schema-slash", schema: "a/b", timeout: 30},
		{name: "unsafe-schema-empty", schema: "", timeout: 30},
		{name: "unsafe-schema-leading-dot", schema: ".hidden", timeout: 30},
		{name: "unsafe-schema-quote", schema: "it's", timeout: 30},
		{name: "schema-with-trailing-newline-is-accepted", schema: "nl.v1\n", timeout: 30},
		{name: "reserved-key-one", schema: "s.v1", domain: map[string]any{"status": "x"}, timeout: 30},
		{name: "reserved-keys-all-sorted", schema: "s.v1", domain: map[string]any{"schema": 1, "status": 1, "input": 1, "isolation": 1, "limitations": 1, "errors": 1, "ok": 1}, timeout: 30},
		{name: "reserved-key-before-unsafe-schema-order", schema: "../x", domain: map[string]any{"errors": 1}, timeout: 30},
		{name: "no-stage", schema: "s.v1", noStage: true, timeout: 30},
		{name: "no-engine-dir", schema: "s.v1", noEngine: true, timeout: 30},
		{name: "dest-exists", schema: "s.v1", destExists: true, timeout: 30},
		{name: "dest-parent-missing", schema: "s.v1", noDestDir: true, dest: "nope/dest", timeout: 30},
		{name: "dest-exists-with-errors-no-pointer", schema: "s.v1", destExists: true, errors: []string{"e"}, timeout: 30},
	}
	py := pythonPath(t)
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			// Parallel, one driver per case: the cases are independent and spend
			// their time in child processes (the driver's redirect_stderr is
			// process-global, so it cannot run cases concurrently itself).
			t.Parallel()
			pyBase, err := filepath.EvalSymlinks(t.TempDir())
			if err != nil {
				t.Fatal(err)
			}
			pyRoot := filepath.Join(pyBase, "py")
			if err := os.Mkdir(pyRoot, 0o755); err != nil {
				t.Fatal(err)
			}
			c.prep(t, pyRoot)
			rs := runPy(t, "emit", []map[string]any{{"root": pyRoot, "schema": c.schema, "domain": orEmpty(c.domain), "input": map[string]any{"source": "s"},
				"isolation": map[string]any{"launcher": "l"}, "limitations": strs(c.limitations), "errors": strs(c.errors), "spec": map[string]any{"dummy": 1},
				"timeout": c.timeout, "dest": destRel(c)}})
			base, err := filepath.EvalSymlinks(t.TempDir())
			if err != nil {
				t.Fatal(err)
			}
			root := filepath.Join(base, "py")
			if err := os.Mkdir(root, 0o755); err != nil {
				t.Fatal(err)
			}
			c.prep(t, root)
			var stderr bytes.Buffer
			err = EmitEvidence(EmitConfig{
				Stage: root + "/stage", Schema: c.schema, Domain: orEmpty(c.domain), InputIdentity: map[string]any{"source": "s"},
				Isolation: map[string]any{"launcher": "l"}, Limitations: strs(c.limitations), Errors: strs(c.errors), ManifestSpec: map[string]any{"dummy": 1},
				ManifestCLI: []string{py, root + "/stub/stub.py"}, Destination: root + "/" + destRel(c), Timeout: c.timeout, Env: os.Environ(), Stderr: &stderr,
			})
			norm := func(s string) string { return strings.ReplaceAll(s, pyRoot, root) }
			sameFailure(t, c.name, rs[0], err, norm)
			if want := norm(rs[0].Stderr); stderr.String() != want {
				t.Errorf("stderr\n python %q\n go     %q", want, stderr.String())
			}
			// Python's own tree is read after the driver ran, the Go one after Go.
			gotTree, wantTree := snapshot(t, root), snapshot(t, pyRoot)
			if !reflect.DeepEqual(gotTree, wantTree) {
				t.Errorf("tree differs\n python %v\n go     %v", wantTree, gotTree)
			}
		})
	}
}

func orEmpty(m map[string]any) map[string]any {
	if m == nil {
		return map[string]any{}
	}
	return m
}

func strs(s []string) []string {
	if s == nil {
		return []string{}
	}
	return s
}

func destRel(c emitCase) string {
	if c.dest == "" {
		return "out/dest"
	}
	return c.dest
}
