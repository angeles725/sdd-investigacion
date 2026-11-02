package java

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/adapter"
)

// manifest runs the in-process manifest CLI (`rsdd adapter manifest`) the way the legacy tests ran the Python one.
func manifest(t *testing.T, cwd string, args ...string) int {
	t.Helper()
	var out, errb bytes.Buffer
	return adapter.ManifestRun(args, cli.Stdio{Out: &out, Err: &errb, Cwd: cwd, Env: func(string) string { return "" }})
}

func TestFiveAdaptersSucceedWithoutExecutingTargetOrWrapper(t *testing.T) {
	h := newHarness(t)
	r := h.run(h.args("--output", h.out("out one"))...)
	if r.rc != 0 || r.err != "" {
		t.Fatalf("rc=%d stderr=%q", r.rc, r.err)
	}
	if h.exists(h.root, "WRAPPER_EXECUTED") {
		t.Fatal("the decompile wrapper was executed")
	}
	rep := h.report(h.out("out one"))
	if rep["schema"] != schema || rep["status"] != "complete" {
		t.Fatalf("schema/status = %v/%v", rep["schema"], rep["status"])
	}
	engines := rep["engines"].(map[string]any)
	if len(engines) != 5 {
		t.Fatalf("engines = %v", engines)
	}
	for name, e := range engines {
		if get(e, "status") != "success" {
			t.Errorf("%s status = %v", name, get(e, "status"))
		}
	}
	if got := rep["expected_classes"].([]any); len(got) != 1 || got[0] != "fixture.App" {
		t.Errorf("expected_classes = %v", got)
	}
	if sigs := rep["javap_signatures"].([]any); len(sigs) == 0 {
		t.Error("javap_signatures is empty")
	}
}

func TestManifestsAreCanonicalBoundAndVerify(t *testing.T) {
	h := newHarness(t)
	if r := h.run(h.args("--output", h.out("out one"))...); r.rc != 0 {
		t.Fatalf("rc=%d %s", r.rc, r.err)
	}
	root := h.out("out one")
	rep := h.report(root)
	for name := range rep["engines"].(map[string]any) {
		path := filepath.Join(root, "engines", name, "analysis-manifest.v1.json")
		if manifest(t, root, "validate", path) != 0 || manifest(t, root, "verify", "--root", root, path) != 0 {
			t.Fatalf("%s manifest does not validate and verify", name)
		}
		raw, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		var doc map[string]any
		if err := json.Unmarshal(raw, &doc); err != nil {
			t.Fatal(err)
		}
		argv := doc["argv"].([]any)
		if argv[0] != h.bwrap || get(doc, "tool", "launcher", "resolved_executable") != h.bwrap {
			t.Errorf("%s: launcher is %v / %v, want %s", name, argv[0], get(doc, "tool", "launcher", "resolved_executable"), h.bwrap)
		}
		has := func(s string) bool {
			for _, a := range argv {
				if a == s {
					return true
				}
			}
			return false
		}
		if !has("--unshare-net") || argv[2] != "--new-session" || argv[1] != "--die-with-parent" {
			t.Errorf("%s: sandbox flags missing: %v", name, argv[:6])
		}
		for _, a := range get(doc, "tool", "artifacts").([]any) {
			rec := a.(map[string]any)
			if argv[int(rec["argv_index"].(float64))] != rec["path"] {
				t.Errorf("%s: artifact %v is not at its argv index", name, rec)
			}
		}
		if p := get(doc, "isolation_profile"); p == nil || get(p, "name") != "bubblewrap-static-network-denied" ||
			get(p, "network_access") != false || get(p, "static_only") != true || get(p, "target_execution") != false {
			t.Errorf("%s: isolation_profile = %v", name, p)
		}
		if !strings.Contains(string(raw), "WSL2 is not a security boundary") || strings.Contains(string(raw), "do-not-persist") {
			t.Errorf("%s: limitations or secret handling wrong", name)
		}
		for _, f := range []string{"stdout.raw.txt", "stderr.raw.txt"} {
			if h.exists(root, "engines", name, f) {
				t.Errorf("%s: %s survived normalisation", name, f)
			}
		}
		stderr, _ := os.ReadFile(filepath.Join(root, "engines", name, "stderr.txt"))
		if name != "jdeps" || true {
			if !strings.Contains(string(stderr), "<STAGING_ROOT>") {
				t.Errorf("%s: stderr is not normalised: %q", name, stderr)
			}
		}
		if _, jar := h.tools[name]; jar {
			staged := filepath.Join(root, "trusted-tools", name+".jar")
			if fi, err := os.Stat(staged); err != nil || fi.Mode().Perm() != 0o400 {
				t.Errorf("%s: staged jar mode = %v (%v)", name, fi, err)
			}
			if fi, err := os.Stat(filepath.Join(root, "trusted-tools")); err != nil || fi.Mode().Perm() != 0o500 {
				t.Errorf("trusted-tools mode = %v (%v)", fi, err)
			}
			evidence := get(rep, "engines", name, "trusted_source")
			if get(evidence, "schema") != "trusted-tool-copy.v1" || get(evidence, "source", "path") != h.tools[name] ||
				get(evidence, "source", "sha256") != get(evidence, "staged", "sha256") {
				t.Errorf("%s: trusted_source = %v", name, evidence)
			}
		}
	}
	t.Cleanup(func() { _ = os.Chmod(filepath.Join(root, "trusted-tools"), 0o700) })
}

