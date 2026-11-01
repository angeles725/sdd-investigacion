//go:build linux

package adapter

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

// pyOut is one case result of testdata/parity_driver.py.
type pyOut struct {
	OK    bool            `json:"ok"`
	Class string          `json:"class"`
	Msg   string          `json:"msg"`
	Value json.RawMessage `json:"value"`
}

const toolbeltDir = "../../../toolbelt"

// runPy runs the real Python adapter_core through the driver for a batch of
// cases. A missing python3 FAILS the test: a skipped parity test proves nothing.
func runPy(t *testing.T, op string, cases any) []pyOut {
	t.Helper()
	py, err := exec.LookPath("python3")
	if err != nil {
		t.Fatalf("python3 is required for the parity tests and was not found: %v", err)
	}
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
	return rs
}

// class names the Python exception class a Go error corresponds to.
func class(err error) string {
	if err == nil {
		return ""
	}
	var ae *Error
	if errors.As(err, &ae) {
		return "AdapterError"
	}
	return "OSError"
}

// sameFailure requires the Go outcome to equal the Python one: success, or the
// same class and (for AdapterError) the same message.
func sameFailure(t *testing.T, label string, py pyOut, goErr error) bool {
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
	pyClass := py.Class
	if pyClass != "AdapterError" {
		pyClass = "OSError"
	}
	if class(goErr) != pyClass {
		t.Errorf("%s: class python %s, go %s (%v)", label, py.Class, class(goErr), goErr)
		return false
	}
	if pyClass == "AdapterError" && goErr.Error() != py.Msg {
		t.Errorf("%s: message\n python %q\n go     %q", label, py.Msg, goErr.Error())
		return false
	}
	return true
}

func TestParityCreds(t *testing.T) {
	var cases []map[string]int
	var creds []Creds
	vals := []int{0, 1000, 1001}
	for _, u := range vals {
		for _, e := range vals {
			for _, g := range vals {
				for _, eg := range vals {
					cases = append(cases, map[string]int{"uid": u, "euid": e, "gid": g, "egid": eg})
					creds = append(creds, Creds{u, e, g, eg})
				}
			}
		}
	}
	rs := runPy(t, "creds", cases)
	for i, c := range creds {
		sameFailure(t, "creds"+jsonString(cases[i]), rs[i], RefusePrivilegedExecution(c))
	}
}

func jsonString(v any) string { b, _ := json.Marshal(v); return string(b) }

func TestParityCurrentCredsMatchTheProcess(t *testing.T) {
	c := CurrentCreds()
	rs := runPy(t, "creds", []map[string]int{{"uid": c.UID, "euid": c.EUID, "gid": c.GID, "egid": c.EGID}})
	sameFailure(t, "current", rs[0], RefusePrivilegedExecution(c))
	if c.UID != os.Getuid() || c.EUID != os.Geteuid() || c.GID != os.Getgid() || c.EGID != os.Getegid() {
		t.Fatalf("CurrentCreds = %+v, process has %d %d %d %d", c, os.Getuid(), os.Geteuid(), os.Getgid(), os.Getegid())
	}
}

