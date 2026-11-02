package firmware

import (
	"bytes"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/adapter"
)

const fixtureBytes = "\x89PNG\r\n\x1a\nfirmware"

func (w *world) input() string { return w.write("fixture.bin", []byte(fixtureBytes)) }

func TestCompleteRunPublishesTruthfulDeterministicEvidence(t *testing.T) {
	w := newWorld(t)
	dir := w.analyzer("v2fake", v2Banner)
	w.useExplicit(dir)
	in := w.input()
	w.mustRun(in, w.path("a"))
	w.mustRun(in, w.path("b"))

	a, _ := os.ReadFile(w.path("a/firmware-static.v1.json"))
	b, _ := os.ReadFile(w.path("b/firmware-static.v1.json"))
	if len(a) == 0 || !bytes.Equal(a, b) {
		t.Errorf("two runs over the same input differ:\n%s\n%s", a, b)
	}
	for _, f := range []string{"engine/signatures.json", "engine/entropy.json"} {
		fa, fb := mustRead(t, w.path("a/"+f)), mustRead(t, w.path("b/"+f))
		if len(fa) == 0 || !bytes.Equal(fa, fb) {
			t.Errorf("%s differs between two runs over the same input:\n%s\n%s", f, fa, fb)
		}
	}
	r := w.report("a")
	if at(t, r, "schema") != "firmware-static.v1" || at(t, r, "status") != "complete" || at(t, r, "engine", "version") != "2.3.3" {
		t.Fatalf("report = %v", r)
	}
	if at(t, r, "engine", "test_override") != false || at(t, r, "engine", "trust") != "user-owned-explicit" {
		t.Errorf("engine = %v", at(t, r, "engine"))
	}
	if got := strings.Join(strs(t, at(t, r, "engine", "argv")), " "); got != "engine/binwalk -B -E -N input/firmware.bin" {
		t.Errorf("argv = %q", got)
	}
	if at(t, r, "engine", "launcher", "source", "sha256") != at(t, r, "engine", "launcher", "staged", "sha256") {
		t.Error("the staged launcher differs from the source launcher")
	}
	if at(t, r, "input", "source", "sha256") != at(t, r, "input", "staged", "sha256") || at(t, r, "input", "staged", "path") != "input/firmware.bin" {
		t.Errorf("input = %v", at(t, r, "input"))
	}
	profile := at(t, r, "isolation", "profile")
	want := map[string]any{"name": "bubblewrap-static-network-denied", "network_access": false, "static_only": true, "target_execution": false}
	for k, v := range want {
		if at(t, profile, k) != v {
			t.Errorf("isolation.profile[%s] = %v, want %v", k, at(t, profile, k), v)
		}
	}
	limits := strs(t, at(t, r, "limitations"))
	if !contains(limits, "not root-owned") || contains(limits, "distro Binwalk package") || contains(limits, "test analyzer") {
		t.Errorf("limitations = %v", limits)
	}
	if at(t, r, "counts", "findings_emitted") != float64(1) || at(t, r, "truncated", "findings") != false || len(strs(t, at(t, r, "errors"))) != 0 {
		t.Errorf("counts/truncated/errors = %v / %v / %v", at(t, r, "counts"), at(t, r, "truncated"), at(t, r, "errors"))
	}
	wantTree := "engine/analysis-manifest.v1.json,engine/binwalk,engine/entropy.json,engine/signatures.json,engine/stderr.txt,engine/stdout.txt,firmware-static.v1.json,input/firmware.bin"
	if got := strings.Join(treeFiles(t, w.path("a")), ","); got != wantTree {
		t.Errorf("tree = %s", got)
	}
	for rel, mode := range map[string]os.FileMode{"input/firmware.bin": 0o400, "engine/binwalk": 0o500, "engine/analysis-manifest.v1.json": 0o600} {
		if fi, err := os.Stat(w.path("a/" + rel)); err != nil || fi.Mode().Perm() != mode {
			t.Errorf("%s mode = %v (%v), want %v", rel, fi.Mode().Perm(), err, mode)
		}
	}
	w.verifyManifest("a")
	if w.exists(".a.stage") || w.exists("a/engine/manifest-spec.json") {
		t.Error("a stage or the manifest spec outlived a successful run")
	}
}