func TestReportIsDeterministicAndSecretFree(t *testing.T) {
	h := newHarness(t)
	for _, out := range []string{"out one", "out two"} {
		if r := h.run(h.args("--output", h.out(out))...); r.rc != 0 {
			t.Fatalf("rc=%d %s", r.rc, r.err)
		}
	}
	a, _ := os.ReadFile(filepath.Join(h.out("out one"), schema+".json"))
	b, _ := os.ReadFile(filepath.Join(h.out("out two"), schema+".json"))
	if !bytes.Equal(a, b) {
		t.Fatalf("reports differ:\n%s\n%s", a, b)
	}
	if !bytes.HasSuffix(a, []byte("}\n")) {
		t.Error("report is not canonical JSON ending in a newline")
	}
	err := filepath.WalkDir(h.out("out one"), func(p string, d os.DirEntry, werr error) error {
		if werr == nil && d.Type().IsRegular() {
			if body, _ := os.ReadFile(p); bytes.Contains(body, []byte("do-not-persist")) {
				t.Errorf("secret persisted in %s", p)
			}
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_ = os.Chmod(filepath.Join(h.out("out one"), "trusted-tools"), 0o700)
		_ = os.Chmod(filepath.Join(h.out("out two"), "trusted-tools"), 0o700)
	})
}

func TestOneAdapterFailurePreservesPartialEvidence(t *testing.T) {
	h := newHarness(t)
	h.mode("cfr", "fail")
	r := h.run(h.args("--output", h.out("partial"))...)
	if r.rc != 1 {
		t.Fatalf("rc = %d, want 1; stderr %q", r.rc, r.err)
	}
	rep := h.report(h.out("partial"))
	if rep["status"] != "partial" || get(rep, "engines", "cfr", "status") != "failed" || get(rep, "engines", "vineflower", "status") != "success" {
		t.Fatalf("report = %v", rep)
	}
	if get(rep, "engines", "cfr", "exit_code") != float64(7) {
		t.Errorf("cfr exit_code = %v", get(rep, "engines", "cfr", "exit_code"))
	}
	if got := rep["errors"].([]any); len(got) != 1 || got[0] != "cfr: failed" {
		t.Errorf("errors = %v", got)
	}
	want := "java-corroboration.v1: completed with issues (cfr) — see " + h.out("partial") + "/java-corroboration.v1.json\n"
	if r.err != want {
		t.Errorf("stderr = %q, want %q", r.err, want)
	}
}

func TestPerAdapterTimeoutIsExplicit(t *testing.T) {
	h := newHarness(t)
	h.mode("vineflower", "slow")
	r := h.run(h.args("--timeout-seconds", "1", "--output", h.out("timeout"))...)
	if r.rc != 1 {
		t.Fatalf("rc = %d; stderr %q", r.rc, r.err)
	}
	rep := h.report(h.out("timeout"))
	if get(rep, "engines", "vineflower", "status") != "timeout" || get(rep, "engines", "cfr", "status") != "success" {
		t.Fatalf("engines = %v", rep["engines"])
	}
	if get(rep, "engines", "vineflower", "signal") == nil {
		t.Error("a stopped adapter must report its signal")
	}
}

func TestCapsPreserveBoundedPerEnginePartialEvidence(t *testing.T) {
	h := newHarness(t)
	h.mode("cfr", "spam")
	r := h.run(h.args("--max-bytes", "4096", "--output", h.out("capped"))...)
	if r.rc != 1 {
		t.Fatalf("rc = %d; stderr %q", r.rc, r.err)
	}
	root := h.out("capped")
	rep := h.report(root)
	cfr := get(rep, "engines", "cfr")
	if rep["status"] != "partial" || get(rep, "truncated", "adapter_caps") != true || get(cfr, "status") != "cap_exceeded" || get(cfr, "exit_code") != nil {
		t.Fatalf("report = %v", rep)
	}
	trunc := get(cfr, "truncated").(map[string]any)
	if trunc["diagnostics"] != true && trunc["outputs"] != true {
		t.Errorf("truncated = %v", trunc)
	}
	if get(rep, "engines", "vineflower", "status") != "success" {
		t.Error("an unrelated engine must stay successful")
	}
	engine := filepath.Join(root, "engines", "cfr")
	total := int64(0)
	for _, n := range []string{"stdout.txt", "stderr.txt"} {
		fi, err := os.Stat(filepath.Join(engine, n))
		if err != nil {
			t.Fatal(err)
		}
		total += fi.Size()
	}
	inv := get(cfr, "output_inventory").([]any)
	if len(inv) == 0 || len(inv) > 100 {
		t.Fatalf("inventory has %d records", len(inv))
	}
	var onDisk []string
	for _, it := range inv {
		total += int64(it.(map[string]any)["size"].(float64))
	}
	if total > 4096 {
		t.Errorf("diagnostics + outputs = %d bytes, over the 4096 cap", total)
	}
	_ = filepath.WalkDir(filepath.Join(engine, "output"), func(p string, d os.DirEntry, err error) error {
		if err == nil && d.Type().IsRegular() {
			rel, _ := filepath.Rel(filepath.Join(engine, "output"), p)
			onDisk = append(onDisk, filepath.ToSlash(rel))
		}
		return nil
	})
	if len(onDisk) != len(inv) {
		t.Errorf("%d files on disk, %d inventoried: %v", len(onDisk), len(inv), onDisk)
	}
	t.Cleanup(func() { _ = os.Chmod(filepath.Join(root, "trusted-tools"), 0o700) })
}

func TestAnAdapterSymlinkAbortsTheRun(t *testing.T) {
	h := newHarness(t)
	h.mode("cfr", "link")
	r := h.run(h.args("--output", h.out("link"))...)
	if r.rc != 2 || !strings.Contains(r.err, "adapter output symlink is forbidden") && !strings.Contains(r.err, "adapter emitted a symlink") {
		t.Fatalf("rc=%d stderr=%q", r.rc, r.err)
	}
	if h.exists(h.out("link")) || h.exists(h.root, ".link.stage") {
		t.Error("a refused run left evidence or a stage behind")
	}
}

func TestMissingTrustOrIsolationRefusesAndCleansUp(t *testing.T) {
	cases := []struct {
		name   string
		mutate func(h *harness)
		want   string
	}{
		{"empty pin", func(h *harness) { h.env["VINEFLOWER_SHA256"] = "" }, "vineflower trusted SHA-256 pin is absent or invalid"},
		{"wrong pin", func(h *harness) { h.env["CFR_SHA256"] = strings.Repeat("0", 64) }, "cfr SHA-256 does not match trusted pin"},
		{"malformed pin", func(h *harness) { h.env["PROCYON_SHA256"] = "sha256:XYZ" }, "procyon trusted SHA-256 pin is absent or invalid"},
		{"missing launcher", func(h *harness) { h.env["RSDD_BWRAP"] = filepath.Join(h.root, "missing-bwrap") }, "launcher cannot be resolved"},
		{"empty launcher", func(h *harness) { h.env["RSDD_BWRAP"] = "" }, "bubblewrap is required for analyzer isolation"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			h := newHarness(t)
			c.mutate(h)
			r := h.run(h.args("--output", h.out("refused"))...)
			if r.rc != 2 || !strings.Contains(r.err, c.want) {
				t.Fatalf("rc=%d stderr=%q, want rc 2 containing %q", r.rc, r.err, c.want)
			}
			if h.exists(h.out("refused")) || h.exists(h.root, ".refused.stage") {
				t.Error("a refused run left evidence or a stage behind")
			}
		})
	}
}