var mountinfoCases = []struct{ name, path, mi string }{
	{"private-tmpfs", "/tmp/x", "1 0 8:1 / /tmp rw - tmpfs t rw\n"},
	{"every-private-fs", "/m/x", "1 0 8:1 / /m rw - ext4 t rw\n"},
	{"9p-rejected", "/m/x", "1 0 8:1 / /m rw - 9p p9 rw\n"},
	{"unknown-fs-rejected", "/m/x", "1 0 8:1 / /m rw - fuseblk f rw\n"},
	{"nfs-rejected", "/m/x", "1 0 8:1 / /m rw - nfs4 n rw\n"},
	{"most-specific-wins", "/a/b/c", "1 0 8:1 / / rw - ext4 r rw\n2 1 8:1 / /a rw - 9p p rw\n3 2 8:1 / /a/b rw - tmpfs t rw\n"},
	{"specific-rejected-over-private-root", "/a/b/c", "1 0 8:1 / / rw - ext4 r rw\n2 1 8:1 / /a/b rw - 9p p rw\n"},
	{"tie-first-wins", "/a/x", "1 0 8:1 / /a rw - 9p p rw\n2 1 8:1 / /a rw - tmpfs t rw\n"},
	{"tie-first-wins-private", "/a/x", "1 0 8:1 / /a rw - tmpfs t rw\n2 1 8:1 / /a rw - 9p p rw\n"},
	{"component-not-prefix", "/homeless/x", "1 0 8:1 / /home rw - 9p p rw\n"},
	{"mount-equals-path", "/m", "1 0 8:1 / /m rw - tmpfs t rw\n"},
	{"trailing-slash-path", "/m/x/", "1 0 8:1 / /m rw - tmpfs t rw\n"},
	{"dot-components-path", "/m/./x//y", "1 0 8:1 / /m rw - tmpfs t rw\n"},
	{"dotdot-is-lexical", "/m/../x", "1 0 8:1 / /m rw - 9p p rw\n2 1 8:1 / / rw - tmpfs t rw\n"},
	{"double-slash-root", "//m/x", "1 0 8:1 / //m rw - tmpfs t rw\n"},
	{"double-slash-vs-single", "//m/x", "1 0 8:1 / /m rw - tmpfs t rw\n"},
	{"triple-slash", "///m/x", "1 0 8:1 / /m rw - tmpfs t rw\n"},
	{"relative-path-no-mount", "m/x", "1 0 8:1 / /m rw - tmpfs t rw\n"},
	{"relative-path-empty-mount", "m/x", "1 0 8:1 / . rw - tmpfs t rw\n"},
	{"absolute-path-dot-mount", "/m/x", "1 0 8:1 / . rw - tmpfs t rw\n"},
	{"escaped-space", "/my dir/x", "1 0 8:1 / /my\\040dir rw - tmpfs t rw\n"},
	{"escaped-tab", "/a\tb/x", "1 0 8:1 / /a\\011b rw - tmpfs t rw\n"},
	{"escaped-backslash", "/a\\b/x", "1 0 8:1 / /a\\134b rw - tmpfs t rw\n"},
	{"escaped-backslash-then-digits", "/a\\040/x", "1 0 8:1 / /a\\134040 rw - tmpfs t rw\n"},
	{"unknown-escape-kept", "/a\\012/x", "1 0 8:1 / /a\\012 rw - tmpfs t rw\n"},
	{"optional-fields-and-separator", "/m/x", "36 35 98:0 /mnt1 /m rw,noatime master:1 - ext3 /dev/root rw,errors=continue\n"},
	{"dash-inside-mount-point", "/a - b/x", "1 0 8:1 / /a rw - tmpfs t rw\n"},
	{"second-separator-in-right", "/m/x", "1 0 8:1 / /m rw - tmpfs t - rw\n"},
	{"no-mounts-empty", "/m/x", ""},
	{"mount-deeper-than-path", "/m", "1 0 8:1 / /m/x/y rw - 9p p rw\n"},
	{"mount-deeper-than-path-private", "/m", "1 0 8:1 / /m/x rw - tmpfs p rw\n2 1 8:1 / / rw - 9p p rw\n"},
	{"no-mount-matches", "/m/x", "1 0 8:1 / /other rw - tmpfs t rw\n"},
	{"no-trailing-newline", "/m/x", "1 0 8:1 / /m rw - tmpfs t rw"},
	{"crlf-lines", "/m/x", "1 0 8:1 / / rw - 9p p rw\r\n2 1 8:1 / /m rw - tmpfs t rw\r\n"},
	{"bare-cr-lines", "/m/x", "1 0 8:1 / / rw - 9p p rw\r2 1 8:1 / /m rw - tmpfs t rw"},
	{"unicode-separators", "/m/x", "1 0 8:1 / / rw - 9p p rw 2 1 8:1 / /m rw - tmpfs t rw\u0085"},
	{"form-feed-separator", "/m/x", "1 0 8:1 / / rw - 9p p rw\f2 1 8:1 / /m rw - tmpfs t rw"},
	{"fs-separated-by-unicode-space", "/m/x", "1 0 8:1 / /m rw - tmpfs t rw"},
	{"blank-line-malformed", "/m/x", "1 0 8:1 / /m rw - tmpfs t rw\n\n"},
	{"missing-separator", "/m/x", "1 0 8:1 / /m rw tmpfs\n"},
	{"separator-without-spaces", "/m/x", "1 0 8:1 / /m rw -tmpfs t rw\n"},
	{"too-few-left-fields", "/m/x", "1 0 8:1 / - tmpfs t rw\n"},
	{"four-left-fields-quote", "/m/x", "it's - tmpfs\n"},
	{"empty-left", "/m/x", " - tmpfs t rw\n"},
	{"empty-right-fields", "/m/x", "1 0 8:1 / /m rw - \n"},
	{"left-checked-before-right", "/m/x", "1 0 - \n"},
	{"malformed-after-valid", "/m/x", "1 0 8:1 / /m rw - tmpfs t rw\ngarbage\n"},
	{"repr-double-quote", "/m/x", "say \"hi\" - \n"},
	{"repr-both-quotes", "/m/x", "it's \"x\" - \n"},
	{"repr-backslash-control", "/m/x", "a\\b\x01\x7f​ é\U0001F600 - \n"},
	{"repr-nul", "/m/x", "x\x00y - \n"},
}

