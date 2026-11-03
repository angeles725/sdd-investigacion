//go:build linux && !nodiff

package capa

// The differential half of the capa tests. The frozen legacy tool (testdata/legacy/corroborate_capa.py,
// byte-for-byte the retired toolbelt/corroborate_capa.py) is the oracle, run under Python 3.12 against the
// same fake sandbox as the Go command: exit code, stdout, stderr, the published evidence and the analysis
// manifest must agree. The legacy script imports toolbelt/lib, which stays in the kit, via PYTHONPATH.

import (
	"bytes"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"math/big"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/jsonout"
)

const (
	legacyScript = "testdata/legacy/corroborate_capa.py"
	toolbeltDir  = "../../core/adapter/testdata/frozen" // frozen oracle copies of the toolbelt adapter modules
)

// python312 is the interpreter the oracle must run under; a missing one FAILS (a skipped parity test proves nothing).
func python312(t testing.TB) string {
	t.Helper()
	py, err := exec.LookPath("python3.12")
	if err != nil {
		t.Fatalf("python3.12 is required for the parity tests and was not found: %v", err)
	}
	return py
}

// pyOutcome is what one process produced.
type pyOutcome struct {
	code           int
	stdout, stderr string
}

// legacyBootstrap runs the frozen legacy tool with --manifest-cli made optional and always pointing at the real
// analysis_manifest.py: the port accepts the flag and ignores it, so the oracle must not depend on what the caller
// passed for it. Everything else is the legacy tool, unmodified.
const legacyBootstrap = `
import sys, importlib.util
from pathlib import Path
legacy, manifest, argv = sys.argv[1], sys.argv[2], sys.argv[3:]
spec = importlib.util.spec_from_file_location("legacy_capa", legacy)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
orig = m._parser
def patched():
    p = orig()
    for a in p._actions:
        if a.dest == "manifest_cli": a.required = False
    parse = p.parse_args
    def parse_args(av=None, *x, **k):
        ns = parse(av, *x, **k)
        ns.manifest_cli = Path(manifest)
        return ns
    p.parse_args = parse_args
    return p
m._parser = patched
sys.exit(m.main(argv))
`

// runLegacy runs the legacy CLI inside rig r with its environment.
func runLegacy(t *testing.T, r *rig, extraEnv []string, args ...string) pyOutcome {
	t.Helper()
	tb, err := filepath.Abs(toolbeltDir)
	if err != nil {
		t.Fatal(err)
	}
	script, _ := filepath.Abs(legacyScript)
	cmd := exec.Command(python312(t), append([]string{"-c", legacyBootstrap, script, filepath.Join(tb, "analysis_manifest.py")}, args...)...)
	cmd.Dir = r.root
	cmd.Env = append(append(r.environ(), "PYTHONPATH="+tb, "PYTHONDONTWRITEBYTECODE=1", "RSDD_BIN="+rsddBinary(t)), extraEnv...)
	var out, errb bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errb
	code := 0
	if err := cmd.Run(); err != nil {
		ee, ok := err.(*exec.ExitError)
		if !ok {
			t.Fatalf("legacy tool did not run: %v", err)
		}
		code = ee.ExitCode()
	}
	return pyOutcome{code, out.String(), errb.String()}
}

// runTimes are the wall-clock fields of the run record and the manifest identity, a hash over them.
var runTimes = regexp.MustCompile(`"(duration_ms)":\d+|"(started_at|ended_at|identity)":"[^"]*"`)

// norm blanks the wall-clock fields of the run record and the manifest identity.
func norm(s string) string { return runTimes.ReplaceAllString(s, `"$1$2":"<t>"`) }

// snapshot is every path under dir with its content (empty for directories), keyed by the relative path.
func snapshot(t *testing.T, dir string) map[string]string {
	t.Helper()
	out := map[string]string{}
	_ = filepath.WalkDir(dir, func(p string, d os.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		rel, _ := filepath.Rel(dir, p)
		if d.IsDir() {
			out[rel+"/"] = ""
			return nil
		}
		b, _ := os.ReadFile(p)
		out[rel] = norm(string(b))
		return nil
	})
	return out
}

