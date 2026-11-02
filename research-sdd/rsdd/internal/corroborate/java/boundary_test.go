package java

import (
	"bytes"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

// Boundary pins: each test sits on the exact value where a comparison, a sign or a negation changes the outcome,
// so a mutated operator is caught without Python or Bubblewrap on PATH (kit issue #2534).

func TestTimeoutSaturatesAtTheInt32Maximum(t *testing.T) {
	h := newHarness(t)
	e := newEnv(h.stdio(io.Discard, io.Discard))
	for in, want := range map[string]int{"2147483647": 1<<31 - 1, "2147483648": 1<<31 - 1, "9999999999999": 1<<31 - 1, "2147483646": 1<<31 - 2} {
		o, rc := e.parse([]string{"--decompile-wrapper", "w", "--manifest-module", "m", "--input", "i", "--output", "o", "--timeout-seconds", in})
		if rc != -1 || o.timeoutSeconds != want {
			t.Errorf("--timeout-seconds %s: rc=%d timeoutSeconds=%d, want %d", in, rc, o.timeoutSeconds, want)
		}
	}
}

func TestIsoZDropsAFractionBelowOneMicrosecond(t *testing.T) {
	base := time.Date(2026, 1, 2, 3, 4, 5, 0, time.UTC)
	for _, c := range []struct {
		ns   int
		want string
	}{{0, "2026-01-02T03:04:05Z"}, {999, "2026-01-02T03:04:05Z"}, {1000, "2026-01-02T03:04:05.000001Z"}, {1500, "2026-01-02T03:04:05.000001Z"}} {
		if got := isoZ(base.Add(time.Duration(c.ns))); got != c.want {
			t.Errorf("%dns: %q, want %q", c.ns, got, c.want)
		}
	}
}

func TestIsolationPrefixBindsTheWritableDirectoryOnlyWhenOneIsGiven(t *testing.T) {
	has := func(argv []string, a, b string) bool {
		for i := 0; i+1 < len(argv); i++ {
			if argv[i] == a && argv[i+1] == b {
				return true
			}
		}
		return false
	}
	without := isolationPrefix("/bw", "", nil)
	if has(without, "--bind", "engines/x/output") || without[len(without)-1] != "--" {
		t.Errorf("no writable directory means no --bind: %v", without)
	}
	for i, a := range without {
		if a == "--bind" {
			t.Errorf("unexpected --bind at %d: %v", i, without)
		}
	}
	with := isolationPrefix("/bw", "engines/x/output", nil)
	if !has(with, "--bind", "engines/x/output") || !has(with, "engines/x/output", sandboxRoot+"/engines/x/output") {
		t.Errorf("the writable directory is bound below the sandbox root: %v", with)
	}
}

func TestSplitLinesCarriageReturnEdges(t *testing.T) {
	for in, want := range map[string][]string{
		"a\r":     {"a"},         // a lone CR at the very end has nothing to pair with
		"\rx":     {"", "x"},     // a CR at the start has no predecessor to pair with
		"\n\rx":   {"", "", "x"}, // a CR after a LF is its own break
		"a\r\nb":  {"a", "b"},
		"a\r\r\n": {"a", ""},
	} {
		if got := splitLines(in); !reflect.DeepEqual(got, want) {
			t.Errorf("splitLines(%q) = %q, want %q", in, got, want)
		}
	}
}

// ---- inventory caps accept the value they name ---------------------------------------------------------------------

func TestInventoryCapsAcceptTheirOwnValue(t *testing.T) {
	h := newHarness(t)
	// A compressible entry keeps the archive far below the expanded size, so each cap can sit exactly on its value.
	writeJar(t, h.input, entry{name: "a.class", data: bytes.Repeat([]byte{0}, 20000)}, entry{name: "b.class", data: bytes.Repeat([]byte{0}, 20000)})
	fi, err := os.Stat(h.input)
	if err != nil {
		t.Fatal(err)
	}
	if fi.Size() >= 40000 {
		t.Fatalf("fixture must compress, size %d", fi.Size())
	}
	if _, err := jarInventory(h.input, 2, 1<<20, 10); err != nil {
		t.Errorf("an entry count equal to --max-files is within the cap: %v", err)
	}
	if _, err := jarInventory(h.input, 10, fi.Size()-1, 10); err == nil || err.Error() != "input exceeds --max-bytes" {
		t.Errorf("an input one byte over --max-bytes refuses: %v", err)
	}
	// Archive framing makes a stored archive larger than what it expands to, so its size can sit on the cap alone.
	small := filepath.Join(h.root, "small.jar")
	writeJar(t, small, entry{name: "a.class", data: []byte("x"), stored: true})
	sfi, err := os.Stat(small)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := jarInventory(small, 10, sfi.Size(), 10); err != nil {
		t.Errorf("an input size equal to --max-bytes is within the cap: %v", err)
	}
	if _, err := jarInventory(h.input, 10, 40000, 10); err != nil {
		t.Errorf("expanded bytes equal to --max-bytes are within the cap: %v", err)
	}
	if _, err := jarInventory(h.input, 10, 39999, 10); err == nil || err.Error() != "JAR expanded bytes exceed --max-bytes" {
		t.Errorf("one byte less must refuse: %v", err)
	}
	inv, err := jarInventory(h.input, 10, 1<<20, 2)
	if err != nil || inv.classesTruncated || len(inv.expectedClasses) != 2 || inv.expectedTotal != 2 {
		t.Errorf("a class count equal to --max-classes is not truncated: %+v %v", inv, err)
	}
	inv, err = jarInventory(h.input, 10, 1<<20, 1)
	if err != nil || !inv.classesTruncated || len(inv.expectedClasses) != 1 || inv.expectedTotal != 2 {
		t.Errorf("one class over --max-classes is truncated: %+v %v", inv, err)
	}
}

// ---- fileIdentity ---------------------------------------------------------------------------------------------------

func TestFileIdentityRootRule(t *testing.T) {
	dir, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	inside := filepath.Join(dir, "root", "f")
	outside := filepath.Join(dir, "elsewhere", "f")
	writeFile(t, inside, []byte("x"))
	writeFile(t, outside, []byte("y"))
	root := filepath.Join(dir, "root")
	if _, _, _, err := fileIdentity(inside, root); err != nil {
		t.Errorf("a file below the root is accepted: %v", err)
	}
	if _, _, _, err := fileIdentity(inside, inside); err != nil {
		t.Errorf("the root itself is accepted: %v", err)
	}
	if _, _, _, err := fileIdentity(inside, ""); err != nil {
		t.Errorf("an empty root means no containment rule: %v", err)
	}
	if _, _, _, err := fileIdentity(outside, ""); err != nil {
		t.Errorf("an empty root accepts any file: %v", err)
	}
	if _, _, _, err := fileIdentity(outside, root); err == nil || err.Error() != "opened file escapes analysis root" {
		t.Errorf("a file outside the root escapes it: %v", err)
	}
	if _, _, _, err := fileIdentity(filepath.Join(dir, "root-sibling-of-prefix"), root); err == nil {
		t.Error("a missing file is an error")
	}
	sibling := filepath.Join(dir, "rootx", "f")
	writeFile(t, sibling, []byte("z"))
	if _, _, _, err := fileIdentity(sibling, root); err == nil {
		t.Errorf("a sibling that merely shares the root's name prefix escapes it")
	}
}

// ---- resolveLoose ---------------------------------------------------------------------------------------------------

func TestResolveLooseFollowsExistingSymlinksAndKeepsTheMissingTail(t *testing.T) {
	dir, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	real := filepath.Join(dir, "real")
	if err := os.Mkdir(real, 0o755); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(dir, "link")
	if err := os.Symlink(real, link); err != nil {
		t.Fatal(err)
	}
	if got := resolveLoose(link); got != real {
		t.Errorf("an existing symlink resolves to its target: %q, want %q", got, real)
	}
	if got, want := resolveLoose(filepath.Join(link, "a", "b")), filepath.Join(real, "a", "b"); got != want {
		t.Errorf("the missing tail is kept below the resolved prefix: %q, want %q", got, want)
	}
}

// ---- output.go boundaries -------------------------------------------------------------------------------------------

func TestScanFilesCountsUpToAndIncludingTheByteCap(t *testing.T) {
	root := t.TempDir()
	writeFile(t, filepath.Join(root, "a"), []byte("1234567890"))
	writeFile(t, filepath.Join(root, "b"), []byte("1"))
	// A total equal to the cap is not past it, so the scan goes on to the next file.
	if files, total, err := scanFiles(root, 10, 10); err != nil || files != 2 || total != 11 {
		t.Errorf("files=%d total=%d err=%v, want 2 11", files, total, err)
	}
	if files, total, err := scanFiles(root, 2, 1000); err != nil || files != 2 || total != 11 {
		t.Errorf("a file count equal to the cap is not past it: files=%d total=%d err=%v", files, total, err)
	}
}

func TestNormalizeDiagnosticsKeepsAPayloadExactlyAtTheBudget(t *testing.T) {
	engine := t.TempDir()
	writeFile(t, filepath.Join(engine, "stdout.raw.txt"), []byte("12345"))
	remaining, truncated, err := normalizeDiagnostics(engine, "/s", 5)
	if err != nil || truncated || remaining != 0 {
		t.Fatalf("remaining=%d truncated=%v err=%v: a payload equal to the budget is not cut", remaining, truncated, err)
	}
	if got, _ := os.ReadFile(filepath.Join(engine, "stdout.txt")); string(got) != "12345" {
		t.Errorf("stdout.txt = %q", got)
	}
}

func TestNormalizeDiagnosticsWithAnEmptyStageReplacesNothing(t *testing.T) {
	engine := t.TempDir()
	writeFile(t, filepath.Join(engine, "stdout.raw.txt"), []byte("abc"))
	if _, _, err := normalizeDiagnostics(engine, "", 100); err != nil {
		t.Fatal(err)
	}
	if got, _ := os.ReadFile(filepath.Join(engine, "stdout.txt")); string(got) != "abc" {
		t.Errorf("an empty variant must not be replaced between every byte: %q", got)
	}
}

func TestInventoryKeepsAFileExactlyAtTheByteBudget(t *testing.T) {
	stage := t.TempDir()
	output := filepath.Join(stage, "output")
	writeFile(t, filepath.Join(output, "a.java"), []byte("12345"))
	e := &env{}
	records, truncated, err := e.outputInventory(stage, output, 10, 5)
	if err != nil || truncated || len(records) != 1 || records[0].size != 5 {
		t.Fatalf("records=%+v truncated=%v err=%v: a file equal to the budget is whole", records, truncated, err)
	}
	if _, _, err := e.outputInventory(stage, output, 10, 4); err != nil {
		t.Fatal(err)
	}
	if fi, _ := os.Stat(filepath.Join(output, "a.java")); fi.Size() != 4 {
		t.Errorf("one byte over the budget is cut to it, size %d", fi.Size())
	}
}

func TestInventoryPrunesNestedEmptyDirectoriesDeepestFirst(t *testing.T) {
	stage := t.TempDir()
	output := filepath.Join(stage, "output")
	for _, d := range []string{"a/b/c", "a/b/d", "a/e", "f/g", "z"} {
		if err := os.MkdirAll(filepath.Join(output, d), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	writeFile(t, filepath.Join(output, "a", "keep.java"), []byte("k"))
	e := &env{}
	if _, _, err := e.outputInventory(stage, output, 10, 100); err != nil {
		t.Fatal(err)
	}
	var left []string
	_ = filepath.WalkDir(output, func(p string, _ os.DirEntry, _ error) error {
		if p != output {
			left = append(left, strings.TrimPrefix(p, output+"/"))
		}
		return nil
	})
	if want := []string{"a", "a/keep.java"}; !reflect.DeepEqual(left, want) {
		t.Errorf("left = %q, want %q: every empty directory goes, the one holding a file stays", left, want)
	}
}

// ---- engine-level outcomes ------------------------------------------------------------------------------------------

// An engine whose analyzer JAR is unavailable keeps that status even when its diagnostics are cut: only a run that
// ended in success or failure becomes cap_exceeded.
func TestUnavailableEngineStaysUnavailableWhenItsDiagnosticsAreCut(t *testing.T) {
	h := newHarness(t)
	e := newEnv(h.stdio(io.Discard, io.Discard))
	stage := filepath.Join(h.root, "stage")
	rec, inv, err := e.runEngine("vineflower", engineInput{
		o: options{maxBytes: 10, maxFiles: 10, maxHeap: "128m"}, stage: stage, isJarTool: true, trusted: nil,
		jar: &inventory{},
	})
	if err != nil {
		t.Fatal(err)
	}
	if rec["status"] != "unavailable" || rec["exit_code"] != 127 || rec["signal"] != nil || len(inv) != 0 {
		t.Errorf("record = %v", rec)
	}
	if get(rec, "truncated", "diagnostics") != true || get(rec, "truncated", "outputs") != false {
		t.Errorf("truncated = %v, want diagnostics cut", rec["truncated"])
	}
	if rec["manifest"] != nil || rec["manifest_identity"] != nil {
		t.Errorf("an unavailable engine has no manifest: %v", rec)
	}
}

// decode reads a published manifest.
func decode(t *testing.T, path string) map[string]any {
	t.Helper()
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var doc map[string]any
	if err := json.Unmarshal(raw, &doc); err != nil {
		t.Fatal(err)
	}
	return doc
}

func TestEngineRecordsAndManifestsCarryExitCodeSignalAndCompleteness(t *testing.T) {
	h := newHarness(t)
	h.mode("cfr", "fail")
	h.mode("vineflower", "slow")
	r := h.run(h.args("--timeout-seconds", "1", "--output", h.out("outcomes"))...)
	if r.rc != 1 {
		t.Fatalf("rc = %d; stderr %q", r.rc, r.err)
	}
	root := h.out("outcomes")
	rep := h.report(root)
	manifestOf := func(name string) map[string]any {
		return decode(t, filepath.Join(root, "engines", name, "analysis-manifest.v1.json"))
	}

	// A clean run: exit code 0 is an exit code, not a signal; the manifest is complete and error-free.
	for _, name := range []string{"procyon", "javap", "jdeps"} {
		if get(rep, "engines", name, "exit_code") != float64(0) || get(rep, "engines", name, "signal") != nil {
			t.Errorf("%s: exit_code=%v signal=%v", name, get(rep, "engines", name, "exit_code"), get(rep, "engines", name, "signal"))
		}
		if want := "engines/" + name + "/analysis-manifest.v1.json"; get(rep, "engines", name, "manifest") != want {
			t.Errorf("%s: manifest = %v, want %s", name, get(rep, "engines", name, "manifest"), want)
		}
		if id, _ := get(rep, "engines", name, "manifest_identity").(string); !strings.HasPrefix(id, "sha256:") {
			t.Errorf("%s: manifest_identity = %v", name, get(rep, "engines", name, "manifest_identity"))
		}
		m := manifestOf(name)
		if errs, _ := m["errors"].([]any); len(errs) != 0 || m["completeness"] != "complete" {
			t.Errorf("%s: errors=%v completeness=%v", name, m["errors"], m["completeness"])
		}
		if get(m, "run", "exit_code") != float64(0) || get(m, "run", "signal") != nil {
			t.Errorf("%s: run = %v", name, m["run"])
		}
	}

	// A failed engine: its manifest is partial and names the status; the exit code is kept, no signal.
	m := manifestOf("cfr")
	if errs, _ := m["errors"].([]any); len(errs) != 1 || errs[0] != "adapter status: failed" || m["completeness"] != "partial" {
		t.Errorf("cfr: errors=%v completeness=%v", m["errors"], m["completeness"])
	}
	if get(m, "run", "exit_code") != float64(7) || get(m, "run", "signal") != nil {
		t.Errorf("cfr: run = %v", m["run"])
	}

	// A stopped engine: a positive signal number, no exit code, in the record and in its manifest.
	sig, _ := get(rep, "engines", "vineflower", "signal").(float64)
	if sig <= 0 || get(rep, "engines", "vineflower", "exit_code") != nil {
		t.Errorf("vineflower: signal=%v exit_code=%v", get(rep, "engines", "vineflower", "signal"), get(rep, "engines", "vineflower", "exit_code"))
	}
	m = manifestOf("vineflower")
	msig, _ := get(m, "run", "signal").(float64)
	if msig != sig || get(m, "run", "exit_code") != nil || m["completeness"] != "partial" {
		t.Errorf("vineflower manifest: run=%v completeness=%v", m["run"], m["completeness"])
	}
}
