package native

import (
	"crypto/sha256"
	"encoding/hex"
	"os"
	"reflect"
	"strings"
	"testing"
)

func sha(b []byte) string { h := sha256.Sum256(b); return "sha256:" + hex.EncodeToString(h[:]) }

func TestHappyPathPublishesCompleteEvidence(t *testing.T) {
	w := newWorld(t)
	w.r2(`[{"name":"z","offset":8192,"size":2},{"name":"a","offset":4096,"size":10,"nargs":0,"nbbs":1,"type":"fcn","junk":true}]`)
	if rc := w.run("out"); rc != 0 {
		t.Fatalf("rc=%d stderr=%q", rc, w.errBuf.String())
	}
	if w.errBuf.Len() != 0 || w.out.Len() != 0 {
		t.Fatalf("a complete run is silent: out=%q err=%q", w.out.String(), w.errBuf.String())
	}
	rep := w.readJSON("out/native-static.v1.json")
	if rep["schema"] != "native-static.v1" || rep["status"] != "complete" {
		t.Fatalf("schema/status: %v %v", rep["schema"], rep["status"])
	}
	src, _ := os.ReadFile(w.input)
	if sub(rep, "input", "source", "sha256") != sha(src) || sub(rep, "input", "staged", "sha256") != sha(src) {
		t.Fatalf("input identities: %v", rep["input"])
	}
	if sub(rep, "input", "source", "path") != w.input || sub(rep, "input", "staged", "path") != "input/target.bin" {
		t.Fatalf("input paths: %v", rep["input"])
	}
	if sub(rep, "engine", "launcher", "staged", "path") != "engine/r2" ||
		sub(rep, "engine", "launcher", "source", "sha256") != sub(rep, "engine", "launcher", "staged", "sha256") {
		t.Fatalf("launcher: %v", sub(rep, "engine", "launcher"))
	}
	if sub(rep, "engine", "name") != "radare2" || sub(rep, "engine", "version") != "radare2 fake 1" {
		t.Fatalf("engine: %v", rep["engine"])
	}
	fns := rep["functions"].([]any)
	if len(fns) != 2 || fns[0].(map[string]any)["name"] != "a" || fns[1].(map[string]any)["name"] != "z" {
		t.Fatalf("functions must be sorted by offset: %v", fns)
	}
	if _, junk := fns[0].(map[string]any)["junk"]; junk {
		t.Fatalf("only the whitelisted record keys survive: %v", fns[0])
	}
	if !reflect.DeepEqual(sub(rep, "counts"), map[string]any{"functions_total": 2.0, "functions_emitted": 2.0}) {
		t.Fatalf("counts: %v", rep["counts"])
	}
	if !reflect.DeepEqual(sub(rep, "caps"), map[string]any{"timeout_seconds": 30.0, "max_bytes": 2e6, "max_files": 8.0, "max_functions": 1e4}) {
		t.Fatalf("caps: %v", rep["caps"])
	}
	if sub(rep, "truncated", "functions") != false || len(rep["errors"].([]any)) != 0 || len(rep["limitations"].([]any)) != 3 {
		t.Fatalf("truncated/errors/limitations: %v", rep)
	}
	if sub(rep, "isolation", "profile", "name") != "bubblewrap-static-network-denied" {
		t.Fatalf("isolation: %v", rep["isolation"])
	}
	if rep["runtime"].(map[string]any)["kernel"] == nil {
		t.Fatalf("runtime: %v", rep["runtime"])
	}
	argv := sub(rep, "engine", "argv").([]any)
	if argv[0] != "engine/r2" || argv[len(argv)-1] != "input/target.bin" {
		t.Fatalf("argv: %v", argv)
	}
	mani := w.readJSON("out/engine/analysis-manifest.v1.json")
	if sub(rep, "engine", "manifest_identity") != mani["identity"] || mani["completeness"] != "complete" {
		t.Fatalf("manifest binding: %v vs %v", sub(rep, "engine", "manifest_identity"), mani["identity"])
	}
	w.verify(w.path("out"))
	for rel, mode := range map[string]os.FileMode{"out/engine/r2": 0o500, "out/input/target.bin": 0o400} {
		fi, err := os.Stat(w.path(rel))
		if err != nil || fi.Mode().Perm() != mode {
			t.Fatalf("%s mode %v err %v want %v", rel, fi, err, mode)
		}
	}
	if w.exists(".out.stage") || w.exists("out/engine/manifest-spec.json") {
		t.Fatal("neither the stage nor the manifest spec may survive")
	}
	fx, _ := os.ReadFile(w.path("out/engine/functions.json"))
	if !strings.HasPrefix(string(fx), `[{"name":"a",`) || !strings.HasSuffix(string(fx), "]\n") {
		t.Fatalf("functions.json is canonical: %q", fx)
	}
}