func TestParityRequirePrivate(t *testing.T) {
	type in struct {
		Path      string `json:"path"`
		Mountinfo string `json:"mountinfo"`
	}
	var cases []in
	for _, c := range mountinfoCases {
		cases = append(cases, in{c.path, c.mi})
	}
	rs := runPy(t, "private", cases)
	for i, c := range mountinfoCases {
		sameFailure(t, c.name, rs[i], RequirePrivate(c.path, c.mi))
	}
}

func TestParityPrivateFSSet(t *testing.T) {
	// Every PRIVATE_FS member is accepted and a near-miss is rejected, in both.
	var names []string
	for fs := range PrivateFS {
		names = append(names, fs)
	}
	if len(names) != 14 {
		t.Fatalf("PrivateFS has %d entries, want 14", len(names))
	}
	probes := append(append([]string{}, names...), "ext", "ext5", "tmpfs2", "TMPFS", "overlayfs", "")
	type in struct {
		Path      string `json:"path"`
		Mountinfo string `json:"mountinfo"`
	}
	var cases []in
	for _, fs := range probes {
		cases = append(cases, in{"/m/x", "1 0 8:1 / /m rw - " + fs + " t rw\n"})
	}
	rs := runPy(t, "private", cases)
	for i, fs := range probes {
		sameFailure(t, "fs="+fs, rs[i], RequirePrivate("/m/x", cases[i].Mountinfo))
	}
}

func TestParityPathHelpers(t *testing.T) {
	strs := []string{"", ".", "/", "//", "///", "//a", "///a/b", "a", "a/", "a//b/./c", "/a/./b/", "/a/../b", "../a", "a/..",
		"it's", "say \"hi\"", "it's \"x\"", "tab\there", "nl\nx", "\\", "\x00", "\x7f", "é", "​", " ", "\U0001F600", " ", "\x1c\x1d\x1e\x1f",
		"a b\tc\x0bd\x0ce\rf\x85g h i j k l m n o　p\x1cq\x1fr", "  lead and trail  ", "​z"}
	type in struct {
		S string `json:"s"`
	}
	var cases []in
	for _, s := range strs {
		cases = append(cases, in{s})
	}
	eq := func(name string, rs []pyOut, got func(string) any) {
		for i, s := range strs {
			var want any
			if err := json.Unmarshal(rs[i].Value, &want); err != nil {
				t.Fatal(err)
			}
			g := got(s)
			gb, _ := json.Marshal(g)
			var gv any
			_ = json.Unmarshal(gb, &gv)
			if !reflect.DeepEqual(gv, want) {
				t.Errorf("%s(%q): python %v, go %v", name, s, want, gv)
			}
		}
	}
	eq("parts", runPy(t, "parts", cases), func(s string) any { return nz(pyParts(s)) })
	eq("repr", runPy(t, "repr", cases), func(s string) any { return pyRepr(s) })
	eq("splitlines", runPy(t, "splitlines", cases), func(s string) any { return nz(pySplitlines(s)) })
	eq("fields", runPy(t, "fields", cases), func(s string) any { return nz(pyFields(s)) })
}