// parityCase is one scenario: a setup applied before each run and the arguments (a function of the rig).
type parityCase struct {
	name  string
	setup func(r *rig)
	args  func(r *rig) []string
	env   []string
	crash bool // the legacy tool dies with a traceback: only the exit code and the published tree are compared
}

func plain(extra ...string) func(r *rig) []string {
	return func(r *rig) []string { return r.args("ev", extra...) }
}

// run executes the scenario with the legacy tool and then with the port in the SAME rig (so every path in the
// evidence, and therefore every hash in the manifest, is identical), clearing the output directory between them.
func (c parityCase) run(t *testing.T) {
	t.Helper()
	r := newRig(t)
	manifest, err := filepath.Abs(toolbeltDir + "/analysis_manifest.py")
	if err != nil {
		t.Fatal(err)
	}
	r.manifestCLI = manifest
	prepare := func() {
		if err := os.RemoveAll(r.outDir); err != nil {
			t.Fatal(err)
		}
		if err := os.Mkdir(r.outDir, 0o755); err != nil {
			t.Fatal(err)
		}
		if c.setup != nil {
			c.setup(r)
		}
		r.extraEv = nil
	}
	prepare()
	want := runLegacy(t, r, c.env, c.args(r)...)
	wantTree := snapshot(t, r.outDir)
	prepare()
	r.extraEv = c.env
	code, stdout, stderr := r.run(c.args(r)...)
	got := pyOutcome{code, stdout, stderr}
	gotTree := snapshot(t, r.outDir)
	if got.code != want.code {
		t.Errorf("exit code: legacy %d, port %d\nlegacy stderr: %s\nport stderr: %s", want.code, got.code, want.stderr, got.stderr)
	}
	if n1, n2 := norm(want.stdout), norm(got.stdout); n1 != n2 {
		t.Errorf("stdout differs:\nlegacy %q\nport   %q", n1, n2)
	}
	if n1, n2 := norm(want.stderr), norm(got.stderr); n1 != n2 && !c.crash {
		t.Errorf("stderr differs:\nlegacy %q\nport   %q", n1, n2)
	}
	for rel, w := range wantTree {
		g, ok := gotTree[rel]
		switch {
		case !ok:
			t.Errorf("published tree: %s only in the legacy output", rel)
		case g != w:
			t.Errorf("%s differs at %s", rel, firstDiff(w, g))
		}
	}
	for rel := range gotTree {
		if _, ok := wantTree[rel]; !ok {
			t.Errorf("published tree: %s only in the port output", rel)
		}
	}
}

// firstDiff shows a window around the first byte where a and b differ.
func firstDiff(a, b string) string {
	i := 0
	for i < len(a) && i < len(b) && a[i] == b[i] {
		i++
	}
	w := func(s string) string { return s[max(0, i-60):min(len(s), i+120)] }
	return fmt.Sprintf("offset %d:\nlegacy ...%s\nport   ...%s", i, w(a), w(b))
}