func TestANonBubblewrapLauncherFailsClosedBeforeAnalysis(t *testing.T) {
	h := newHarness(t)
	h.env["RSDD_BWRAP"] = "/bin/true"
	r := h.run(h.args("--output", h.out("wrong"))...)
	if r.rc != 2 || !strings.Contains(r.err, "configured isolation launcher does not match system Bubblewrap") {
		t.Fatalf("rc=%d stderr=%q", r.rc, r.err)
	}
	if h.exists(h.out("wrong")) || h.exists(h.root, ".wrong.stage") || h.exists(h.root, "WRAPPER_EXECUTED") {
		t.Error("evidence, stage or wrapper execution after a refusal")
	}
}

func TestIsolationProbeFailureIsTyped(t *testing.T) {
	h := newHarness(t)
	h.write(h.bwrap, "#!/bin/sh\nexit 1\n", 0o755)
	r := h.run(h.args("--output", h.out("noiso"))...)
	if r.rc != 2 || !strings.Contains(r.err, "network-denied isolation cannot be established") {
		t.Fatalf("rc=%d stderr=%q", r.rc, r.err)
	}
	if h.exists(h.root, ".noiso.stage") {
		t.Error("stage left behind")
	}
}

func TestBubblewrapMustBeRootOwned(t *testing.T) {
	h := newHarness(t)
	var out, errb bytes.Buffer
	s := cli.Stdio{Out: &out, Err: &errb, Cwd: h.root, Env: func(k string) string { return h.env[k] }, Clock: func() time.Time { return h.clock }}
	e := newEnv(s) // the real owner check: the fake launcher belongs to the test user, not root
	e.helper = nil
	if rc := e.main(h.args("--output", h.out("owned"))); rc != 2 || !strings.Contains(errb.String(), "bubblewrap launcher must be root-owned and non-writable") {
		t.Fatalf("rc=%d stderr=%q", rc, errb.String())
	}
}

