//go:build !nodiff && unix

package java

import (
	"bytes"
	"encoding/json"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"testing"
)

// Differential tests against the frozen legacy script (testdata/legacy/corroborate_java.py, with the manifest
// module and the lib it imports): the same inputs go through the Python script and through Run, with a real
// Bubblewrap and a fake JDK, and the exit code, the stderr line and every published file must agree. Logic that
// only this oracle checks also has golden tests in the untagged files, because the mutation runs have neither
// python3 nor Bubblewrap.

const legacyDir = "testdata/legacy"

func needPython(t *testing.T) string {
	t.Helper()
	py, err := exec.LookPath("python3")
	if err != nil {
		if os.Getenv("RSDD_PARITY_REQUIRE") == "1" {
			t.Fatal("no python3 on PATH and RSDD_PARITY_REQUIRE=1")
		}
		t.Skip("no python3 on PATH: the differential tests need the legacy script's interpreter")
	}
	return py
}

// realBwrap reports whether /usr/bin/bwrap can start a network-denied sandbox here.
func realBwrap(t *testing.T) bool {
	t.Helper()
	if fi, err := os.Stat("/usr/bin/bwrap"); err != nil || !fi.Mode().IsRegular() {
		return false
	}
	return exec.Command("/usr/bin/bwrap", "--unshare-net", "--ro-bind", "/", "/", "/bin/true").Run() == nil
}

var timestamps = regexp.MustCompile(`"(started_at|ended_at)":"[^"]*"|"duration_ms":[0-9]+`)

func maskTimes(b []byte) []byte {
	return timestamps.ReplaceAllFunc(b, func(m []byte) []byte {
		if bytes.HasPrefix(m, []byte(`"duration_ms"`)) {
			return []byte(`"duration_ms":0`)
		}
		return append(append([]byte{}, m[:bytes.IndexByte(m, ':')+1]...), `"T"`...)
	})
}

// legacyScript puts the frozen script in a fresh directory next to a `lib` link to the frozen core/adapter copy, so it
// imports the helpers (adapter_helpers, isolation_profile) the toolbelt still ships; it returns the script and
// the toolbelt directory, whose analysis_manifest.py the script is handed. Only corroborate_java.py is frozen:
// the adapter modules are frozen copies under core/adapter/testdata/frozen.
func legacyScript(t *testing.T) (script, toolbelt string) {
	t.Helper()
	toolbelt, err := filepath.Abs("../../core/adapter/testdata/frozen")
	if err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(filepath.Join(legacyDir, "corroborate_java.py"))
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	script = filepath.Join(dir, "corroborate_java.py")
	if err := os.WriteFile(script, data, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(toolbelt, "lib"), filepath.Join(dir, "lib")); err != nil {
		t.Fatal(err)
	}
	return script, toolbelt
}

// legacyRun is the frozen script run the way the shim ran it.
func legacyRun(t *testing.T, h *harness, py string, args []string) result {
	t.Helper()
	script, toolbelt := legacyScript(t)
	// The script loads the manifest module it is handed: give it the real one, not the harness stub.
	// The port accepts --manifest-module and ignores it, so the script always runs with the real module, whatever
	// the arguments carried (including no flag at all).
	real := filepath.Join(toolbelt, "analysis_manifest.py")
	var rewritten []string
	for i := 0; i < len(args); i++ {
		if args[i] == "--manifest-module" && i+1 < len(args) {
			i++
			continue
		}
		rewritten = append(rewritten, args[i])
	}
	args = append([]string{"--manifest-module", real}, rewritten...)
	argv := append([]string{"-I", "-B", script}, args...)
	cmd := exec.Command(py, argv...)
	cmd.Dir = h.root
	cmd.Env = []string{"PATH=" + filepath.Dir(py) + ":/usr/bin:/bin"}
	for k, v := range h.env {
		cmd.Env = append(cmd.Env, k+"="+v)
	}
	var out, errb bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errb
	rc := 0
	if err := cmd.Run(); err != nil {
		ee, ok := err.(*exec.ExitError)
		if !ok {
			t.Fatal(err)
		}
		rc = ee.ExitCode()
	}
	return result{rc: rc, stdout: out.String(), err: errb.String()}
}