// nz maps a nil slice to an empty one so JSON null does not differ from [].
func nz(s []string) []string {
	if s == nil {
		return []string{}
	}
	return s
}

// tree is the symlink fixture shared by the realpath, resolve, which and
// executable parity tests. It returns the (real) directory.
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
	must(os.MkdirAll(filepath.Join(dir, "bin"), 0o755))
	must(os.MkdirAll(filepath.Join(dir, "bin2"), 0o755))
	must(os.WriteFile(filepath.Join(dir, "real/file"), []byte("data"), 0o644))
	must(os.WriteFile(filepath.Join(dir, "bin/tool"), []byte("#!/bin/sh\n"), 0o755))
	must(os.WriteFile(filepath.Join(dir, "bin/plain"), []byte("x"), 0o644))
	must(os.WriteFile(filepath.Join(dir, "bin2/tool"), []byte("#!/bin/sh\n"), 0o755))
	must(os.Mkdir(filepath.Join(dir, "bin/adir"), 0o755))
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
	must(os.Symlink("bin/tool", filepath.Join(dir, "toolcopy")))
	must(os.Symlink(filepath.Join(dir, "bin/tool"), filepath.Join(dir, "bin2/toollink")))
	must(os.Symlink(filepath.Join(dir, "bin/tool"), filepath.Join(dir, "bin/toolalias")))
	return dir
}

var pathProbes = []string{
	"", ".", "/", "//", "real", "real/", "real/file", "real/file/", "real/file/x", "real/./sub/../file", "real/sub/..",
	"lnk", "lnk/file", "lnk/", "abs", "abs/file", "chain/file", "loop1", "loop1/x", "self", "self/x", "dangling", "dangling/x",
	"dangling/../real", "nope", "nope/x", "nope/../real", "real/nope/../file", "filelnk", "filelnk/x", "real/sub/up", "real/sub/up/file",
	"real/sub/up/../lnk", "toroot", "toroot/usr", "..", "../x", "lnk/..", "lnk/../real", "bin//tool", "./bin/tool", "toolcopy",
	"lnk/../lnk/file", "lnk/../lnk", "chain/../chain/file", "loop1/../loop1", "abs/../abs/file",
}

func TestParityRealpathAndResolve(t *testing.T) {
	dir := tree(t)
	type in struct {
		Path string `json:"path"`
		Cwd  string `json:"cwd"`
	}
	var cases []in
	for _, p := range pathProbes {
		cases = append(cases, in{p, dir})
		cases = append(cases, in{filepath.Join(dir, "x") + "/../" + p, dir}) // absolute spelling through a dotdot
		if p != "" && !strings.HasPrefix(p, "/") && !strings.HasPrefix(p, "..") {
			cases = append(cases, in{dir + "/" + p, "/"})
		}
	}
	cases = append(cases, in{"/usr/bin/../lib", "/"})
	rs := runPy(t, "realpath", cases)
	for i, c := range cases {
		got, err := realpath(c.Path, false, c.Cwd)
		if err != nil || !rs[i].OK {
			t.Errorf("realpath(%q, cwd %q): python ok=%v, go err=%v", c.Path, c.Cwd, rs[i].OK, err)
			continue
		}
		var want string
		_ = json.Unmarshal(rs[i].Value, &want)
		if got != want {
			t.Errorf("realpath(%q, cwd %q): python %q, go %q", c.Path, c.Cwd, want, got)
		}
	}
	rs = runPy(t, "resolve", cases)
	for i, c := range cases {
		got, err := resolveStrict(c.Path, c.Cwd)
		if !rs[i].OK {
			if err == nil {
				t.Errorf("resolve(%q, cwd %q): python %s, go %q", c.Path, c.Cwd, rs[i].Class, got)
			}
			continue
		}
		var want string
		_ = json.Unmarshal(rs[i].Value, &want)
		if err != nil || got != want {
			t.Errorf("resolve(%q, cwd %q): python %q, go %q (%v)", c.Path, c.Cwd, want, got, err)
		}
	}
}