func TestParityRuns(t *testing.T) {
	big := func(r *rig) {
		var b strings.Builder
		b.WriteString(`{"rules": {`)
		for i := 0; i < 40; i++ {
			if i > 0 {
				b.WriteString(",")
			}
			fmt.Fprintf(&b, `"rule %02d": {"meta": {"namespace": "ns/%d", "attack": [{"id": "T%d"}], "mbc": [{"id": "B%d"}, {"x": 1}]}, "matches": [[1, {}]]}`, i, i%7, 1000+i, i)
		}
		b.WriteString(`}}`)
		r.capaOutput(b.String())
	}
	unicode := func(r *rig) {
		r.capaOutput(`{"rules": {"régle ü": {"meta": {"namespace": "ünï/cödé", "attack": [{"id": "T€"}]}, "matches": []}, "plain": {"meta": {}, "matches": {"a": 1}}}}`)
	}
	cases := []parityCase{
		{name: "happy", args: plain()},
		{name: "cap one", args: plain("--max-capabilities", "1")},
		{name: "cap exact", args: plain("--max-capabilities", "3")},
		{name: "cap huge", args: plain("--max-capabilities", "99999999999999999999999")},
		{name: "timeout value huge", args: plain("--timeout", "99999999999999999999999")},
		{name: "forty rules cap 25", setup: big, args: plain("--max-capabilities", "25")},
		{name: "unicode", setup: unicode, args: plain()},
		{name: "empty rules", setup: func(r *rig) { r.capaOutput(`{"rules": {}}`) }, args: plain()},
		{name: "null document", setup: func(r *rig) { r.capaOutput(`null`) }, args: plain()},
		{name: "empty stdout", setup: func(r *rig) { r.capaOutput(``) }, args: plain()},
		{name: "no rules key", setup: func(r *rig) { r.capaOutput(`{"meta": 1}`) }, args: plain()},
		{name: "rules list", setup: func(r *rig) { r.capaOutput(`{"rules": []}`) }, args: plain()},
		{name: "rules null", setup: func(r *rig) { r.capaOutput(`{"rules": null}`) }, args: plain()},
		{name: "malformed", setup: func(r *rig) { r.capaOutput("{\"rules\": {\"a\": ") }, args: plain()},
		{name: "extra data", setup: func(r *rig) { r.capaOutput("{} []") }, args: plain()},
		{name: "analyzer exit", setup: func(r *rig) { r.capaOutput(""); r.capaFile("rc", "3") }, args: plain()},
		{name: "analyzer exit with output", setup: func(r *rig) { r.capaFile("rc", "1"); r.capaFile("err.txt", "boom\n") }, args: plain()},
		{name: "signal", setup: func(r *rig) { r.capaOutput(""); r.capaFile("rc", "137") }, args: plain()},
		{name: "timeout", setup: func(r *rig) { r.capaFile("sleep", "30") }, args: plain("--timeout", "1")},
		{name: "version stderr only", setup: func(r *rig) { r.capaFile("version", "") }, args: plain()},
		{name: "structural crash", crash: true, setup: func(r *rig) { r.capaOutput(`{"rules": {"x": 3}}`) }, args: plain()},
		{name: "output exists", setup: func(r *rig) { os.Mkdir(r.output("ev"), 0o755) }, args: plain()},
		{name: "stage exists", setup: func(r *rig) { os.Mkdir(filepath.Join(r.outDir, ".ev.stage"), 0o700) }, args: plain()},
		{name: "relative output", args: func(r *rig) []string {
			return []string{"--input", r.input(), "--output", "out/ev", "--rules", r.rules, "--manifest-cli", r.manifestCLI}
		}},
		{name: "relative input", args: func(r *rig) []string {
			return []string{"--input", "sample.bin", "--output", r.output("ev"), "--rules", r.rules, "--manifest-cli", r.manifestCLI}
		}},
		{name: "missing input", args: func(r *rig) []string {
			return []string{"--input", r.root + "/absent", "--output", r.output("ev"), "--rules", r.rules, "--manifest-cli", r.manifestCLI}
		}},
		{name: "input is directory", args: func(r *rig) []string {
			return []string{"--input", r.root, "--output", r.output("ev"), "--rules", r.rules, "--manifest-cli", r.manifestCLI}
		}},
		{name: "parent missing", args: func(r *rig) []string {
			return []string{"--input", r.input(), "--output", r.root + "/no/dir/ev", "--rules", r.rules, "--manifest-cli", r.input()}
		}},
		{name: "relative parent missing", args: func(r *rig) []string {
			return []string{"--input", r.input(), "--output", "no/dir/ev", "--rules", r.rules, "--manifest-cli", r.input()}
		}},
		{name: "relative manifest missing", args: func(r *rig) []string {
			return []string{"--input", r.input(), "--output", r.output("ev"), "--rules", r.rules, "--manifest-cli", "nope/m.py"}
		}},
		{name: "dotdot output", args: func(r *rig) []string {
			return []string{"--input", r.input(), "--output", r.outDir + "/../ev", "--rules", r.rules, "--manifest-cli", r.input()}
		}},
		{name: "backslash output", args: func(r *rig) []string {
			return []string{"--input", r.input(), "--output", r.outDir + `/a\b`, "--rules", r.rules, "--manifest-cli", r.input()}
		}},
		{name: "empty output", args: func(r *rig) []string {
			return []string{"--input", r.input(), "--output", "", "--rules", r.rules, "--manifest-cli", r.input()}
		}},
		{name: "root output", args: func(r *rig) []string {
			return []string{"--input", r.input(), "--output", "/", "--rules", r.rules, "--manifest-cli", r.input()}
		}},
		{name: "timeout zero", args: plain("--timeout", "0")},
		{name: "max caps negative", args: plain("--max-capabilities=-1")},
		{name: "missing capa", env: []string{"PATH=/nonexistent"}, args: plain()},
		{name: "configured capa missing", env: []string{"RSDD_CAPA=/nonexistent/capa"}, args: plain()},
		{name: "configured capa empty", env: []string{"RSDD_CAPA="}, args: plain()},
		{name: "configured bwrap mismatch", setup: func(r *rig) {
			r.write(filepath.Join(r.root, "other-bwrap"), fakeBwrap, 0o755)
		}, args: func(r *rig) []string {
			r.extraEv = []string{"RSDD_BWRAP=" + filepath.Join(r.root, "other-bwrap")}
			return plain()(r)
		}},
		{name: "rules missing", args: func(r *rig) []string { return r.input0("ev", r.root+"/nope") }},
		{name: "rules relative missing", args: func(r *rig) []string { return r.input0("ev", "nope/rules") }},
		{name: "rules is file", args: func(r *rig) []string { return r.input0("ev", r.input()) }},
		{name: "rules symlink", setup: func(r *rig) { os.Symlink(r.rules, filepath.Join(r.root, "rl")) }, args: func(r *rig) []string { return r.input0("ev", filepath.Join(r.root, "rl")) }},
		{name: "rules empty dir", setup: func(r *rig) { os.Mkdir(filepath.Join(r.root, "er"), 0o755) }, args: func(r *rig) []string { return r.input0("ev", filepath.Join(r.root, "er")) }},
		{name: "rules fifty yml", setup: func(r *rig) {
			os.Mkdir(filepath.Join(r.root, "fifty"), 0o755)
			os.Mkdir(filepath.Join(r.root, "fifty", "deep"), 0o755)
			for i := 0; i < 50; i++ {
				os.WriteFile(filepath.Join(r.root, "fifty", "deep", fmt.Sprintf("r%02d.yml", i)), nil, 0o644)
			}
		}, args: func(r *rig) []string { return r.input0("ev", filepath.Join(r.root, "fifty")) }},
		{name: "rules forty-nine yml", setup: func(r *rig) {
			os.Mkdir(filepath.Join(r.root, "f49"), 0o755)
			for i := 0; i < 49; i++ {
				os.WriteFile(filepath.Join(r.root, "f49", fmt.Sprintf("r%02d.yml", i)), nil, 0o644)
			}
		}, args: func(r *rig) []string { return r.input0("ev", filepath.Join(r.root, "f49")) }},
		{name: "rules nested structural is not enough", setup: func(r *rig) {
			os.MkdirAll(filepath.Join(r.root, "ns", "x", "nursery"), 0o755)
		}, args: func(r *rig) []string { return r.input0("ev", filepath.Join(r.root, "ns")) }},
		{name: "rules digest shape", setup: func(r *rig) {
			os.MkdirAll(filepath.Join(r.rules, "x", "y.yml"), 0o755)
			os.WriteFile(filepath.Join(r.rules, "x", "y.yml", "in.yml"), nil, 0o644)
			os.WriteFile(filepath.Join(r.rules, ".yml"), nil, 0o644)
			os.WriteFile(filepath.Join(r.rules, "UP.YML"), nil, 0o644)
			os.Symlink(filepath.Join(r.rules, "lib"), filepath.Join(r.rules, "linkdir"))
			os.Symlink(filepath.Join(r.rules, "nonexistent"), filepath.Join(r.rules, "broken.yml"))
		}, args: plain()},
		{name: "rules with dotdot and trailing slash", args: func(r *rig) []string { return r.input0("ev", r.rules+"/lib/../") }},
		{name: "rules tilde", env: nil, args: func(r *rig) []string { return r.input0("ev", "~/rules") }, setup: func(r *rig) {
			os.MkdirAll(filepath.Join(r.home, "rules", "lib"), 0o755)
		}},
		{name: "rules default", args: func(r *rig) []string {
			return []string{"--input", r.input(), "--output", r.output("ev"), "--manifest-cli", r.manifestCLI}
		}, setup: func(r *rig) { os.MkdirAll(filepath.Join(r.home, ".local", "share", "capa-rules", "lib"), 0o755) }},
		{name: "rules under home broad", args: func(r *rig) []string { return r.input0("ev", "/home") }},
		{name: "rules is home", args: func(r *rig) []string { return r.input0("ev", r.home) }},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) { c.run(t) })
	}
}