// goRun is Run with the production wiring (real owner check, /tmp/rsdd, the test binary as the rlimit helper).
func goRun(t *testing.T, h *harness, args []string) result {
	t.Helper()
	var out, errb bytes.Buffer
	s := h.stdio(&out, &errb)
	e := newEnv(s)
	e.helper = os.Executable
	rc := e.main(args)
	return result{rc: rc, stdout: out.String(), err: errb.String()}
}

// tree is every path below root with its mode and (time-masked) content.
func tree(t *testing.T, root string) map[string]string {
	t.Helper()
	out := map[string]string{}
	err := filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(root, p)
		fi, err := d.Info()
		if err != nil {
			return err
		}
		desc := fi.Mode().String()
		if d.Type().IsRegular() {
			b, rerr := os.ReadFile(p)
			if rerr != nil {
				return rerr
			}
			desc += " " + string(maskTimes(b))
		}
		out[rel] = desc
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	return out
}

// sides renames the output parents so the two runs publish to equally named roots in different directories.
type scenario struct {
	name       string
	needBwrap  bool
	setup      func(h *harness)
	extra      []string
	wantRC     int
	sameStderr bool // the message is the same text in both implementations
	// racy: how much a capped engine wrote before the cap was seen depends on timing in both implementations
	// (the frozen script polls every 50 ms), so only the report's verdict fields are compared, not the trees.
	racy bool
}

