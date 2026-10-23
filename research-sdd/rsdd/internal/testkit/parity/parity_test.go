package parity

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

// TestParity is the real differential run. Configuration comes from the
// environment:
//
//	RSDD_PARITY_LEGACY   pinned origin/main kit root (the dir holding toolbelt/)
//	RSDD_BIN             rsdd binary; built once with `go build` when unset
//	RSDD_PARITY_SPECS    spec dir (default testdata/parity)
//	RSDD_PARITY_TARGETS  TARGETS.md path; turns corpus mode on
//	RSDD_PARITY_TIMEOUT  per-run timeout (Go duration, default 60s)
//	RSDD_PARITY_REQUIRE  1 = a missing input FAILS instead of skipping
//
// Without RSDD_PARITY_LEGACY (plain `go test ./...`) it skips with the reason.
func TestParity(t *testing.T) {
	require := os.Getenv("RSDD_PARITY_REQUIRE") == "1"
	gate := func(err error) {
		t.Helper()
		if require {
			t.Fatalf("%v (RSDD_PARITY_REQUIRE=1: a missing input is a failure, not a skip)", err)
		}
		t.Skipf("%v (set RSDD_PARITY_LEGACY to run the differential; RSDD_PARITY_REQUIRE=1 makes this a failure)", err)
	}

	cfg, err := ConfigFromEnv(os.Getenv, t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if cfg.LegacyRoot == "" {
		gate(&Degraded{KindAbsentInput, "legacy kit root not configured: RSDD_PARITY_LEGACY is unset"})
	}
	if cfg.Bin == "" {
		root, err := moduleRoot()
		if err != nil {
			t.Fatal(err)
		}
		if cfg.Bin, err = BuildBinary(root, cfg.Work); err != nil {
			gate(err)
		}
	}
	runner, err := NewRunner(cfg)
	if err != nil {
		gate(err)
	}

	specDir := os.Getenv("RSDD_PARITY_SPECS")
	if specDir == "" {
		specDir = filepath.Join("testdata", "parity")
	}
	cases, err := LoadCases(specDir)
	if err != nil {
		gate(err)
	}

	var opt Options
	if targets := os.Getenv("RSDD_PARITY_TARGETS"); targets != "" {
		toks, err := ParseTargets(targets, ResearchHome(os.Getenv))
		if err != nil {
			t.Fatal(err)
		}
		opt = Options{CorpusMode: true, Corpora: toks}
	}

	t.Cleanup(func() {
		if err := runner.Cleanup(); err != nil {
			t.Error(err)
		}
	})
	rep := runner.RunAll(cases, opt)
	for _, r := range rep.Results {
		switch r.Status {
		case StatusFailed:
			t.Errorf("%s", r.describe())
		default:
			t.Logf("%s", r.describe())
		}
	}
	for _, a := range rep.Absent {
		t.Logf("%s: corpus %s (%s)", KindAbsentInput, a.Path, a.Why)
	}
	t.Log(rep.Summary())
	fmt.Fprintln(os.Stderr, rep.Summary())
	if require && opt.CorpusMode && len(opt.Corpora) > 0 && rep.Counts.AbsentCorpora == len(opt.Corpora) {
		t.Errorf("%s: all %d corpus targets are absent: corpus mode compared nothing", KindAbsentInput, len(opt.Corpora))
	}
}

func moduleRoot() (string, error) {
	dir, err := os.Getwd()
	if err != nil {
		return "", err
	}
	for {
		if _, err := os.Stat(filepath.Join(dir, "go.mod")); err == nil {
			return dir, nil
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return "", fmt.Errorf("no go.mod above the working directory")
		}
		dir = parent
	}
}

// runSelf re-executes this test binary for TestParity only, with a controlled
// RSDD_* environment, and returns its combined output and exit code.
func runSelf(t *testing.T, env map[string]string) (string, int) {
	t.Helper()
	cmd := exec.Command(os.Args[0], "-test.run=^TestParity$", "-test.v", "-test.count=1")
	for _, kv := range os.Environ() {
		if !strings.HasPrefix(kv, "RSDD_") {
			cmd.Env = append(cmd.Env, kv)
		}
	}
	for k, v := range env {
		cmd.Env = append(cmd.Env, k+"="+v)
	}
	out, err := cmd.CombinedOutput()
	code := 0
	if ee, ok := err.(*exec.ExitError); ok {
		code = ee.ExitCode()
	} else if err != nil {
		t.Fatal(err)
	}
	return string(out), code
}

func TestParityGate(t *testing.T) {
	r := newRig(t)
	emptySpecs := t.TempDir()
	r.addCase("eq", []string{"out=a"}, []string{"out=a"}, false, map[string]string{})
	base := map[string]string{"RSDD_PARITY_LEGACY": r.root, "RSDD_BIN": r.bin}
	with := func(extra map[string]string) map[string]string {
		m := map[string]string{}
		for k, v := range base {
			m[k] = v
		}
		for k, v := range extra {
			m[k] = v
		}
		return m
	}
	tests := []struct {
		name     string
		env      map[string]string
		wantExit int
		wantOut  []string
	}{
		{"no legacy root skips", nil, 0, []string{"--- SKIP", "absent-input", "RSDD_PARITY_LEGACY"}},
		{"no legacy root fails under REQUIRE", map[string]string{"RSDD_PARITY_REQUIRE": "1"}, 1, []string{"--- FAIL", "absent-input"}},
		{"missing binary skips", map[string]string{"RSDD_PARITY_LEGACY": r.root, "RSDD_BIN": filepath.Join(r.work, "nope"), "RSDD_PARITY_SPECS": r.specs}, 0, []string{"--- SKIP", "absent-input"}},
		{"missing binary fails under REQUIRE", map[string]string{"RSDD_PARITY_LEGACY": r.root, "RSDD_BIN": filepath.Join(r.work, "nope"), "RSDD_PARITY_SPECS": r.specs, "RSDD_PARITY_REQUIRE": "1"}, 1, []string{"--- FAIL", "absent-input"}},
		{"zero specs skips", with(map[string]string{"RSDD_PARITY_SPECS": emptySpecs}), 0, []string{"--- SKIP", "empty-input: 0 parity specs"}},
		{"zero specs fails under REQUIRE", with(map[string]string{"RSDD_PARITY_SPECS": emptySpecs, "RSDD_PARITY_REQUIRE": "1"}), 1, []string{"--- FAIL", "empty-input: 0 parity specs"}},
		{"passing run prints the summary", with(map[string]string{"RSDD_PARITY_SPECS": r.specs, "RSDD_PARITY_REQUIRE": "1"}), 0,
			[]string{"--- PASS", "parity: compared=1 equal=1 declared-divergent=0 failed=0 absent-corpora=0 skipped=0"}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			out, code := runSelf(t, tt.env)
			if code != tt.wantExit {
				t.Fatalf("exit %d, want %d:\n%s", code, tt.wantExit, out)
			}
			for _, w := range tt.wantOut {
				if !strings.Contains(out, w) {
					t.Errorf("output lacks %q:\n%s", w, out)
				}
			}
		})
	}

	// A divergence makes the real entry point fail.
	bad := newRig(t)
	bad.addCase("bad", []string{"out=a"}, []string{"out=b"}, false, map[string]string{})
	out, code := runSelf(t, map[string]string{"RSDD_PARITY_LEGACY": bad.root, "RSDD_BIN": bad.bin, "RSDD_PARITY_SPECS": bad.specs})
	if code != 1 || !strings.Contains(out, "undeclared-divergence") || !strings.Contains(out, "failed=1") {
		t.Fatalf("an undeclared divergence must fail the entry point (exit %d):\n%s", code, out)
	}

	// An unusable explicit TARGETS.md is a failure even without REQUIRE.
	out, code = runSelf(t, with(map[string]string{"RSDD_PARITY_SPECS": r.specs, "RSDD_PARITY_TARGETS": filepath.Join(r.work, "no-targets.md")}))
	if code != 1 || !strings.Contains(out, "absent-input") {
		t.Fatalf("a TARGETS.md that cannot be read must fail (exit %d):\n%s", code, out)
	}
}