func treeFiles(t *testing.T, dir string) []string {
	t.Helper()
	var out []string
	if err := filepath.WalkDir(dir, func(p string, d os.DirEntry, err error) error {
		if err == nil && d.Type().IsRegular() {
			rel, _ := filepath.Rel(dir, p)
			out = append(out, rel)
		}
		return err
	}); err != nil {
		t.Fatal(err)
	}
	return out
}

func TestTestOverrideIsReportedAsSuchAndNeedsNoTrust(t *testing.T) {
	w := newWorld(t)
	dir := w.analyzer("v2fake", v2Banner)
	w.useOverride(dir)
	w.mustRun(w.input(), w.path("out"))
	r := w.report("out")
	limits := strs(t, at(t, r, "limitations"))
	if at(t, r, "engine", "trust") != "test-override" || at(t, r, "engine", "test_override") != true {
		t.Errorf("engine = %v", at(t, r, "engine"))
	}
	if contains(limits, "not root-owned") || !contains(limits, "test analyzer") {
		t.Errorf("limitations = %v", limits)
	}
	if !strings.Contains(string(mustRead(t, w.path("out/engine/analysis-manifest.v1.json"))), `"name":"binwalk-test-override"`) {
		t.Error("the manifest must name the tool a test override")
	}
}

func mustRead(t *testing.T, p string) []byte {
	t.Helper()
	b, err := os.ReadFile(p)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func TestTestOverrideMayAnnounceAnyVersionButARealAnalyzerMustBeMajorTwo(t *testing.T) {
	w := newWorld(t)
	w.useOverride(w.analyzer("odd", "#!/bin/sh\n[ \"$1\" = --help ] && { echo 'Binwalk vfake'; exit; }\nprintf '0 0x0 x\\n'\n"))
	w.mustRun(w.input(), w.path("override"))
	if at(t, w.report("override"), "engine", "version") != "fake" {
		t.Error("a test analyzer's own version must be reported as announced")
	}

	w = newWorld(t)
	w.useExplicit(w.analyzer("v3fake", v3Banner))
	if code := w.run(w.input(), w.path("v3")); code != 2 || !strings.Contains(w.err.String(), "unsupported Binwalk version 3.1.0") || w.exists("v3") {
		t.Errorf("binwalk 3.x: exit %d stderr %q published %v", code, w.err.String(), w.exists("v3"))
	}
}

func TestFindingCapPublishesTruthfulPartialEvidence(t *testing.T) {
	w := newWorld(t)
	w.useOverride(w.analyzer("capped", fakeBinwalk(`printf '2 0x2 third\n0 0x0 first\n1 0x1 second\n'`)))
	if code := w.run(w.input(), w.path("partial"), "--max-findings", "2"); code != 1 {
		t.Fatalf("exit %d, want 1 (stderr %q)", code, w.err.String())
	}
	r := w.report("partial")
	counts := at(t, r, "counts").(map[string]any)
	if at(t, r, "status") != "partial" || counts["findings_emitted"] != float64(2) || counts["findings_total"] != float64(3) ||
		counts["signatures_total"] != float64(3) || counts["entropy_total"] != float64(0) || at(t, r, "truncated", "findings") != true {
		t.Errorf("status/counts = %v / %v", at(t, r, "status"), counts)
	}
	sigs := at(t, r, "signatures").([]any)
	if len(sigs) != 2 || at(t, sigs[0], "description") != "first" || at(t, sigs[1], "description") != "second" {
		t.Errorf("the cap must keep the lowest offsets, got %v", sigs)
	}
	want := "firmware-static.v1: completed with issues (status=partial) — see " + w.path("partial") + "/firmware-static.v1.json\n"
	if w.err.String() != want {
		t.Errorf("stderr = %q, want %q", w.err.String(), want)
	}
	w.verifyManifest("partial")
}

func TestSignaturesAndEntropyAreSplitSortedAndCappedInThatOrder(t *testing.T) {
	w := newWorld(t)
	w.useOverride(w.analyzer("mixed", fakeBinwalk(`printf '10 0xa Falling entropy edge (0.1)\n5 0x5 zeta\n5 0x5 alpha\n0 0x0 Rising entropy edge (0.9)\n9 0x9 \033[31mred\033[0m   text\n'`)))
	w.mustRun(w.input(), w.path("out"))
	r := w.report("out")
	var sigs, ents []string
	for _, s := range at(t, r, "signatures").([]any) {
		sigs = append(sigs, at(t, s, "description").(string)+"@"+at(t, s, "hex").(string))
	}
	for _, s := range at(t, r, "entropy").([]any) {
		ents = append(ents, at(t, s, "description").(string))
	}
	if strings.Join(sigs, "|") != "alpha@0x5|zeta@0x5|red text@0x9" {
		t.Errorf("signatures = %v", sigs)
	}
	if strings.Join(ents, "|") != "Rising entropy edge (0.9)|Falling entropy edge (0.1)" {
		t.Errorf("entropy = %v", ents)
	}
}

func TestProcessCapKillsAndCleansTheProcessTree(t *testing.T) {
	w := newWorld(t)
	leak := w.path("LEAKED_CHILD")
	w.useOverride(w.analyzer("child", fakeBinwalk("(sleep 2; touch '"+leak+"') &\nsleep 5")))
	if code := w.run(w.input(), w.path("failed-child"), "--max-processes", "1"); code != 1 {
		t.Fatalf("exit %d, want 1 (stderr %q)", code, w.err.String())
	}
	time.Sleep(2500 * time.Millisecond)
	if w.exists("LEAKED_CHILD") {
		t.Error("a child of the analyzer outlived the process cap")
	}
	r := w.report("failed-child")
	if at(t, r, "status") != "failed" || !contains(strs(t, at(t, r, "errors")), "process-cap") {
		t.Errorf("status/errors = %v / %v", at(t, r, "status"), at(t, r, "errors"))
	}
	w.verifyManifest("failed-child")
}

func TestDiagnosticCapTruncatesNoisyOutput(t *testing.T) {
	w := newWorld(t)
	w.useOverride(w.analyzer("noisy", fakeBinwalk("dd if=/dev/zero bs=1M count=1 2>/dev/null")))
	if code := w.run(w.input(), w.path("noisy-out"), "--max-diagnostic-bytes", "4096"); code != 1 {
		t.Fatalf("exit %d, want 1 (stderr %q)", code, w.err.String())
	}
	if fi, err := os.Stat(w.path("noisy-out/engine/stdout.txt")); err != nil || fi.Size() > 4096 {
		t.Errorf("stdout.txt = %v (%v), want at most 4096 bytes", fi, err)
	}
	if !contains(strs(t, at(t, w.report("noisy-out"), "errors")), "diagnostic-cap") {
		t.Error("the report must say the diagnostic cap fired")
	}
}

func TestAnalyzerFailureIsPublishedWithItsExitCodeAndAPointer(t *testing.T) {
	w := newWorld(t)
	w.useOverride(w.analyzer("fail9", fakeBinwalk("exit 9")))
	if code := w.run(w.input(), w.path("warn-fw-ptr")); code != 1 {
		t.Fatalf("exit %d, want 1", code)
	}
	r := w.report("warn-fw-ptr")
	if at(t, r, "status") != "failed" || strings.Join(strs(t, at(t, r, "errors")), ",") != "analyzer-exit:9" || at(t, r, "engine", "run", "exit_code") != float64(9) {
		t.Errorf("report = status %v errors %v run %v", at(t, r, "status"), at(t, r, "errors"), at(t, r, "engine", "run"))
	}
	if !strings.Contains(w.err.String(), "firmware-static.v1.json") || !strings.Contains(w.err.String(), "status=failed") {
		t.Errorf("stderr = %q", w.err.String())
	}
}

func TestAnalyzerKilledBySignalIsRecordedAsASignal(t *testing.T) {
	w := newWorld(t)
	w.useOverride(w.analyzer("killed", fakeBinwalk("kill -9 $$")))
	if code := w.run(w.input(), w.path("sig")); code != 1 {
		t.Fatalf("exit %d, want 1", code)
	}
	r := w.report("sig")
	if at(t, r, "engine", "run", "exit_code") != nil || at(t, r, "engine", "run", "signal") != float64(9) || !contains(strs(t, at(t, r, "errors")), "analyzer-exit:-9") {
		t.Errorf("run/errors = %v / %v", at(t, r, "engine", "run"), at(t, r, "errors"))
	}
}

func TestTimeoutStopsTheAnalyzer(t *testing.T) {
	w := newWorld(t)
	w.useOverride(w.analyzer("slow", fakeBinwalk("sleep 10")))
	start := time.Now()
	if code := w.run(w.input(), w.path("timeout"), "--timeout-seconds", "1"); code != 1 {
		t.Fatalf("exit %d, want 1", code)
	}
	if !contains(strs(t, at(t, w.report("timeout"), "errors")), "timeout") || time.Since(start) > 8*time.Second {
		t.Errorf("errors = %v after %v", at(t, w.report("timeout"), "errors"), time.Since(start))
	}
}

func TestPreflightSafetyFailsClosed(t *testing.T) {
	w := newWorld(t)
	dir := w.analyzer("v2fake", v2Banner)
	w.useOverride(dir)
	in := w.input()
	if err := os.Symlink(in, w.path("link.bin")); err != nil {
		t.Fatal(err)
	}
	w.mustRun(in, w.path("done"))
	w.write("oversized.bin", []byte("12345"))
	if err := os.Truncate(w.write("sparse.bin", nil), 1<<20); err != nil {
		t.Fatal(err)
	}
	w.mkdir(".occupied.stage")
	w.write(".occupied.stage/sentinel", []byte("keep"))
	w.mkdir("pathbad")
	if err := os.Symlink("/usr/bin/true", w.path("pathbad/binwalk")); err != nil {
		t.Fatal(err)
	}

	cases := []struct {
		name, input, out, want string
		env                    map[string]string
		extra                  []string
	}{
		{"symlinked input", w.path("link.bin"), "link-out", "cannot open regular non-symlink file", nil, nil},
		{"existing output", in, "done", "output must be a new non-colliding path", nil, nil},
		{"output is the input", in, "fixture.bin", "output must be a new non-colliding path", nil, nil},
		{"PATH disagrees with the analyzer", in, "path-mismatch", "configured binwalk does not match PATH-selected executable",
			map[string]string{"PATH": w.path("pathbad") + ":/usr/bin:/bin"}, nil},
		{"dense input over the cap", w.path("oversized.bin"), "oversized-out", "input exceeds max-input-bytes", nil, []string{"--max-input-bytes", "4"}},
		{"sparse input over the cap", w.path("sparse.bin"), "sparse-out", "input exceeds max-input-bytes", nil, []string{"--max-input-bytes", "4"}},
		{"foreign stage", in, "occupied", "File exists", nil, nil},
		{"missing output parent", in, "nope/out", "No such file or directory", nil, nil},
		{"max-files below the evidence tree", in, "few", "caps must be positive and max-files at least 7", nil, []string{"--max-files", "6"}},
		{"zero timeout", in, "zero", "caps must be positive and max-files at least 7", nil, []string{"--timeout-seconds", "0"}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			saved := map[string]string{}
			for k, v := range tc.env {
				saved[k], w.env[k] = w.env[k], v
			}
			defer func() {
				for k, v := range saved {
					w.env[k] = v
				}
			}()
			if code := w.run(tc.input, w.path(tc.out), tc.extra...); code != 2 {
				t.Fatalf("exit %d, want 2 (stderr %q)", code, w.err.String())
			}
			if !strings.Contains(w.err.String(), tc.want) {
				t.Errorf("stderr %q lacks %q", w.err.String(), tc.want)
			}
			if tc.out != "done" && tc.out != "fixture.bin" && tc.out != "occupied" && w.exists(tc.out) {
				t.Error("a refused run published an output")
			}
		})
	}
	if b, err := os.ReadFile(w.path(".occupied.stage/sentinel")); err != nil || string(b) != "keep" {
		t.Error("the foreign stage directory was not preserved")
	}
	for _, stage := range []string{".link-out.stage", ".oversized-out.stage", ".path-mismatch.stage"} {
		if w.exists(stage) {
			t.Errorf("%s left behind", stage)
		}
	}
}

