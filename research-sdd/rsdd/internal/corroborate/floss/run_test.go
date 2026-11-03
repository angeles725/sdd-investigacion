//go:build unix

package floss

// End-to-end tests: the real command, the real bwrap, a fake floss (a shell script in a venv-shaped tree) and
// the real analysis_manifest.py. They replace the logic cases of tests/floss.test.sh; the case-to-test map is
// in the head of the commit that slimmed that suite:
//
//	T1  happy path            TestRunHappyPathPublishesEvidence
//	T2  evidence schema       TestRunHappyPathPublishesEvidence
//	T3  determinism           TestRunIsDeterministic
//	T4  analysis manifest     TestRunManifestValidatesAndVerifies
//	T5  string cap            TestRunStringCap
//	T6  string-length cap     TestRunStringLengthCap
//	T7  empty input           TestRunSilentFlossIsACompleteEmptyInventory
//	T8  output-dir-exists     TestRunRefusals ("output exists")
//	T9  O_NOFOLLOW symlink    TestReadStdoutJSONRefusesALink
//	T10 isolation profile     TestRunHappyPathPublishesEvidence
//	T11 _read_stdout_json     TestReadStdoutJSONMalformedIsAnExplicitError, TestReadStdoutJSONEmptyFileIsNoOutput
//	T12 timeout visibility    TestRunTimeoutIsVisible
//	teeth-1 length cap        TestBuildInventoryStringLengthCap