func TestOutputIsDeterministic(t *testing.T) {
	w := newWorld(t)
	if w.run("a") != 0 || w.run("b") != 0 {
		t.Fatalf("runs failed: %s", w.errBuf.String())
	}
	a, _ := os.ReadFile(w.path("a/native-static.v1.json"))
	b, _ := os.ReadFile(w.path("b/native-static.v1.json"))
	if string(a) != string(b) {
		t.Fatalf("two runs differ:\n%s\n%s", a, b)
	}
}

func TestFunctionCapIsPartialEvidenceWithExit1(t *testing.T) {
	w := newWorld(t)
	w.r2(`[{"name":"z","offset":2},{"name":"a","offset":1}]`)
	if rc := w.run("capped", "--max-functions", "1"); rc != 1 {
		t.Fatalf("rc=%d err=%q", rc, w.errBuf.String())
	}
	rep := w.readJSON("capped/native-static.v1.json")
	mani := w.readJSON("capped/engine/analysis-manifest.v1.json")
	if rep["status"] != "partial" || mani["completeness"] != "partial" {
		t.Fatalf("status %v completeness %v", rep["status"], mani["completeness"])
	}
	if !reflect.DeepEqual(rep["counts"], map[string]any{"functions_total": 2.0, "functions_emitted": 1.0}) || sub(rep, "truncated", "functions") != true {
		t.Fatalf("counts/truncated: %v %v", rep["counts"], rep["truncated"])
	}
	if got := rep["functions"].([]any)[0].(map[string]any)["name"]; got != "a" {
		t.Fatalf("the first function by offset is kept, got %v", got)
	}
	w.verify(w.path("capped"))
	want := "native-static.v1: completed with issues — see " + w.path("capped") + "/native-static.v1.json\n"
	if w.errBuf.String() != want {
		t.Fatalf("stderr pointer:\n got %q\nwant %q", w.errBuf.String(), want)
	}
}

func TestOutputCapKillsAndBoundsNoisyAnalyzer(t *testing.T) {
	w := newWorld(t)
	w.r2Raw("yes x | head -c 100000")
	if rc := w.run("noisy", "--max-bytes", "100"); rc != 1 {
		t.Fatalf("rc=%d err=%q", rc, w.errBuf.String())
	}
	rep := w.readJSON("noisy/native-static.v1.json")
	if !reflect.DeepEqual(rep["errors"], []any{"output-cap"}) || rep["status"] != "failed" {
		t.Fatalf("errors %v status %v", rep["errors"], rep["status"])
	}
	fi, err := os.Stat(w.path("noisy/engine/stdout.txt"))
	if err != nil || fi.Size() > 100 {
		t.Fatalf("stdout.txt must be cut to the cap: %v %v", fi, err)
	}
	if !strings.Contains(w.errBuf.String(), "(output-cap)") {
		t.Fatalf("stderr pointer must name the cause: %q", w.errBuf.String())
	}
	w.verify(w.path("noisy"))
}