func TestSourceMutationAfterStagingCannotChangeTheAnalyzedBytes(t *testing.T) {
	w := newWorld(t)
	w.useOverride(w.analyzer("slow_stage", fakeBinwalk("sleep 1; echo '0 0x0 staged source'")))
	in := w.input()
	done := make(chan int, 1)
	go func() { done <- w.run(in, w.path("source-swap")) }()
	staged := w.path(".source-swap.stage/input/firmware.bin")
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if fi, err := os.Stat(staged); err == nil && fi.Mode().Perm() == 0o400 {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	f, err := os.OpenFile(in, os.O_APPEND|os.O_WRONLY, 0)
	if err != nil {
		t.Fatal(err)
	}
	_, _ = f.WriteString("mutation")
	f.Close()
	if code := <-done; code != 0 {
		t.Fatalf("exit %d, stderr %q", code, w.err.String())
	}
	r := w.report("source-swap")
	if at(t, r, "input", "staged", "size") != float64(len(fixtureBytes)) || at(t, r, "input", "source", "sha256") != at(t, r, "input", "staged", "sha256") {
		t.Errorf("input = %v", at(t, r, "input"))
	}
}

func TestAnalyzerSelectionAndTrust(t *testing.T) {
	cases := []struct {
		name   string
		setup  func(w *world)
		want   []string // substrings of stderr, all required
		status int
	}{
		{"user-owned PATH analyzer without RSDD_BINWALK", func(w *world) {
			w.env["PATH"] = w.analyzer("v2fake", v2Banner) + ":/usr/bin:/bin"
		}, []string{"root-owned", "RSDD_BINWALK"}, 2},
		{"relative RSDD_BINWALK", func(w *world) {
			w.analyzer("v2fake", v2Banner)
			w.env["RSDD_BINWALK"] = "v2fake/binwalk"
		}, []string{"RSDD_BINWALK must be an absolute path"}, 2},
		{"group-writable analyzer", func(w *world) {
			dir := w.analyzer("v2fake", v2Banner)
			w.useExplicit(dir)
			_ = os.Chmod(filepath.Join(dir, "binwalk"), 0o775)
		}, []string{"Binwalk must be root-owned and non-writable"}, 2},
		{"world-writable analyzer directory", func(w *world) {
			dir := w.analyzer("v2fake", v2Banner)
			w.useExplicit(dir)
			_ = os.Chmod(dir, 0o777)
		}, []string{"directory must be"}, 2},
		{"no binwalk on PATH", func(w *world) { w.env["PATH"] = "/nonexistent" }, []string{"PATH-selected binwalk is missing"}, 2},
		{"relative PATH entries are not searched", func(w *world) {
			w.analyzer("v2fake", v2Banner)
			w.env["PATH"] = "v2fake:/nonexistent"
		}, []string{"PATH-selected binwalk is missing"}, 2},
		{"empty PATH entry is not searched", func(w *world) {
			w.analyzer("v2fake", v2Banner)
			w.env["PATH"] = ":/nonexistent"
		}, []string{"PATH-selected binwalk is missing"}, 2},
		{"RSDD_BINWALK names a missing file", func(w *world) {
			w.env["RSDD_BINWALK"] = w.path("missing/binwalk")
		}, []string{"No such file or directory"}, 2},
		{"RSDD_BINWALK names a directory", func(w *world) {
			w.mkdir("adir")
			w.env["RSDD_BINWALK"] = w.path("adir")
		}, []string{"is not an executable file"}, 2},
		{"RSDD_BINWALK_TEST_ONLY not first on PATH", func(w *world) {
			dir := w.analyzer("v2fake", v2Banner)
			w.env["RSDD_BINWALK_TEST_ONLY"] = filepath.Join(dir, "binwalk")
			w.env["PATH"] = "/nonexistent"
		}, []string{"PATH-selected binwalk is missing"}, 2},
		{"binwalk reports no version", func(w *world) {
			w.useOverride(w.analyzer("mute", "#!/bin/sh\nexit 0\n"))
		}, []string{"Binwalk version is unavailable"}, 2},
		{"binwalk fails its version probe", func(w *world) {
			w.useOverride(w.analyzer("broken", "#!/bin/sh\nexit 3\n"))
		}, []string{"bounded Binwalk version probe failed: analyzer-exit:3"}, 2},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			w := newWorld(t)
			tc.setup(w)
			if code := w.run(w.input(), w.path("out")); code != tc.status {
				t.Fatalf("exit %d, want %d (stderr %q)", code, tc.status, w.err.String())
			}
			for _, want := range tc.want {
				if !strings.Contains(w.err.String(), want) {
					t.Errorf("stderr %q lacks %q", w.err.String(), want)
				}
			}
			if w.exists("out") || w.exists(".out.stage") {
				t.Error("a refused run left an output or a stage")
			}
		})
	}
}

