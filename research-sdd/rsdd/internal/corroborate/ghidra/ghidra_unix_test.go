//go:build unix

package ghidra

import (
	"os"
	"strings"
	"testing"
)

func TestCompleteRunPublishesVerifiedEvidence(t *testing.T) {
	w := newWorld(t)
	if rc := w.run("out"); rc != 0 {
		t.Fatalf("rc=%d stderr=%q", rc, w.errBuf.String())
	}
	if w.out.Len() != 0 || w.errBuf.Len() != 0 {
		t.Fatalf("a complete run is silent: out=%q err=%q", w.out.String(), w.errBuf.String())
	}
	r := w.readJSON("out/report.json")
	if r["schema"] != schema || r["status"] != "complete" {
		t.Fatalf("report: %v", r)
	}
	if sub(r, "ghidra", "version") != "12.1-test" || sub(r, "ghidra", "manifest") != manifestFile {
		t.Fatalf("ghidra: %v", r["ghidra"])
	}
	if sub(r, "run", "exit_code") != float64(0) {
		t.Fatalf("run: %v", r["run"])
	}
	if got := len(r["provenance"].([]any)); got != 9 {
		t.Fatalf("provenance entries = %d, want 9", got)
	}
	for _, f := range []string{"input/target.bin", "tool/bwrap", "logs/stdout.txt", "logs/application.log", "output/curated.json", manifestFile} {
		if !w.exists("out/" + f) {
			t.Errorf("missing %s", f)
		}
	}
	if w.exists("out/manifest-spec.json") || w.exists(".out.stage") {
		t.Error("spec or stage left behind")
	}
	w.verify(w.path("out"))
}

func TestUntrustedLauncherIsLabelledTestOnly(t *testing.T) {
	w := newWorld(t)
	if rc := w.run("out"); rc != 0 {
		t.Fatalf("rc=%d %q", rc, w.errBuf.String())
	}
	r := w.readJSON("out/report.json")
	if sub(r, "isolation", "network_access") != true || sub(r, "isolation", "read_only_host_root") != false {
		t.Fatalf("isolation: %v", r["isolation"])
	}
	lim := r["limitations"].([]any)
	if len(lim) != 3 || !strings.HasPrefix(lim[2].(string), "TEST ONLY") {
		t.Fatalf("limitations: %v", lim)
	}
}

func TestTrustPolicyRefusesUntestedLauncherWithoutTestOnly(t *testing.T) {
	w := newWorld(t)
	delete(w.env, "RSDD_TEST_ONLY_UNTRUSTED_BWRAP")
	rc := w.run("out")
	w.refused(rc, "out", "Bubblewrap must match trusted PATH-selected bwrap")
}

func TestFlagEnablesTestOnlyMode(t *testing.T) {
	w := newWorld(t)
	delete(w.env, "RSDD_TEST_ONLY_UNTRUSTED_BWRAP")
	if rc := w.run("out", "--test-only-untrusted-bwrap"); rc != 0 {
		t.Fatalf("rc=%d %q", rc, w.errBuf.String())
	}
}

func TestPartialAndFailedOutcomes(t *testing.T) {
	cases := []struct {
		mode, status string
		rc           int
		errs         string
	}{
		{"partial", "partial", 0, ""},
		{"nonzero", "failed", 1, "analyzer-exit:9"},
		{"missing", "failed", 1, "missing-curated-output"},
		{"malformed", "failed", 1, "malformed-curated-output"},
		{"sentinel", "failed", 1, "unchanged-sentinel"},
		{"dishonest", "failed", 1, "malformed-curated-output"},
		{"boolean", "failed", 1, "malformed-curated-output"},
		{"symlinkout", "failed", 1, "unsafe-curated-output"},
		{"bigout", "failed", 1, "curated-output-cap"},
	}
	for _, c := range cases {
		t.Run(c.mode, func(t *testing.T) {
			w := newWorld(t)
			w.headless(c.mode)
			extra := []string{}
			if c.mode == "bigout" {
				extra = []string{"--max-output-bytes", "100"}
			}
			rc := w.run("out", extra...)
			if rc != c.rc {
				t.Fatalf("rc=%d want %d stderr=%q", rc, c.rc, w.errBuf.String())
			}
			r := w.readJSON("out/report.json")
			if r["status"] != c.status {
				t.Fatalf("status=%v want %s: %v", r["status"], c.status, r["errors"])
			}
			if c.errs != "" && (len(r["errors"].([]any)) == 0 || r["errors"].([]any)[0] != c.errs) {
				t.Fatalf("errors=%v want %s", r["errors"], c.errs)
			}
			if c.rc == 1 && !strings.Contains(w.errBuf.String(), "completeness=failed") {
				t.Fatalf("a failed published run warns on stderr: %q", w.errBuf.String())
			}
			w.verify(w.path("out"))
		})
	}
}