// TestParityCommandLines compares the argument parser and its usage, help and error texts.
func TestParityCommandLines(t *testing.T) {
	ok := []string{"--input", "a", "--output", "b", "--manifest-cli", "/nonexistent-manifest"}
	lines := [][]string{
		nil, {"-h"}, {"--help"}, {"--h"}, {"--he=x"}, {"-hx"}, {"-hfoo"}, {"-h=3"}, {"-h", "--bogus"}, {"--bogus", "-h"},
		{"--m", "x"}, {"--ma"}, {"--man=x"}, {"--max=3", "--man=q"}, {"--timeout"}, {"--timeout", "x"}, {"--timeout", "-5"},
		{"--timeout=-1_0"}, {"--timeout=1e3"}, {"--timeout", "-1.5"}, {"--timeout", "--", "5"}, {"--input", "--", "--output", "b"},
		{"--input"}, {"--input", "-a"}, {"--input", "- a"}, {"--input", "-"}, {"-5", "--input", "a"}, {"--input", "a", "-5"},
		{"--foo"}, {"-x", "--input", "a"}, {"--manifest-cli="}, {"--manifest-cli=", "--input=i", "--output="},
		append(append([]string{}, ok...), "extra"), append(append([]string{}, ok...), "--"), append(append([]string{}, ok...), "--", "x"),
		append(append([]string{}, ok...), "--unk=1", "x"), append(append([]string{}, ok...), "-z"),
		append(append([]string{}, ok...), "--timeout", "1_0"), append(append([]string{}, ok...), "--timeout", " 7 "),
		append(append([]string{}, ok...), "--timeout", "+9", "--max-capabilities", "0"),
		append(append([]string{}, ok...), "--timeout", "٣"), append(append([]string{}, ok...), "--timeout", strings.Repeat("9", 4301)),
		{"--input", "a", "--input", "b", "--output", "o", "--manifest-cli", "/nonexistent-manifest"},
		{"--timeout=x", "--bogus", "--m", "x"},
	}
	narrow := [][]string{nil, {"-h"}, {"--timeout"}}
	for _, cols := range []string{"", "80", "200", "50", "40", "30", "20", "abc", "0", "-3"} {
		set := lines
		if cols != "" && cols != "80" && cols != "200" {
			set = narrow
		}
		for _, args := range set {
			name := fmt.Sprintf("cols=%s %q", cols, args)
			var env []string
			if cols != "" {
				env = []string{"COLUMNS=" + cols}
			}
			t.Run(name, func(t *testing.T) {
				c := parityCase{name: name, env: env, args: func(*rig) []string { return args }}
				c.run(t)
			})
		}
	}
}