func TestExplicitAnalyzerIsUsedWhetherOrNotItIsFirstOnPATH(t *testing.T) {
	w := newWorld(t)
	v2 := w.analyzer("v2fake", v2Banner)
	v3 := w.analyzer("v3fake", v3Banner)
	w.env["RSDD_BINWALK"] = filepath.Join(v2, "binwalk")
	for name, path := range map[string]string{"first-not": v3 + ":" + v2 + ":/usr/bin:/bin", "absent": "/usr/bin:/bin"} {
		w.env["PATH"] = path
		w.mustRun(w.input(), w.path(name))
		if at(t, w.report(name), "status") != "complete" || at(t, w.report(name), "engine", "version") != "2.3.3" {
			t.Errorf("%s: report = %v", name, w.report(name))
		}
	}
}

func TestSandboxPreconditions(t *testing.T) {
	cases := []struct {
		name  string
		setup func(w *world)
		want  string
	}{
		{"isolation probe fails", func(w *world) { w.write("bin/probe-fails", nil) }, "network-denied zero-capability isolation probe failed"},
		{"launcher owned by an untrusted user", func(w *world) { w.d.bwrapUIDs = map[uint64]bool{0: true} }, "Bubblewrap must be root-owned and non-writable"},
		{"launcher group-writable", func(w *world) { _ = os.Chmod(w.path("bin/bwrap"), 0o775) }, "Bubblewrap must be root-owned and non-writable"},
		{"launcher is not the PATH-selected one", func(w *world) {
			w.exe("elsewhere-bwrap", fakeBwrap)
			w.env["RSDD_BWRAP"] = w.path("elsewhere-bwrap")
		}, "configured bwrap does not match PATH-selected executable"},
		{"mount point is a symlink", func(w *world) {
			if err := os.Symlink(w.root, w.d.hostRoot); err != nil {
				t.Fatal(err)
			}
		}, "unsafe Bubblewrap mountpoint"},
		{"mount point is open to others", func(w *world) {
			w.mkdir("host-rsdd")
			_ = os.Chmod(w.d.hostRoot, 0o755)
		}, "unsafe Bubblewrap mountpoint"},
		{"output on a foreign filesystem", func(w *world) {
			w.d.mountinfo = func() (string, error) { return "1 0 0:1 / / rw - drvfs C:\\ rw\n", nil }
		}, "output must reside on a Linux-private filesystem"},
		{"running as root", func(w *world) {
			w.d.creds = func() adapter.Creds { return adapter.Creds{} }
		}, "root or set-id"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			w := newWorld(t)
			w.useOverride(w.analyzer("v2fake", v2Banner))
			tc.setup(w)
			if code := w.run(w.input(), w.path("out")); code != 2 || !strings.Contains(w.err.String(), tc.want) {
				t.Fatalf("exit %d, stderr %q; want 2 and %q", code, w.err.String(), tc.want)
			}
			if w.exists("out") || w.exists(".out.stage") {
				t.Error("a refused run left an output or a stage")
			}
		})
	}
}