func TestOutputExactlyAtCapIsNotAnError(t *testing.T) {
	w := newWorld(t)
	w.r2Raw("printf '[]'")
	if rc := w.run("exact", "--max-bytes", "2"); rc != 0 {
		t.Fatalf("2 bytes under a 2 byte cap is within the cap; rc=%d err=%q", rc, w.errBuf.String())
	}
}

func TestAnalyzerFailurePublishesTruthfulEvidence(t *testing.T) {
	w := newWorld(t)
	w.r2Raw("echo '[]'; exit 9")
	if rc := w.run("failed"); rc != 1 {
		t.Fatalf("rc=%d", rc)
	}
	rep := w.readJSON("failed/native-static.v1.json")
	if rep["status"] != "failed" || sub(rep, "engine", "run", "exit_code") != 9.0 || sub(rep, "engine", "run", "signal") != nil {
		t.Fatalf("report: %v", rep["engine"])
	}
	if !reflect.DeepEqual(rep["errors"], []any{"analyzer-exit:9"}) {
		t.Fatalf("errors: %v", rep["errors"])
	}
	w.verify(w.path("failed"))
	want := "native-static.v1: completed with issues (analyzer-exit:9) — see " + w.path("failed") + "/native-static.v1.json\n"
	if w.errBuf.String() != want {
		t.Fatalf("stderr %q want %q", w.errBuf.String(), want)
	}
}

func TestTimeoutIsBoundedPublishedAndCleaned(t *testing.T) {
	w := newWorld(t)
	w.r2Raw("sleep 5")
	if rc := w.run("timeout", "--timeout-seconds", "1"); rc != 1 {
		t.Fatalf("rc=%d err=%q", rc, w.errBuf.String())
	}
	rep := w.readJSON("timeout/native-static.v1.json")
	if rep["status"] != "failed" || !reflect.DeepEqual(rep["errors"], []any{"timeout"}) {
		t.Fatalf("report: %v %v", rep["status"], rep["errors"])
	}
	if sub(rep, "engine", "run", "exit_code") != nil || sub(rep, "engine", "run", "signal") == nil {
		t.Fatalf("a killed run has a signal and no exit code: %v", sub(rep, "engine", "run"))
	}
	if w.exists(".timeout.stage") {
		t.Fatal("stage must be cleaned")
	}
}

func TestInvalidFunctionsJSONIsFailedEvidence(t *testing.T) {
	for name, body := range map[string]string{
		"garbage":    "{bad",
		"not-list":   `{"a":1}`,
		"bad-offset": `[{"name":"x","offset":"zero"}]`,
		"bad-name":   `[{"name":5,"offset":1}]`,
		"trailing":   `[] []`,
	} {
		t.Run(name, func(t *testing.T) {
			w := newWorld(t)
			w.r2(body)
			if rc := w.run("bad"); rc != 1 {
				t.Fatalf("rc=%d err=%q", rc, w.errBuf.String())
			}
			rep := w.readJSON("bad/native-static.v1.json")
			if rep["status"] != "failed" || !reflect.DeepEqual(rep["errors"], []any{"invalid-functions-json"}) {
				t.Fatalf("report: %v %v", rep["status"], rep["errors"])
			}
			if !reflect.DeepEqual(rep["counts"], map[string]any{"functions_total": 0.0, "functions_emitted": 0.0}) {
				t.Fatalf("counts: %v", rep["counts"])
			}
		})
	}
}

func TestStagingPathIsScrubbedFromAnalyzerOutput(t *testing.T) {
	w := newWorld(t)
	w.r2Raw("echo \"$PWD leaked\" >&2; echo '[]'")
	if rc := w.run("scrub"); rc != 0 {
		t.Fatalf("rc=%d err=%q", rc, w.errBuf.String())
	}
	b, _ := os.ReadFile(w.path("scrub/engine/stderr.txt"))
	if strings.Contains(string(b), w.root) || !strings.Contains(string(b), "<STAGING_ROOT> leaked") {
		t.Fatalf("stderr.txt: %q", b)
	}
	w.verify(w.path("scrub"))
}