import (
	"bytes"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func evidence(t *testing.T, w *world, dir string) map[string]any {
	t.Helper()
	var d map[string]any
	if err := json.Unmarshal(w.read(filepath.Join(dir, "floss-evidence.v1.json")), &d); err != nil {
		t.Fatal(err)
	}
	return d
}

func sub(t *testing.T, m map[string]any, keys ...string) map[string]any {
	t.Helper()
	for _, k := range keys {
		next, ok := m[k].(map[string]any)
		if !ok {
			t.Fatalf("%v is not an object in %v", k, m)
		}
		m = next
	}
	return m
}

func TestRunHappyPathPublishesEvidence(t *testing.T) {
	w := newWorld(t, flossHappy)
	code, stdout, stderr := w.run(w.out("out"))
	if code != 0 || stdout != "" || stderr != "" {
		t.Fatalf("code=%d stdout=%q stderr=%q", code, stdout, stderr)
	}
	d := evidence(t, w, "out")
	if d["schema"] != "floss-evidence.v1" || d["status"] != "complete" || !reflect.DeepEqual(d["errors"], []any{}) {
		t.Fatalf("envelope: %v", d)
	}
	s := sub(t, d, "strings")
	for _, cat := range []string{"static_strings", "stack_strings", "tight_strings", "decoded_strings"} {
		c := sub(t, s, cat)
		if c["truncated"] != false {
			t.Errorf("%s: %v", cat, c)
		}
		for _, e := range c["strings"].([]any) {
			e := e.(map[string]any)
			if !strings.HasPrefix(e["sha256"].(string), "sha256:") || e["value"] == nil || e["offset"] == nil {
				t.Errorf("%s entry: %v", cat, e)
			}
		}
	}
	if s["total_count"] != float64(5) || s["total_sampled"] != float64(5) || s["truncated"] != false {
		t.Errorf("totals: %v", s)
	}
	static := sub(t, s, "static_strings")["strings"].([]any)
	if static[0].(map[string]any)["value"] != "StaticAlpha" || static[1].(map[string]any)["value"] != "StaticBeta" {
		t.Errorf("static strings must be sorted by offset: %v", static)
	}
	// Containment (CONTAINMENT guard of the shell suite): the recorded profile denies the network and execution.
	iso := sub(t, d, "isolation")
	profile := sub(t, iso, "profile")
	if profile["network_access"] != false || profile["target_execution"] != false || profile["name"] != "bubblewrap-floss-offline" {
		t.Errorf("profile: %v", profile)
	}
	if sub(t, iso, "launcher")["path"] == "" || s["floss_version"] != "floss 3.1.1-fake" {
		t.Errorf("launcher/version: %v / %v", iso, s["floss_version"])
	}
	argv := s["argv"].([]any)
	if len(argv) != 3 || argv[1] != "-j" || argv[2] != "/tmp/rsdd/work/input/binary.bin" {
		t.Errorf("argv: %v", argv)
	}
	if sub(t, s, "caps")["timeout"] != float64(120) || sub(t, d, "input", "staged")["path"] != "input/binary.bin" {
		t.Errorf("caps/input: %v", d)
	}
	entries, _ := os.ReadDir(w.root)
	for _, e := range entries {
		if strings.HasSuffix(e.Name(), ".stage") {
			t.Errorf("stage directory left behind: %s", e.Name())
		}
	}
}

func TestRunIsDeterministic(t *testing.T) {
	w := newWorld(t, flossHappy)
	for _, n := range []string{"a", "b"} {
		if code, _, stderr := w.run(w.out(n)); code != 0 {
			t.Fatalf("run %s: code=%d %s", n, code, stderr)
		}
	}
	if !bytes.Equal(w.read("a/floss-evidence.v1.json"), w.read("b/floss-evidence.v1.json")) {
		t.Fatal("two runs must produce byte-identical evidence")
	}
}

func TestRunManifestValidatesAndVerifies(t *testing.T) {
	w := newWorld(t, flossHappy)
	if code, _, stderr := w.run(w.out("out")); code != 0 {
		t.Fatalf("code=%d %s", code, stderr)
	}
	manifest := w.out("out/engine/analysis-manifest.v1.json")
	for _, args := range [][]string{{"validate", manifest}, {"verify", "--root", w.out("out"), manifest}} {
		if out, err := exec.Command(w.python, append([]string{w.manifest}, args...)...).CombinedOutput(); err != nil {
			t.Fatalf("manifest %v: %v\n%s", args, err, out)
		}
	}
}

// --manifest-cli is accepted and ignored: omitted, pointing at a path that does not exist or at a real file, the
// run succeeds and publishes byte-identical evidence (the manifest steps run in process).
func TestRunIgnoresManifestCLI(t *testing.T) {
	w := newWorld(t, flossHappy)
	variants := []struct {
		name string
		flag []string
	}{
		{"omitted", nil},
		{"missing", []string{"--manifest-cli", "/nonexistent/manifest-tool"}},
		{"existing", []string{"--manifest-cli", w.manifest}},
	}
	var want []byte
	for _, v := range variants {
		var o, e bytes.Buffer
		out := w.out("ign-" + v.name)
		code := Run(append([]string{"--input", w.input, "--output", out}, v.flag...), w.stdio(&o, &e, nil))
		if code != 0 || o.Len() != 0 || e.Len() != 0 {
			t.Fatalf("%s: code=%d stdout=%q stderr=%q", v.name, code, o.String(), e.String())
		}
		got := w.read("ign-" + v.name + "/floss-evidence.v1.json")
		if want == nil {
			want = got
		} else if !bytes.Equal(got, want) {
			t.Errorf("%s: evidence differs from the other variants", v.name)
		}
	}
}

func TestRunStringCap(t *testing.T) {
	w := newWorld(t, flossHappy)
	if code, _, stderr := w.run(w.out("out"), "--max-strings", "2"); code != 0 {
		t.Fatalf("code=%d %s", code, stderr)
	}
	d := evidence(t, w, "out")
	s := sub(t, d, "strings")
	if s["total_sampled"] != float64(2) || s["truncated"] != true {
		t.Errorf("totals: %v", s)
	}
	if !contains(d["limitations"], "inventory truncated: string cap 2 reached") {
		t.Errorf("limitations: %v", d["limitations"])
	}
	if sub(t, s, "caps")["max_strings"] != float64(2) {
		t.Errorf("caps: %v", s["caps"])
	}
}

func TestRunStringLengthCap(t *testing.T) {
	w := newWorld(t, flossHappy)
	if code, _, stderr := w.run(w.out("out"), "--max-string-len", "5"); code != 0 {
		t.Fatalf("code=%d %s", code, stderr)
	}
	d := evidence(t, w, "out")
	s := sub(t, d, "strings")
	for _, cat := range []string{"static_strings", "stack_strings", "tight_strings", "decoded_strings"} {
		for _, e := range sub(t, s, cat)["strings"].([]any) {
			if v := e.(map[string]any)["value"].(string); len([]rune(v)) > 5 {
				t.Errorf("value exceeds the cap: %q", v)
			}
		}
	}
	if s["truncated"] != true || !contains(d["limitations"], "inventory truncated: string-length cap 5 reached") {
		t.Errorf("truncated=%v limitations=%v", s["truncated"], d["limitations"])
	}
}

func contains(list any, want string) bool {
	for _, l := range list.([]any) {
		if l == want {
			return true
		}
	}
	return false
}

func TestRunSilentFlossIsACompleteEmptyInventory(t *testing.T) {
	w := newWorld(t, flossSilent)
	if code, _, stderr := w.run(w.out("out")); code != 0 {
		t.Fatalf("code=%d %s", code, stderr)
	}
	d := evidence(t, w, "out")
	s := sub(t, d, "strings")
	if d["status"] != "complete" || s["total_count"] != float64(0) || s["total_sampled"] != float64(0) || s["truncated"] != false {
		t.Errorf("evidence: %v", d)
	}
}

func TestRunFlossFailureIsPublishedAsFailedEvidence(t *testing.T) {
	w := newWorld(t, flossFails)
	code, _, stderr := w.run(w.out("out"))
	if code != 1 {
		t.Fatalf("code=%d stderr=%s", code, stderr)
	}
	d := evidence(t, w, "out")
	if d["status"] != "failed" || !reflect.DeepEqual(d["errors"], []any{"analyzer-exit:1"}) || sub(t, d, "strings")["truncated"] != false {
		t.Errorf("evidence: %v", d)
	}
	want := "floss-evidence.v1: completed with issues (analyzer-exit:1) — see " + w.out("out") + "/floss-evidence.v1.json\n"
	if stderr != want {
		t.Errorf("stderr = %q, want %q", stderr, want)
	}
	if got := string(w.read("out/engine/stderr.txt")); got != "ERROR: not a PE\n" {
		t.Errorf("captured stderr = %q", got)
	}
}

func TestRunMalformedFlossJSONIsAnExplicitError(t *testing.T) {
	w := newWorld(t, flossJunk)
	code, _, _ := w.run(w.out("out"))
	d := evidence(t, w, "out")
	want := []any{"malformed JSON in floss stdout: Expecting value: line 1 column 1 (char 0)"}
	if code != 1 || d["status"] != "failed" || !reflect.DeepEqual(d["errors"], want) || sub(t, d, "strings")["total_count"] != float64(0) {
		t.Errorf("code=%d evidence=%v", code, d)
	}
}

func TestRunTimeoutIsVisible(t *testing.T) {
	w := newWorld(t, flossSlow)
	code, _, _ := w.run(w.out("out"), "--timeout", "1")
	if code != 1 {
		t.Fatalf("code=%d", code)
	}
	d := evidence(t, w, "out")
	s := sub(t, d, "strings")
	if d["status"] != "failed" || !reflect.DeepEqual(d["errors"], []any{"timeout"}) || s["truncated"] != true {
		t.Errorf("evidence: %v", d)
	}
	if !contains(d["limitations"], "floss run truncated: timeout reached — inventory is incomplete") {
		t.Errorf("limitations: %v", d["limitations"])
	}
}

func TestRunOutputCapIsVisible(t *testing.T) {
	w := newWorld(t, flossFlood)
	code, _, _ := w.run(w.out("out"))
	d := evidence(t, w, "out")
	if code != 1 || !contains(d["errors"], "output-cap") || sub(t, d, "strings")["truncated"] != true {
		t.Errorf("code=%d evidence=%v", code, d["errors"])
	}
	if fi, err := os.Stat(w.out("out/engine/stdout.txt")); err != nil || fi.Size() > maxOutputBytes {
		t.Errorf("captured output must be cut to the cap: %v %v", fi, err)
	}
}

func TestRunVersionProbeFailureIsUnknown(t *testing.T) {
	w := newWorld(t, flossNoVersion)
	if code, _, stderr := w.run(w.out("out")); code != 0 {
		t.Fatalf("code=%d %s", code, stderr)
	}
	if v := sub(t, evidence(t, w, "out"), "strings")["floss_version"]; v != "unknown" {
		t.Errorf("floss_version = %v", v)
	}
}

func TestRunRefusesShapesItCannotSample(t *testing.T) {
	w := newWorld(t, flossList)
	code, stdout, stderr := w.run(w.out("out"))
	if code != 2 || stdout != "" || stderr != "corroborate-floss: unsupported floss JSON shape: top level is an array, not an object\n" {
		t.Fatalf("code=%d stdout=%q stderr=%q", code, stdout, stderr)
	}
	assertNothingPublished(t, w, "out")
}

func assertNothingPublished(t *testing.T, w *world, name string) {
	t.Helper()
	entries, _ := os.ReadDir(w.root)
	for _, e := range entries {
		if e.Name() == name || e.Name() == "."+name+".stage" {
			t.Errorf("%s must not exist after a refusal", e.Name())
		}
	}
}

func TestRunRefusals(t *testing.T) {
	w := newWorld(t, flossHappy)
	must(t, os.Mkdir(w.out("taken"), 0o755))
	must(t, os.Symlink(w.out("taken"), w.out("link")))
	must(t, os.WriteFile(w.out("floss"), []byte("#!/bin/sh\nexit 0\n"), 0o755))
	cases := []struct {
		name  string
		extra []string
		out   string
		env   map[string]string
		want  string
	}{
		{"timeout below one", []string{"--timeout", "0"}, w.out("o1"), nil, "--timeout must be >= 1"},
		{"max strings below one", []string{"--max-strings", "-3"}, w.out("o2"), nil, "--max-strings must be >= 1"},
		{"max string len below one", []string{"--max-string-len", "0"}, w.out("o3"), nil, "--max-string-len must be >= 1"},
		{"output with dotdot", nil, w.root + "/x/../o4", nil, "output must be a canonical path"},
		{"output with backslash", nil, w.out(`o\5`), nil, "output must be a canonical path"},
		{"output exists", nil, w.out("taken"), nil, "output must be a new non-colliding path"},
		{"output is a link", nil, w.out("link"), nil, "output must be a new non-colliding path"},
		{"output parent missing", nil, w.out("nodir/o6"), nil, "[Errno 2] No such file or directory: " + pyRepr(w.out("nodir"))},
		{"floss not on PATH", nil, w.out("o7"), map[string]string{"PATH": "/usr/bin:/bin"}, "PATH-selected floss is missing"},
		{"floss wrapper outside a venv", nil, w.out("o8"), map[string]string{"PATH": filepath.Join(w.root, "pybin") + ":" + w.root + ":/usr/bin:/bin", "RSDD_FLOSS": w.out("floss")}, "tool executable is not inside a 'bin/' directory: " + w.out("floss")},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			code, stdout, stderr := w.runEnv(c.env, c.out, c.extra...)
			if code != 2 || stdout != "" || stderr != "corroborate-floss: "+c.want+"\n" {
				t.Fatalf("code=%d stdout=%q\nstderr=%q\nwant   %q", code, stdout, stderr, "corroborate-floss: "+c.want+"\n")
			}
			if base := filepath.Base(c.out); base != "taken" && base != "link" {
				assertNothingPublished(t, w, base)
			}
		})
	}
	if entries, _ := os.ReadDir(w.out("taken")); len(entries) != 0 {
		t.Errorf("an existing output directory must stay untouched: %v", entries)
	}
}