func TestDiagnosticFloodIsCappedAndReported(t *testing.T) {
	w := newWorld(t)
	w.headless("flood")
	if rc := w.run("out", "--max-diagnostic-bytes", "1000", "--timeout-seconds", "3"); rc != 1 {
		t.Fatalf("rc=%d", rc)
	}
	r := w.readJSON("out/report.json")
	if r["errors"].([]any)[0] != "diagnostic-cap" {
		t.Fatalf("errors=%v", r["errors"])
	}
	var total int64
	for _, f := range []string{"stdout.txt", "stderr.txt", "application.log", "script.log"} {
		fi, err := os.Stat(w.path("out/logs/" + f))
		must(t, err)
		total += fi.Size()
	}
	if total > 1000 {
		t.Fatalf("diagnostics total %d bytes, cap 1000", total)
	}
}

func TestWallTimeoutStopsTheRun(t *testing.T) {
	w := newWorld(t)
	w.headless("timeout")
	if rc := w.run("out", "--timeout-seconds", "1"); rc != 1 {
		t.Fatalf("rc=%d", rc)
	}
	if r := w.readJSON("out/report.json"); r["errors"].([]any)[0] != "wall-timeout" {
		t.Fatalf("errors=%v", r["errors"])
	}
}

func TestPlantedDiagnosticSymlinkIsRefused(t *testing.T) {
	w := newWorld(t)
	w.headless("loglink")
	w.refused(w.run("out"), "out", "unsafe diagnostic file: application.log")
	if w.exists(".out.stage") {
		t.Fatal("stage left behind")
	}
}

func TestDescendantIsReaped(t *testing.T) {
	w := newWorld(t)
	w.headless("descendant")
	if rc := w.run("out"); rc != 1 {
		t.Fatalf("rc=%d", rc)
	}
	b, err := os.ReadFile(w.path("child.pid"))
	must(t, err)
	pid := strings.TrimSpace(string(b))
	// Killed and collected: not running and not even a zombie waiting for its adopter.
	if st, err := os.ReadFile("/proc/" + pid + "/stat"); err == nil {
		t.Fatalf("descendant %s still exists after the run: %s", pid, st)
	}
}

func TestRefusals(t *testing.T) {
	t.Run("caps", func(t *testing.T) {
		w := newWorld(t)
		w.refused(w.run("out", "--max-files", "11"), "out", "caps must be positive and max-files at least 12")
	})
	t.Run("no ghidra", func(t *testing.T) {
		w := newWorld(t)
		w.env["ANALYZE_HEADLESS"] = w.path("nope/support/analyzeHeadless")
		w.refused(w.run("out"), "out", "Ghidra unavailable")
	})
	t.Run("no java", func(t *testing.T) {
		w := newWorld(t)
		delete(w.env, "JAVA_HOME")
		w.env["PATH"] = "/nonexistent"
		w.refused(w.run("out"), "out", "Java 21 unavailable")
	})
	t.Run("no bwrap", func(t *testing.T) {
		w := newWorld(t)
		w.env["RSDD_BWRAP"] = w.path("nope")
		w.refused(w.run("out"), "out", "Bubblewrap unavailable")
	})
	t.Run("input missing", func(t *testing.T) {
		w := newWorld(t)
		w.input = w.path("missing.bin")
		w.refused(w.run("out"), "out", "cannot safely open "+w.input)
	})
	t.Run("input directory", func(t *testing.T) {
		w := newWorld(t)
		w.input = w.root
		w.refused(w.run("out"), "out", "not a regular file: "+w.root)
	})
	t.Run("input symlink", func(t *testing.T) {
		w := newWorld(t)
		must(t, os.Symlink(w.input, w.path("link.bin")))
		w.input = w.path("link.bin")
		w.refused(w.run("out"), "out", "cannot safely open "+w.input)
	})
	t.Run("output exists", func(t *testing.T) {
		w := newWorld(t)
		must(t, os.Mkdir(w.path("out"), 0o755))
		w.refused(w.run("out"), "", "output must be new and non-colliding")
	})
	t.Run("output parent not canonical", func(t *testing.T) {
		w := newWorld(t)
		must(t, os.Mkdir(w.path("real"), 0o755))
		must(t, os.Symlink(w.path("real"), w.path("alias")))
		w.refused(w.run("alias/out"), "", "output parent must be canonical")
	})
	t.Run("output parent missing", func(t *testing.T) {
		w := newWorld(t)
		w.run("nodir/out")
		if rc := w.exec("--input", w.input, "--output", w.path("nodir/out"), "--toolbelt", w.path("toolbelt")); rc != 2 ||
			!strings.HasPrefix(w.errBuf.String(), "corroborate-ghidra: [Errno 2] No such file or directory: ") {
			t.Fatalf("rc=%d %q", rc, w.errBuf.String())
		}
	})
	t.Run("not a private filesystem", func(t *testing.T) {
		w := newWorld(t)
		w.d.mountinfo = func() (string, error) { return "1 0 0:1 / / rw - nfs srv:/x rw\n", nil }
		if rc := w.run("out"); rc != 2 || w.exists("out") {
			t.Fatalf("rc=%d %q", rc, w.errBuf.String())
		}
	})
	t.Run("foreign stage kept", func(t *testing.T) {
		w := newWorld(t)
		must(t, os.Mkdir(w.path(".out.stage"), 0o700))
		must(t, os.WriteFile(w.path(".out.stage/keep"), []byte("x"), 0o600))
		if rc := w.run("out"); rc != 2 {
			t.Fatalf("rc=%d", rc)
		}
		if !w.exists(".out.stage/keep") {
			t.Fatal("a stage this run did not create was removed")
		}
	})
}