func bigInt(n int) *big.Int { return big.NewInt(int64(n)) }

// ---------------------------------------------------------------- JSON reader and inventory against the legacy functions

// oracleScript drives the legacy module's _read_stdout_json and _build_inventory over a batch of documents.
const oracleScript = `
import sys, json, importlib.util, tempfile
from pathlib import Path
legacy, toolbelt = sys.argv[1], sys.argv[2]
sys.path.insert(0, toolbelt)
spec = importlib.util.spec_from_file_location("legacy_capa", legacy)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
canon = lambda v: json.dumps(v, sort_keys=True, separators=(",", ":"), allow_nan=False)
out = []
for c in json.load(sys.stdin):
    raw = bytes.fromhex(c["hex"])
    try:
        if c["op"] == "read":
            with tempfile.TemporaryDirectory() as d:
                p = Path(d) / "stdout.txt"
                p.write_bytes(raw)
                v, e = m._read_stdout_json(p)
            out.append({"ok": True, "value": canon(v), "err": e})
        else:
            inv, lims = m._build_inventory(json.loads(raw), c["max"])
            out.append({"ok": True, "value": canon(inv), "lims": lims})
    except Exception as e:
        out.append({"ok": False, "exc": type(e).__name__})
json.dump(out, sys.stdout)
`