func TestDifferentialAgainstTheFrozenScript(t *testing.T) {
	py := needPython(t)
	haveBwrap := realBwrap(t)
	scenarios := []scenario{
		{name: "five adapters succeed", needBwrap: true, wantRC: 0, sameStderr: true},
		{name: "one adapter fails", needBwrap: true, setup: func(h *harness) { h.mode("cfr", "fail") }, wantRC: 1, sameStderr: true},
		{name: "an adapter times out", needBwrap: true, setup: func(h *harness) { h.mode("vineflower", "slow") }, extra: []string{"--timeout-seconds", "1"}, wantRC: 1, sameStderr: true},
		{name: "caps are hit", needBwrap: true, setup: func(h *harness) { h.mode("cfr", "spam") }, extra: []string{"--max-bytes", "4096"}, wantRC: 1, sameStderr: true, racy: true},
		{name: "a decompiler is unavailable", needBwrap: true, setup: func(h *harness) { delete(h.env, "RSDD_CORROBORATE_PROCYON") }, wantRC: 1, sameStderr: true},
		{name: "multi-release jar with broken classes", needBwrap: true, setup: func(h *harness) {
			c := classBytes(52, true)
			writeJar(t, h.input, entry{name: "p/A.class", data: c}, entry{name: "p/A$B.class", data: classBytes(65, false)},
				entry{name: "META-INF/versions/11/p/A.class", data: c}, entry{name: "p/Bad.class", data: []byte{1, 2, 3}},
				entry{name: "module-info.class", data: c}, entry{name: "r.txt", data: []byte("x")})
		}, wantRC: 0, sameStderr: true},
		{name: "class limit truncates the expected set", needBwrap: true, setup: func(h *harness) {
			writeJar(t, h.input, entry{name: "a/A.class", data: classBytes(61, false)}, entry{name: "a/B.class", data: classBytes(61, false)}, entry{name: "a/C.class", data: classBytes(61, false)})
		}, extra: []string{"--max-classes", "2"}, wantRC: 0, sameStderr: true},
		{name: "malformed class facts limit", needBwrap: true, setup: func(h *harness) { h.env["RSDD_CLASSFACTS_MAX_CLASS_BYTES"] = "abc" }, wantRC: 0, sameStderr: true},
		{name: "unsafe entry", setup: func(h *harness) { writeJar(t, h.input, entry{name: "../escape.class", data: []byte("c")}) }, wantRC: 2, sameStderr: true},
		{name: "duplicate entry", setup: func(h *harness) {
			writeJar(t, h.input, entry{name: "a.class", data: []byte("c")}, entry{name: "a.class", data: []byte("d")})
		}, wantRC: 2, sameStderr: true},
		{name: "symlink entry", setup: func(h *harness) {
			writeJar(t, h.input, entry{name: "l.class", data: []byte("/etc/passwd"), mode: os.ModeSymlink | 0o777})
		}, wantRC: 2, sameStderr: true},
		{name: "not an archive", setup: func(h *harness) { _ = os.WriteFile(h.input, []byte("plain"), 0o644) }, wantRC: 2, sameStderr: true},
		{name: "corrupt deflate entry", setup: func(h *harness) { corruptDeflate(t, h.input) }, wantRC: 2, sameStderr: true},
		{name: "too many entries", setup: func(h *harness) {}, extra: []string{"--max-files", "1"}, wantRC: 2, sameStderr: true},
		{name: "expanded bytes cap", setup: func(h *harness) {}, extra: []string{"--max-bytes", "30"}, wantRC: 2, sameStderr: true},
		{name: "missing input", setup: func(h *harness) { h.input = filepath.Join(h.root, "nope.jar") }, wantRC: 2, sameStderr: true},
		{name: "input is a directory", setup: func(h *harness) { h.input = h.root }, wantRC: 2, sameStderr: true},
		{name: "empty pin", setup: func(h *harness) { h.env["VINEFLOWER_SHA256"] = "" }, wantRC: 2, sameStderr: true},
		{name: "wrong pin", setup: func(h *harness) { h.env["CFR_SHA256"] = strings.Repeat("0", 64) }, wantRC: 2, sameStderr: true},
		{name: "sha256: prefixed pin", needBwrap: true, setup: func(h *harness) { h.env["CFR_SHA256"] = "sha256:" + h.env["CFR_SHA256"] }, wantRC: 0, sameStderr: true},
		{name: "launcher is not bubblewrap", setup: func(h *harness) { h.env["RSDD_BWRAP"] = "/bin/true" }, wantRC: 2, sameStderr: true},
		{name: "launcher missing", setup: func(h *harness) { h.env["RSDD_BWRAP"] = filepath.Join(h.root, "absent") }, wantRC: 2, sameStderr: true},
		{name: "launcher empty", setup: func(h *harness) { h.env["RSDD_BWRAP"] = "" }, wantRC: 2, sameStderr: true},
		{name: "java missing", setup: func(h *harness) { _ = os.Remove(filepath.Join(h.javaHome, "bin", "java")) }, wantRC: 2, sameStderr: true},
		{name: "jdeps not executable", setup: func(h *harness) { _ = os.Chmod(filepath.Join(h.javaHome, "bin", "jdeps"), 0o644) }, wantRC: 2, sameStderr: true},
		{name: "wrapper missing", setup: func(h *harness) { _ = os.Remove(filepath.Join(h.root, "wrapper-trap")) }, wantRC: 2, sameStderr: false},
	}
	for _, sc := range scenarios {
		t.Run(sc.name, func(t *testing.T) {
			if sc.needBwrap && !haveBwrap {
				t.Skip("no working /usr/bin/bwrap")
			}
			h := newHarness(t)
			_ = os.Remove(filepath.Join(h.javaHome, "bin", "bwrap")) // the sandbox PATH must find the system one
			h.env["RSDD_BWRAP"] = "/usr/bin/bwrap"
			if sc.setup != nil {
				sc.setup(h)
			}
			legacyOut, goOut := filepath.Join(h.root, "py", "out"), filepath.Join(h.root, "go", "out")
			for _, d := range []string{filepath.Dir(legacyOut), filepath.Dir(goOut)} {
				if err := os.MkdirAll(d, 0o755); err != nil {
					t.Fatal(err)
				}
			}
			args := func(out string) []string { return h.args(append([]string{"--output", out}, sc.extra...)...) }
			want := legacyRun(t, h, py, args(legacyOut))
			got := goRun(t, h, args(goOut))
			if want.rc != sc.wantRC {
				t.Fatalf("legacy rc = %d, the scenario expects %d; stderr %q", want.rc, sc.wantRC, want.err)
			}
			if got.rc != want.rc {
				t.Fatalf("rc: go %d, legacy %d\n go:     %q\n legacy: %q", got.rc, want.rc, got.err, want.err)
			}
			norm := func(s, out string) string {
				return strings.ReplaceAll(strings.ReplaceAll(s, out, "OUT"), h.root, "ROOT")
			}
			if sc.sameStderr && norm(got.err, goOut) != norm(want.err, legacyOut) {
				t.Errorf("stderr:\n go:     %q\n legacy: %q", norm(got.err, goOut), norm(want.err, legacyOut))
			}
			if got.stdout != want.stdout {
				t.Errorf("stdout: go %q, legacy %q", got.stdout, want.stdout)
			}
			if want.rc == 2 {
				for _, o := range []string{legacyOut, goOut} {
					if pathExists(o) || pathExists(filepath.Join(filepath.Dir(o), ".out.stage")) {
						t.Errorf("a refused run left %s or its stage behind", o)
					}
				}
				return
			}
			if sc.racy {
				if pa, pb := verdict(t, legacyOut), verdict(t, goOut); pa != pb {
					t.Errorf("report verdict:\n legacy: %s\n go:     %s", pa, pb)
				}
				return
			}
			a, b := tree(t, legacyOut), tree(t, goOut)
			var keys []string
			for k := range a {
				keys = append(keys, k)
			}
			for k := range b {
				if _, ok := a[k]; !ok {
					keys = append(keys, k)
				}
			}
			sort.Strings(keys)
			for _, k := range keys {
				if a[k] != b[k] {
					at := firstDiff(a[k], b[k])
					t.Errorf("%s differs at byte %d:\n legacy: …%.300s\n go:     …%.300s", k, at, a[k][max(at-120, 0):], b[k][max(at-120, 0):])
				}
			}
		})
	}
}