func TestParityWhich(t *testing.T) {
	dir := tree(t)
	b, b2 := filepath.Join(dir, "bin"), filepath.Join(dir, "bin2")
	type in struct {
		Cmd    string `json:"cmd"`
		Search string `json:"search"`
		Cwd    string `json:"cwd"`
	}
	cases := []in{
		{"tool", b, dir}, {"tool", b2 + ":" + b, dir}, {"tool", b + ":" + b2, dir}, {"plain", b, dir}, {"adir", b, dir},
		{"nope", b, dir}, {"tool", "", dir}, {"tool", ":", dir}, {"tool", "bin", dir}, {"tool", ":bin", dir},
		{"tool", b + "::" + b2, dir}, {"tool", b + ":" + b, dir}, {"bin/tool", "", dir}, {"bin/tool", b2, dir},
		{"./bin/tool", "", dir}, {filepath.Join(b, "tool"), "", dir}, {filepath.Join(b, "plain"), "", dir},
		{filepath.Join(b, "adir"), "", dir}, {filepath.Join(b, "adir") + "/", "", dir}, {"bin/", "", dir},
		{"toolcopy", dir, dir}, {"toolalias", b, dir}, {"", b, dir}, {"/", "", dir}, {"tool", "/nonexistent", dir},
		{"sh", "/usr/bin:/bin", dir},
	}
	rs := runPy(t, "which", cases)
	for i, c := range cases {
		got, ok := which(c.Cmd, c.Search, c.Cwd)
		var want *string
		_ = json.Unmarshal(rs[i].Value, &want)
		if (want != nil) != ok || (ok && got != *want) {
			t.Errorf("which(%q, %q): python %v, go %q ok=%v", c.Cmd, c.Search, want, got, ok)
		}
	}
}

func TestParityExecutable(t *testing.T) {
	dir := tree(t)
	b, b2 := filepath.Join(dir, "bin"), filepath.Join(dir, "bin2")
	str := func(s string) *string { return &s }
	type in struct {
		Name       string  `json:"name"`
		Configured *string `json:"configured"`
		Search     string  `json:"search"`
		Cwd        string  `json:"cwd"`
	}
	cases := []in{
		{"tool", nil, b, dir},
		{"tool", str(""), b, dir},
		{"tool", str(filepath.Join(b, "tool")), b, dir},
		{"tool", str(filepath.Join(b, "toolalias")), b, dir},
		{"tool", str("bin/tool"), b, dir},
		{"tool", str("bin//tool/"), b, dir},
		{"tool", str(filepath.Join(b2, "tool")), b, dir},
		{"tool", str(filepath.Join(b2, "toollink")), b, dir},
		{"tool", str(filepath.Join(dir, "nope")), b, dir},
		{"tool", str(filepath.Join(b, "plain")), b, dir},
		{"tool", str(filepath.Join(b, "adir")), b, dir},
		{"tool", str(filepath.Join(dir, "loop1")), b, dir},
		{"tool", str(filepath.Join(b, "tool") + "/"), b, dir},
		{"tool", str(filepath.Join(b, "tool", "x")), b, dir},
		{"missing", nil, b, dir},
		{"missing", str(filepath.Join(b, "tool")), b, dir},
		{"tool", nil, "", dir},
		{"plain", nil, b, dir},
		{"tool", nil, "bin", dir},
		{"toolcopy", nil, dir, dir},
	}
	rs := runPy(t, "executable", cases)
	for i, c := range cases {
		conf := c.Configured
		path, rec, err := Executable(Host{Cwd: c.Cwd}, c.Name, conf, c.Search)
		label := c.Name
		if conf != nil {
			label += " configured=" + *conf
		}
		label += " search=" + c.Search
		if !sameFailure(t, label, rs[i], err) || !rs[i].OK {
			continue
		}
		var want struct {
			Path   string
			Record map[string]any
		}
		_ = json.Unmarshal(rs[i].Value, &want)
		if path != want.Path || rec.Path != want.Record["path"] || float64(rec.Size) != want.Record["size"] || rec.SHA256 != want.Record["sha256"] {
			t.Errorf("%s: python %+v, go %q %+v", label, want, path, rec)
		}
	}
}