type oracleCase struct {
	Op  string `json:"op"`
	Hex string `json:"hex"`
	Max int    `json:"max"`
}

type oracleResult struct {
	OK    bool     `json:"ok"`
	Value string   `json:"value"`
	Err   *string  `json:"err"`
	Lims  []string `json:"lims"`
	Exc   string   `json:"exc"`
}

func runOracle(t *testing.T, cases []oracleCase) []oracleResult {
	t.Helper()
	in, _ := json.Marshal(cases)
	script, _ := filepath.Abs(legacyScript)
	tb, _ := filepath.Abs(toolbeltDir)
	cmd := exec.Command(python312(t), "-I", "-c", oracleScript, script, tb)
	var out, errb bytes.Buffer
	cmd.Stdin, cmd.Stdout, cmd.Stderr = bytes.NewReader(in), &out, &errb
	if err := cmd.Run(); err != nil {
		t.Fatalf("oracle: %v\n%s", err, errb.String())
	}
	var rs []oracleResult
	if err := json.Unmarshal(out.Bytes(), &rs); err != nil || len(rs) != len(cases) {
		t.Fatalf("oracle output: %v (%d results for %d cases)", err, len(rs), len(cases))
	}
	return rs
}

func canonString(t *testing.T, v any) string {
	t.Helper()
	b, err := jsonout.Canonical(v)
	if err != nil {
		t.Fatalf("canonical: %v", err)
	}
	return strings.TrimSuffix(string(b), "\n")
}