func TestStagedBytesCannotChangeAfterStaging(t *testing.T) {
	w := newWorld(t)
	w.r2(`[{"name":"ORIGINAL","offset":1}]`)
	orig, _ := os.ReadFile(w.input)
	origR2, _ := os.ReadFile(w.path("bin/r2"))
	w.d.beforeRun = func(string) {
		must(t, os.WriteFile(w.input, append(orig, []byte("\nsource mutation\n")...), 0o644))
		repl := w.path("bin/r2.new")
		must(t, os.WriteFile(repl, []byte("#!/bin/sh\n[ \"${1:-}\" = -v ] && { echo replacement; exit 0; }\necho '[{\"name\":\"REPLACEMENT_EXECUTED\",\"offset\":2}]'\n"), 0o755))
		must(t, os.Rename(repl, w.path("bin/r2")))
	}
	if rc := w.run("race"); rc != 0 {
		t.Fatalf("rc=%d err=%q", rc, w.errBuf.String())
	}
	rep := w.readJSON("race/native-static.v1.json")
	if rep["functions"].([]any)[0].(map[string]any)["name"] != "ORIGINAL" {
		t.Fatalf("the staged launcher must run, not the replacement: %v", rep["functions"])
	}
	if sub(rep, "input", "source", "sha256") != sha(orig) || sub(rep, "input", "staged", "sha256") != sha(orig) {
		t.Fatalf("input identity: %v", rep["input"])
	}
	if sub(rep, "engine", "launcher", "source", "sha256") != sha(origR2) || sub(rep, "engine", "launcher", "staged", "sha256") != sha(origR2) {
		t.Fatalf("launcher identity: %v", sub(rep, "engine", "launcher"))
	}
	mani := w.readJSON("race/engine/analysis-manifest.v1.json")
	art := sub(mani, "tool", "artifacts").([]any)[0].(map[string]any)
	if art["path"] != "engine/r2" || art["sha256"] != sha(origR2) {
		t.Fatalf("manifest artifact: %v", art)
	}
	w.verify(w.path("race"))
}

func TestUserConfigurationIsNotConsulted(t *testing.T) {
	w := newWorld(t)
	w.r2Raw("echo \"$HOME|$XDG_CONFIG_HOME|$TMPDIR|$TZ|$LC_ALL\" >&2; echo '[]'")
	w.env["HOME"] = w.path("evilhome")
	if rc := w.run("noconfig"); rc != 0 {
		t.Fatalf("rc=%d err=%q", rc, w.errBuf.String())
	}
	b, _ := os.ReadFile(w.path("noconfig/engine/stderr.txt"))
	if string(b) != "/tmp/rsdd/home|/tmp/rsdd/config|/tmp/rsdd|UTC|C.UTF-8\n" {
		t.Fatalf("the analyzer sees only the synthetic environment: %q", b)
	}
}

// The analyzed binary is data: an executable target that would write a marker when run never does, and the
// evidence is still complete. The marker path is absolute, so it would appear wherever the target ran.
func TestTargetIsNeverExecuted(t *testing.T) {
	w := newWorld(t)
	marker := w.path("target-was-executed")
	script := "#!/bin/sh\necho ran > '" + marker + "'\n"
	must(t, os.WriteFile(w.input, []byte(script), 0o755))
	if rc := w.run("noexec"); rc != 0 {
		t.Fatalf("rc=%d stderr=%q", rc, w.errBuf.String())
	}
	if w.exists("target-was-executed") {
		t.Fatal("the analyzed target was executed")
	}
	rep := w.readJSON("noexec/native-static.v1.json")
	if rep["status"] != "complete" {
		t.Fatalf("status %v errors %v", rep["status"], rep["errors"])
	}
	w.verify(w.path("noexec"))
}