// ---- sandbox parity ----

type sbCase struct {
	Name  string     `json:"-"`
	Root  string     `json:"root"`
	UID   int        `json:"uid"`
	Cwd   string     `json:"cwd"`
	Bwrap string     `json:"bwrap"`
	Env   [][]string `json:"env"`
	Ro    []string   `json:"ro"`
	Hide  []string   `json:"hide"`
	setup func(t *testing.T, root string)
}

func TestParitySandbox(t *testing.T) {
	dir := tree(t)
	uid := os.Getuid()
	cases := []sbCase{
		{Name: "no-env-no-inputs"},
		{Name: "env-order-kept", Env: [][]string{{"Z", "1"}, {"A", "2"}, {"HOME", "/tmp/rsdd/home"}, {"E", ""}}},
		{Name: "env-odd-values", Env: [][]string{{"K", "a b=c\n"}, {"é", "ü"}}},
		{Name: "ro-usr-share", Ro: []string{"/usr/share"}},
		{Name: "ro-two-in-order", Ro: []string{"/usr/lib", "/usr/bin"}},
		{Name: "ro-duplicate", Ro: []string{"/usr/bin", "/usr/bin"}},
		{Name: "ro-trailing-slash", Ro: []string{"/usr/bin/"}},
		{Name: "ro-dotdot-resolves-out", Ro: []string{"/usr/bin/../lib"}},
		{Name: "ro-symlink-bound-by-real-path", Ro: []string{filepath.Join(dir, "toroot") + "/usr/bin"}},
		{Name: "ro-empty-list", Ro: []string{}},
		{Name: "ro-root", Ro: []string{"/"}},
		{Name: "ro-double-slash-root", Ro: []string{"//"}},
		{Name: "ro-symlink-to-root", Ro: []string{filepath.Join(dir, "toroot")}},
		{Name: "ro-symlink-to-etc", Ro: []string{"/etc/ssl/../../etc"}},
		{Name: "ro-dotdot-to-root", Ro: []string{"/usr/.."}},
		{Name: "ro-home", Ro: []string{"/home"}},
		{Name: "ro-under-home", Ro: []string{"/home/x/y"}},
		{Name: "ro-tmpdir-under-home", Ro: []string{dir}},
		{Name: "ro-root-dir", Ro: []string{"/root"}},
		{Name: "ro-etc", Ro: []string{"/etc"}},
		{Name: "ro-etc-file", Ro: []string{"/etc/passwd"}},
		{Name: "ro-proc", Ro: []string{"/proc/self"}},
		{Name: "ro-sys", Ro: []string{"/sys/kernel"}},
		{Name: "ro-dev", Ro: []string{"/dev/null"}},
		{Name: "ro-run", Ro: []string{"/run/user"}},
		{Name: "ro-homeless-not-blocked-but-missing", Ro: []string{"/homeless"}},
		{Name: "ro-etcetera-missing", Ro: []string{"/etcetera/x"}},
		{Name: "ro-missing", Ro: []string{"/usr/__no_such_dir_xyz__"}},
		{Name: "ro-missing-after-good", Ro: []string{"/usr/bin", "/usr/__no_such__"}},
		{Name: "ro-blocked-before-missing", Ro: []string{"/usr/__no_such__", "/etc"}},
		{Name: "ro-relative", Ro: []string{"."}, Cwd: "/usr"},
		{Name: "ro-relative-child", Ro: []string{"bin"}, Cwd: "/usr"},
		{Name: "ro-relative-into-home", Ro: []string{"x"}, Cwd: dir},
		{Name: "ro-empty-string", Ro: []string{""}, Cwd: "/usr"},
		{Name: "hide-lib64", Hide: []string{"/lib64"}},
		{Name: "hide-all-runtime-dirs", Hide: []string{"/usr", "/bin", "/sbin", "/lib", "/lib64"}},
		{Name: "hide-usr-only", Hide: []string{"/usr"}},
		{Name: "hide-input-as-missing", Hide: []string{"/usr/share"}, Ro: []string{"/usr/share"}},
		{Name: "bwrap-path", Bwrap: "/opt/x/bwrap"},
		{Name: "root-created-0700"},
		{Name: "root-existing-0700", setup: func(t *testing.T, r string) { mk(t, r, 0o700) }},
		{Name: "root-0755", setup: func(t *testing.T, r string) { mk(t, r, 0o755) }},
		{Name: "root-0750", setup: func(t *testing.T, r string) { mk(t, r, 0o750) }},
		{Name: "root-0705", setup: func(t *testing.T, r string) { mk(t, r, 0o705) }},
		{Name: "root-0770", setup: func(t *testing.T, r string) { mk(t, r, 0o770) }},
		{Name: "root-0701", setup: func(t *testing.T, r string) { mk(t, r, 0o701) }},
		{Name: "root-0710", setup: func(t *testing.T, r string) { mk(t, r, 0o710) }},
		{Name: "root-0500", setup: func(t *testing.T, r string) { mk(t, r, 0o500) }},
		{Name: "root-wrong-owner", UID: uid + 1},
		{Name: "root-symlink-to-private-dir", setup: func(t *testing.T, r string) {
			mk(t, r+".real", 0o700)
			if err := os.Symlink(r+".real", r); err != nil {
				t.Fatal(err)
			}
		}},
		{Name: "root-is-a-file", setup: func(t *testing.T, r string) {
			if err := os.WriteFile(r, nil, 0o600); err != nil {
				t.Fatal(err)
			}
		}},
		{Name: "root-dangling-symlink", setup: func(t *testing.T, r string) {
			if err := os.Symlink("nowhere", r); err != nil {
				t.Fatal(err)
			}
		}},
		{Name: "root-parent-missing", setup: func(t *testing.T, r string) {}, Root: "missing-parent/rsdd"},
	}
	for i := range cases {
		c := &cases[i]
		if c.Bwrap == "" {
			c.Bwrap = "/usr/bin/bwrap"
		}
		if c.Cwd == "" {
			c.Cwd = "/"
		}
		if c.UID == 0 {
			c.UID = uid
		}
		if c.Env == nil {
			c.Env = [][]string{}
		}
	}
	// Python and Go each get their own root under a fresh directory, set up identically.
	base := t.TempDir()
	rootFor := func(who string, i int) string {
		c := cases[i]
		rel := c.Root
		if rel == "" {
			rel = "rsdd"
		}
		r := filepath.Join(base, who, c.Name, rel)
		if err := os.MkdirAll(filepath.Dir(filepath.Join(base, who, c.Name, "x")), 0o700); err != nil {
			t.Fatal(err)
		}
		if c.setup != nil && c.Root == "" {
			c.setup(t, r)
		}
		return r
	}
	pyIn := make([]sbCase, len(cases))
	for i := range cases {
		pyIn[i] = cases[i]
		pyIn[i].Root = rootFor("py", i)
	}
	rs := runPy(t, "sandbox", pyIn)
	for i, c := range cases {
		root := rootFor("go", i)
		var env []EnvVar
		for _, kv := range c.Env {
			env = append(env, EnvVar{kv[0], kv[1]})
		}
		hide := map[string]bool{}
		for _, h := range c.Hide {
			hide[h] = true
		}
		h := Host{Root: root, UID: c.UID, Cwd: c.Cwd, Exists: func(p string) bool {
			if hide[p] {
				return false
			}
			_, err := os.Stat(p)
			return err == nil
		}}
		argv, err := Sandbox(h, c.Bwrap, env, c.Ro)
		if !sameFailure(t, c.Name, rs[i], err) || !rs[i].OK {
			continue
		}
		var want []string
		_ = json.Unmarshal(rs[i].Value, &want)
		if !reflect.DeepEqual(argv, want) {
			t.Errorf("%s: argv\n python %q\n go     %q", c.Name, want, argv)
		}
	}
}

func mk(t *testing.T, path string, mode os.FileMode) {
	t.Helper()
	if err := os.MkdirAll(path, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(path, mode); err != nil {
		t.Fatal(err)
	}
}