func TestRunRefusesAnUnreadableInput(t *testing.T) {
	w := newWorld(t, flossHappy)
	code, _, stderr := w.runInput(w.out("nope.bin"), w.out("o1"))
	if code != 2 || stderr != "corroborate-floss: source cannot be opened safely\n" {
		t.Errorf("missing input: code=%d stderr=%q", code, stderr)
	}
	code, _, stderr = w.runInput(w.root, w.out("o2"))
	if code != 2 || stderr != "corroborate-floss: source is not a regular file\n" {
		t.Errorf("directory input: code=%d stderr=%q", code, stderr)
	}
	assertNothingPublished(t, w, "o1")
	assertNothingPublished(t, w, "o2")
}

func (w *world) runInput(input, output string) (int, string, string) {
	var o, e bytes.Buffer
	code := Run([]string{"--input", input, "--output", output, "--manifest-cli", w.manifest}, w.stdio(&o, &e, nil))
	return code, o.String(), e.String()
}

func TestRunNeverDeletesAStageItDidNotCreate(t *testing.T) {
	w := newWorld(t, flossHappy)
	foreign := w.out(".out.stage")
	must(t, os.Mkdir(foreign, 0o700))
	must(t, os.WriteFile(filepath.Join(foreign, "keep"), []byte("x"), 0o600))
	code, _, stderr := w.run(w.out("out"))
	if code != 2 || stderr != "corroborate-floss: [Errno 17] File exists: "+pyRepr(foreign)+"\n" {
		t.Fatalf("code=%d stderr=%q", code, stderr)
	}
	if _, err := os.Stat(filepath.Join(foreign, "keep")); err != nil {
		t.Errorf("the other run's stage was deleted: %v", err)
	}
}

func TestRunUsageIsRefusedBeforeAnyWork(t *testing.T) {
	w := newWorld(t, flossHappy)
	var o, e bytes.Buffer
	code := Run([]string{"--input", w.input}, w.stdio(&o, &e, nil))
	if code != 2 || o.Len() != 0 || !strings.HasSuffix(e.String(), "corroborate-floss: error: the following arguments are required: --output\n") {
		t.Fatalf("code=%d stdout=%q stderr=%q", code, o.String(), e.String())
	}
}