var readCorpus = []string{
	`not json at all {{{{`, ``, ` `, `{`, `}`, `[`, `]`, `{"a": 1,}`, `{"a" 1}`, `{"a": 1 "b"}`, `[1,]`, `[1 2]`, `{"a": "x`,
	"{\"a\": \"x\ny\"}", "{\"a\": \"x\ty\"}", `{"a": "\q"}`, `{"a": "\u12g4"}`, `{"a": "\u12"}`, `"\`, `{} extra`,
	"{\n  \"a\": tru\n}", "{\n\n\n   x}", `-`, `-x`, `01`, `1.`, `.5`, `1e`, `1e+`, `+1`, `nul`, `nulll`, `true false`, `tru`,
	`{"a":`, `{"a":1`, `[1`, `[[[[`, `{"a": {"b": [1, 2, {"c": null}]}}`, `"\u00e9\ud83d\ude00"`, `"\ud83d\u0041"`[:0] + `"x"`,
	`[1e5, 1E+2, -0.0, 0e0, 1.5e300, 123456789012345678901234567890, -0, 0.1, 100000000000000000000.0, 1e-7]`,
	`{"a":1,"a":2}`, "\xef\xbb\xbf{}", "\xef\xbb\xbf", "\t\r\n {} \t\r\n", `{"é": "ü"}`, "{\"a\": \"\\/\\b\\f\\n\\r\\t\\\\\\\"\"}",
	`{"rules": {"a": {"meta": {"namespace": "n"}, "matches": []}}}`, `null`, `[]`, `"s"`, `1`, `true`,
}

func TestParityReadStdoutJSON(t *testing.T) {
	var cases []oracleCase
	for _, d := range readCorpus {
		cases = append(cases, oracleCase{Op: "read", Hex: hex.EncodeToString([]byte(d))})
	}
	for i, want := range runOracle(t, cases) {
		doc := []byte(readCorpus[i])
		path := filepath.Join(t.TempDir(), "stdout.txt")
		os.WriteFile(path, doc, 0o644)
		v, msg, err := readStdoutJSON(path)
		if !want.OK {
			if err == nil {
				t.Errorf("%q: legacy raised %s, port returned (%v, %q)", doc, want.Exc, v, msg)
			}
			continue
		}
		if err != nil {
			t.Errorf("%q: legacy returned, port failed: %v", doc, err)
			continue
		}
		wantErr := ""
		if want.Err != nil {
			wantErr = *want.Err
		}
		if msg != wantErr {
			t.Errorf("%q: message legacy %q, port %q", doc, wantErr, msg)
		}
		if v != nil || want.Value != "null" {
			if got := canonString(t, v); got != want.Value {
				t.Errorf("%q: value legacy %s, port %s", doc, want.Value, got)
			}
		}
	}
}

var inventoryCorpus = []string{
	`{"rules": {"b": {"meta": {"namespace": "n/2", "attack": [{"id": "T1"}, {"id": ""}, {"id": 0}, {"id": [1]}, {"x": 1}, {"id": null}, {"id": 3}], "mbc": [{"id": "M1"}]}, "matches": [[1,2],[3,4]]},
	  "a": {"meta": {"namespace": "n/1"}, "matches": []}, "c": {"meta": {"namespace": "n/1"}, "matches": "abc"}, "d": {"matches": {"k": 1, "j": 2}}}}`,
	`{"rules": {"x": {}}}`, `{"rules": {"x": {"meta": null}}}`, `{"rules": {"x": {"meta": []}}}`, `{"rules": {"x": {"meta": {}, "matches": null}}}`,
	`{"rules": {"x": {"meta": {}, "matches": 3}}}`, `{"rules": {"x": {"meta": {"attack": null}}}}`, `{"rules": {"x": {"meta": {"attack": {}}}}}`,
	`{"rules": {"x": {"meta": {"attack": {"k": 1}}}}}`, `{"rules": {"x": {"meta": {"attack": ""}}}}`, `{"rules": {"x": {"meta": {"attack": "ab"}}}}`,
	`{"rules": {"x": {"meta": {"attack": ["T"]}}}}`, `{"rules": {"x": {"meta": {"attack": 5}}}}`, `{"rules": {"x": {"meta": {"mbc": [[]]}}}}`,
	`{"rules": {"x": {"meta": {"namespace": null}}, "y": {"meta": {"namespace": null}}}}`, `{"rules": {"x": {"meta": {"namespace": 1}}}}`,
	`{"rules": {"x": {"meta": {"namespace": "s"}}, "y": {"meta": {"namespace": 2}}}}`, `{"rules": {"x": {"meta": {"namespace": ["a"]}}}}`,
	`{"rules": {"x": 3}}`, `{"rules": {"x": []}}`, `{"rules": {"x": null}}`, `{"rules": 5}`, `{"rules": "s"}`, `{"rules": true}`, `{"rules": 1.5}`,
	`[]`, `"s"`, `3`, `null`, `{}`, `{"rules": {"é": {"meta": {"namespace": "ü"}}, "e": {"meta": {"namespace": "ü"}}}}`,
}

func TestParityBuildInventory(t *testing.T) {
	for _, max := range []int{1, 2, 3, 500} {
		var cases []oracleCase
		for _, d := range inventoryCorpus {
			cases = append(cases, oracleCase{Op: "inventory", Hex: hex.EncodeToString([]byte(d)), Max: max})
		}
		for i, want := range runOracle(t, cases) {
			name := fmt.Sprintf("max=%d %s", max, inventoryCorpus[i])
			v, derr := decodeJSON([]byte(inventoryCorpus[i]))
			var inv inventory
			var lims []string
			err := derr
			if err == nil {
				inv, lims, err = buildInventory(v, bigInt(max))
			}
			if !want.OK {
				if err == nil {
					t.Errorf("%s: legacy raised %s, port returned %+v", name, want.Exc, inv)
				}
				continue
			}
			if err != nil {
				t.Errorf("%s: legacy returned, port failed: %v", name, err)
				continue
			}
			got := canonString(t, map[string]any{"items": inv.items, "total_count": inv.totalCount, "total_sampled": inv.totalSampled, "truncated": inv.truncated})
			if got != want.Value {
				t.Errorf("%s:\nlegacy %s\nport   %s", name, want.Value, got)
			}
			if strings.Join(lims, "|") != strings.Join(want.Lims, "|") {
				t.Errorf("%s: limitations legacy %v, port %v", name, want.Lims, lims)
			}
		}
	}
}