func TestSourceMutationCannotChangeStagedEvidence(t *testing.T) {
	h := newHarness(t)
	if r := h.run(h.args("--output", h.out("out one"))...); r.rc != 0 {
		t.Fatalf("rc=%d %s", r.rc, r.err)
	}
	root := h.out("out one")
	t.Cleanup(func() { _ = os.Chmod(filepath.Join(root, "trusted-tools"), 0o700) })
	before, _ := os.ReadFile(filepath.Join(root, "trusted-tools", "vineflower.jar"))
	f, err := os.OpenFile(h.tools["vineflower"], os.O_APPEND|os.O_WRONLY, 0)
	if err != nil {
		t.Fatal(err)
	}
	_, _ = f.WriteString("source changed after private copy\n")
	_ = f.Close()
	after, _ := os.ReadFile(filepath.Join(root, "trusted-tools", "vineflower.jar"))
	if !bytes.Equal(before, after) {
		t.Fatal("the staged copy followed the source")
	}
	if manifest(t, root, "verify", "--root", root, filepath.Join(root, "engines", "vineflower", "analysis-manifest.v1.json")) != 0 {
		t.Error("the staged invocation no longer verifies")
	}
}

func TestUnavailableDecompilerIsTypedNotSkipped(t *testing.T) {
	h := newHarness(t)
	delete(h.env, "RSDD_CORROBORATE_PROCYON")
	r := h.run(h.args("--output", h.out("unavail"))...)
	if r.rc != 1 {
		t.Fatalf("rc=%d stderr=%q", r.rc, r.err)
	}
	rep := h.report(h.out("unavail"))
	p := get(rep, "engines", "procyon")
	if get(p, "status") != "unavailable" || get(p, "exit_code") != float64(127) || get(p, "manifest") != nil || get(p, "trusted_source") != nil {
		t.Fatalf("procyon = %v", p)
	}
	stderr, _ := os.ReadFile(filepath.Join(h.out("unavail"), "engines", "procyon", "stderr.txt"))
	if string(stderr) != "analyzer JAR unavailable\n" {
		t.Errorf("stderr = %q", stderr)
	}
	t.Cleanup(func() { _ = os.Chmod(filepath.Join(h.out("unavail"), "trusted-tools"), 0o700) })
}

func TestNoDecompilerJarsMeansThreeUnavailableEngines(t *testing.T) {
	h := newHarness(t)
	for _, n := range engineNames[:3] {
		delete(h.env, "RSDD_CORROBORATE_"+strings.ToUpper(n))
	}
	r := h.run(h.args("--output", h.out("none"))...)
	if r.rc != 1 || !strings.Contains(r.err, "(vineflower, cfr, procyon)") {
		t.Fatalf("rc=%d stderr=%q", r.rc, r.err)
	}
	rep := h.report(h.out("none"))
	if get(rep, "engines", "javap", "status") != "success" || get(rep, "engines", "jdeps", "status") != "success" {
		t.Errorf("javap and jdeps must still run: %v", rep["engines"])
	}
}

// The manifest is built in-process (core/adapter): the module --manifest-module names is required and kept out of
// the outputs, but never read. An unreadable module therefore changes nothing; a port that loaded it would fail.
func TestManifestModuleIsNeverLoaded(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root reads a mode-000 file, so unreadability proves nothing")
	}
	h := newHarness(t)
	module := filepath.Join(h.root, "analysis_manifest.py")
	if err := os.WriteFile(module, []byte("raise SystemExit('loaded')\n"), 0o000); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(module, 0o000); err != nil {
		t.Fatal(err)
	}
	if _, err := os.ReadFile(module); err == nil {
		t.Skip("this file system does not enforce mode 000")
	}
	r := h.run(h.args("--output", h.out("unloaded"))...)
	if r.rc != 0 || r.err != "" {
		t.Fatalf("rc=%d stderr=%q: the port must not read --manifest-module", r.rc, r.err)
	}
	if rep := h.report(h.out("unloaded")); rep["status"] != "complete" {
		t.Fatalf("status = %v", rep["status"])
	}
}