func TestBuildBinary(t *testing.T) {
	if _, err := exec.LookPath("go"); err != nil {
		t.Skip("go toolchain not on PATH")
	}
	mod := t.TempDir()
	for rel, body := range map[string]string{
		"go.mod":           "module tiny\n\ngo 1.21\n",
		"cmd/rsdd/main.go": "package main\n\nfunc main() {}\n",
	} {
		p := filepath.Join(mod, rel)
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	dst := t.TempDir()
	bin, err := BuildBinary(mod, dst)
	if err != nil {
		t.Fatal(err)
	}
	if st, err := os.Stat(bin); err != nil || st.Mode()&0o111 == 0 || filepath.Dir(bin) != dst {
		t.Fatalf("binary not built into dst: %s %v", bin, err)
	}
	want := "rsdd"
	if runtime.GOOS == "windows" {
		want += ".exe"
	}
	if filepath.Base(bin) != want {
		t.Fatalf("binary name %q, want %q on %s", filepath.Base(bin), want, runtime.GOOS)
	}

	_, err = BuildBinary(t.TempDir(), dst)
	d, ok := err.(*Degraded)
	if !ok || d.Kind != KindDegraded || d.Detail == "" {
		t.Fatalf("a failed build must be a typed degraded result carrying the go output, got %v", err)
	}
}