// TestDifferentialOverwriteAndExistingRoot pins the publication contract on both sides.
func TestDifferentialOverwriteAndExistingRoot(t *testing.T) {
	py := needPython(t)
	if !realBwrap(t) {
		t.Skip("no working /usr/bin/bwrap")
	}
	h := newHarness(t)
	_ = os.Remove(filepath.Join(h.javaHome, "bin", "bwrap"))
	h.env["RSDD_BWRAP"] = "/usr/bin/bwrap"
	for side, run := range map[string]func(args []string) result{
		"legacy": func(a []string) result { return legacyRun(t, h, py, a) },
		"go":     func(a []string) result { return goRun(t, h, a) },
	} {
		out := filepath.Join(h.root, side+"-out")
		if r := run(h.args("--output", out)); r.rc != 0 {
			t.Fatalf("%s first run rc=%d %s", side, r.rc, r.err)
		}
		r := run(h.args("--output", out))
		if r.rc != 2 || r.err != "corroborate-java: output root exists; pass --overwrite\n" {
			t.Errorf("%s without --overwrite: rc=%d stderr=%q", side, r.rc, r.err)
		}
		if r := run(h.args("--output", out, "--overwrite")); r.rc != 0 {
			t.Errorf("%s with --overwrite: rc=%d %s", side, r.rc, r.err)
		}
		if pathExists(filepath.Join(h.root, "."+side+"-out.stage")) {
			t.Errorf("%s left a stage behind", side)
		}
	}
}

// firstDiff is the offset of the first byte where a and b differ (the shorter length when one is a prefix).
func firstDiff(a, b string) int {
	n := min(len(a), len(b))
	for i := 0; i < n; i++ {
		if a[i] != b[i] {
			return i
		}
	}
	return n
}

// verdict projects a published report onto the fields that do not depend on timing: the run status, the
// truncation flags and each engine's status, exit code and signal.
func verdict(t *testing.T, root string) string {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(root, "java-corroboration.v1.json"))
	if err != nil {
		t.Fatal(err)
	}
	var rep struct {
		Status    any `json:"status"`
		Truncated any `json:"truncated"`
		Engines   map[string]struct {
			Status   any `json:"status"`
			ExitCode any `json:"exit_code"`
			Signal   any `json:"signal"`
		} `json:"engines"`
	}
	if err := json.Unmarshal(data, &rep); err != nil {
		t.Fatal(err)
	}
	out, err := json.Marshal(rep)
	if err != nil {
		t.Fatal(err)
	}
	return string(out)
}