func TestEvidenceFileCap(t *testing.T) {
	w := newWorld(t)
	w.refused(w.run("out", "--max-files", "12"), "out", "evidence file cap exceeded")
	if w.exists(".out.stage") {
		t.Fatal("stage left behind")
	}
}

func TestStagedBytesMustStayStable(t *testing.T) {
	w := newWorld(t)
	w.d.beforeRun = func(stage string) {
		must(t, os.Chmod(stage+"/tool/ghidra/support/launch.properties", 0o600))
		must(t, os.WriteFile(stage+"/tool/ghidra/support/launch.properties", []byte("tampered\n"), 0o600))
	}
	w.refused(w.run("out"), "out", "locked staged bytes changed")
}

func TestStagedPathnameMustStayBound(t *testing.T) {
	w := newWorld(t)
	w.d.beforeRun = func(stage string) {
		p := stage + "/tool/ghidra/support/launch.properties"
		must(t, os.Remove(p))
		must(t, os.WriteFile(p, []byte("support/launch.properties\n"), 0o400))
	}
	w.refused(w.run("out"), "out", "staged pathname replaced")
}

func TestHelpAndUsage(t *testing.T) {
	w := newWorld(t)
	if rc := w.exec("--help"); rc != 0 || !strings.Contains(w.out.String(), "--input") {
		t.Fatalf("help rc=%d %q", rc, w.out.String())
	}
	if rc := w.exec("--output", "x"); rc != 2 || !strings.Contains(w.errBuf.String(), "--input") {
		t.Fatalf("usage rc=%d %q", rc, w.errBuf.String())
	}
}

func TestCuratedValidationErrorsAreSingleAndTyped(t *testing.T) {
	caps := map[string]int{"functions": 2, "symbols": 2, "imports": 2, "exports": 2, "strings": 2, "references": 2, "string_chars": 32}
	dir := t.TempDir()
	write := func(b []byte) string {
		p := dir + "/c.json"
		must(t, os.RemoveAll(p))
		must(t, os.WriteFile(p, b, 0o644))
		return p
	}
	if st, errs := validateCurated(write(curatedBytes(curatedDoc())), caps, 1<<20); st != "complete" || errs != nil {
		t.Fatalf("valid: %q %v", st, errs)
	}
	for name, b := range map[string][]byte{
		"trailing garbage":  append(curatedBytes(curatedDoc()), '{'),
		"no newline":        []byte(strings.TrimSuffix(string(curatedBytes(curatedDoc())), "\n")),
		"wrong cap":         curatedBytes(curatedDoc(func(d map[string]any) { d["caps"].(map[string]any)["strings"] = 3 })),
		"extra top key":     curatedBytes(curatedDoc(func(d map[string]any) { d["x"] = 1 })),
		"fractional count":  []byte(strings.Replace(string(curatedBytes(curatedDoc())), `"emitted":0`, `"emitted":0.0`, 1)),
		"bad utf8":          {'{', 0xff, '}', '\n'},
		"unsorted truthful": curatedBytes(curatedDoc(func(d map[string]any) { d["status"] = "partial" })),
	} {
		if st, errs := validateCurated(write(b), caps, 1<<20); st != "" || len(errs) != 1 || errs[0] != "malformed-curated-output" {
			t.Errorf("%s: %q %v", name, st, errs)
		}
	}
	if _, errs := validateCurated(dir+"/absent.json", caps, 1<<20); errs[0] != "missing-curated-output" {
		t.Errorf("absent: %v", errs)
	}
}