func TestSandboxCommandIsTheDocumentedOne(t *testing.T) {
	w := newWorld(t)
	w.useOverride(w.analyzer("v2fake", v2Banner))
	w.mustRun(w.input(), w.path("out"))
	manifest := string(mustRead(t, w.path("out/engine/analysis-manifest.v1.json")))
	line := w.path("bin/bwrap") + `","--die-with-parent","--new-session","--unshare-net","--unshare-pid","--cap-drop","ALL","--ro-bind","/","/",` +
		`"--proc","/proc","--dev","/dev","--tmpfs","/tmp/rsdd","--dir","/tmp/rsdd/home","--dir","/tmp/rsdd/cache","--dir","/tmp/rsdd/config",` +
		`"--dir","/tmp/rsdd/data","--dir","/tmp/rsdd/work","--ro-bind",".","/tmp/rsdd/work","--setenv","HOME","/tmp/rsdd/home",` +
		`"--setenv","XDG_CACHE_HOME","/tmp/rsdd/cache","--setenv","XDG_CONFIG_HOME","/tmp/rsdd/config","--setenv","XDG_DATA_HOME","/tmp/rsdd/data",` +
		`"--setenv","TMPDIR","/tmp/rsdd","--setenv","PATH","/usr/bin:/bin","--setenv","LANG","C.UTF-8","--setenv","LC_ALL","C.UTF-8",` +
		`"--setenv","TZ","UTC","--chdir","/tmp/rsdd/work","--","engine/binwalk","-B","-E","-N","input/firmware.bin"]`
	if !strings.Contains(manifest, line) {
		t.Errorf("manifest argv is not the documented sandbox command:\n%s", manifest)
	}
	if want := `"argv_index":` + strconv.Itoa(59); !strings.Contains(manifest, want) { // the 59 elements of the sandbox prefix
		t.Errorf("the manifest must bind the staged analyzer to its argv position (%s)", want)
	}
	if fi, err := os.Lstat(w.d.hostRoot); err != nil || fi.Mode().Perm() != 0o700 {
		t.Errorf("host mount point = %v (%v), want a private directory", fi, err)
	}
}

func TestUsage(t *testing.T) {
	w := newWorld(t)
	for _, tc := range []struct {
		args      []string
		code      int
		out, errw string
	}{
		{[]string{"-h"}, 0, "usage: rsdd corroborate firmware", ""},
		{[]string{"--output", "x"}, 2, "", "the following arguments are required: --input"},
		{nil, 2, "", "the following arguments are required: --input, --output"},
		{[]string{"--input", "a", "--output", "b", "stray"}, 2, "", "unrecognized arguments: stray"},
		{[]string{"--input", "a", "--output", "b", "--max-findings", "many"}, 2, "", "invalid value"},
	} {
		w.out.Reset()
		w.err.Reset()
		code := execute(tc.args, w.stdio(), w.d)
		if code != tc.code || !strings.Contains(w.out.String(), tc.out) || !strings.Contains(w.err.String(), tc.errw) {
			t.Errorf("%v: exit %d, stdout %q, stderr %q", tc.args, code, w.out.String(), w.err.String())
		}
	}
	// --manifest-cli is accepted for callers of the old script and ignored.
	w.useOverride(w.analyzer("v2fake", v2Banner))
	w.mustRun(w.input(), w.path("compat"), "--manifest-cli", "/nonexistent/analysis_manifest.py")
}
