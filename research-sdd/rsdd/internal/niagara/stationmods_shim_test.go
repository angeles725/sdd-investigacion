package niagara

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/niagara/bogtest"
)

// station-modules.sh is the CLI shim of rsdd_exec (lib/rsdd-exec.sh, template cli): it hands the legacy command
// line to rsdd and passes the exit code, stdout and stderr through. Python is no longer in the chain.

func smShim(t *testing.T) string {
	t.Helper()
	tb, err := filepath.Abs(toolbelt)
	if err != nil {
		t.Fatal(err)
	}
	return filepath.Join(tb, "station-modules.sh")
}

func TestStationModulesNoPythonHopRemains(t *testing.T) {
	tb, _ := filepath.Abs(toolbelt)
	if _, err := os.Stat(filepath.Join(tb, "station_modules.py")); err == nil {
		t.Error("station_modules.py still exists: the shim must call rsdd directly, not through Python")
	}
	if _, err := os.Stat(filepath.Join(tb, "tests", "station-modules.test.sh")); err == nil {
		t.Error("tests/station-modules.test.sh still exists: the Go tests replace it")
	}
	b, err := os.ReadFile(smShim(t))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(b), "python") || !strings.Contains(string(b), "rsdd_exec niagara station-modules") {
		t.Errorf("shim does not call rsdd_exec niagara station-modules:\n%s", b)
	}
}

func TestStationModulesShimExecsRsdd(t *testing.T) {
	bin := buildRsdd(t)
	env := []string{"RSDD_BIN=" + bin}
	shim := smShim(t)
	fx := smFix(t)
	for _, tc := range []struct{ name, bog, install string }{
		{"valid", fx.bog["valid.bog"], fx.install},
		{"plaintext", fx.bog["plaintext.bog"], fx.install},
		{"binary bog", fx.bog["binary.bog"], fx.install},
		{"empty install", fx.bog["type_mismatch.bog"], fx.empty},
	} {
		t.Run(tc.name, func(t *testing.T) {
			want := filepath.Join(t.TempDir(), "want.json")
			wantCode, _, _ := runSM("--input", tc.bog, "--install", tc.install, "--output", want)
			got := filepath.Join(t.TempDir(), "got.json")
			code, stdout, stderr := runShimIn(t, shim, "", env, "--input", tc.bog, "--install", tc.install, "--output", got)
			if code != wantCode || stdout != "" || stderr != "" {
				t.Errorf("code=%d (want %d) stdout=%q stderr=%q", code, wantCode, stdout, stderr)
			}
			a, _ := os.ReadFile(want)
			b, _ := os.ReadFile(got)
			if !bytes.Equal(a, b) || len(a) == 0 {
				t.Errorf("shim output differs from the in-process command")
			}
		})
	}
	// refusals and usage pass through
	missing := filepath.Join(t.TempDir(), "nope.bog")
	code, _, stderr := runShimIn(t, shim, "", env, "--input", missing, "--install", fx.install, "--output", filepath.Join(t.TempDir(), "o.json"))
	if code != 2 || stderr != "station-modules: "+missing+": No such file or directory\n" {
		t.Errorf("absent input: code=%d stderr=%q", code, stderr)
	}
	code, out, _ := runShimIn(t, shim, "", env, "--help")
	if code != 0 || out != smHelp {
		t.Errorf("--help: code=%d out=%q", code, out)
	}
	code, _, stderr = runShimIn(t, shim, "", env)
	if code != 2 || stderr != smUsageErr("the following arguments are required: --input, --install, --output") {
		t.Errorf("no args: code=%d stderr=%q", code, stderr)
	}
}

// Relative paths resolve against the caller's working directory, for the files and for the containment check.
func TestStationModulesShimRelativePathsUseTheCallersDirectory(t *testing.T) {
	bin := buildRsdd(t)
	dir := t.TempDir()
	smWrite(t, filepath.Join(dir, "in.bog"), bogtest.Bog(smStationXML))
	smWrite(t, filepath.Join(dir, "inst", "modules", "baja-rt.jar"), smJar("baja", "baja-rt", "Station", "ServiceContainer"))
	env := []string{"RSDD_BIN=" + bin}
	code, _, stderr := runShimIn(t, smShim(t), dir, env, "--input", "in.bog", "--install", "inst/", "--output", "out.json")
	if code != 0 || stderr != "" {
		t.Fatalf("code=%d stderr=%q", code, stderr)
	}
	raw, err := os.ReadFile(filepath.Join(dir, "out.json"))
	if err != nil || !strings.Contains(string(raw), `"install_root": "inst"`) || !strings.Contains(string(raw), `"baja-rt"`) {
		t.Errorf("relative run wrote %q, %v", raw, err)
	}
	// a modules/ symlink out of a relative root is an escape, resolved against the caller's directory
	smWrite(t, filepath.Join(dir, "outside", "o.jar"), smJar("baja", "baja-rt", "Station"))
	saMkdir(t, filepath.Join(dir, "rel"))
	if err := os.Symlink("../outside", filepath.Join(dir, "rel", "modules")); err != nil {
		t.Fatal(err)
	}
	code, _, _ = runShimIn(t, smShim(t), dir, env, "--input", "in.bog", "--install", "rel", "--output", "out2.json")
	raw, _ = os.ReadFile(filepath.Join(dir, "out2.json"))
	if code != 1 || !strings.Contains(string(raw), "symlink escape") || strings.Contains(string(raw), "o.jar") {
		t.Errorf("a relative symlink out of a relative root was followed: code=%d %s", code, raw)
	}
}

func TestStationModulesShimDegradesLoudly(t *testing.T) {
	if testing.Short() {
		t.Skip("shim process tests")
	}
	shim := smShim(t)
	code, stdout, stderr := runShimIn(t, shim, "", []string{"RSDD_BIN=" + filepath.Join(t.TempDir(), "not-there")}, "--input", "a", "--install", "b", "--output", "c")
	if code != 2 || stdout != "" || !strings.HasPrefix(stderr, "degraded: rsdd-unavailable — RSDD_BIN not executable: ") {
		t.Errorf("missing binary: code=%d stdout=%q stderr=%q", code, stdout, stderr)
	}

	// The shim copied away from its library reports the missing helper instead of passing silently.
	lone := t.TempDir()
	src, err := os.ReadFile(shim)
	if err != nil {
		t.Fatal(err)
	}
	copied := filepath.Join(lone, "station-modules.sh")
	if err := os.WriteFile(copied, src, 0o700); err != nil {
		t.Fatal(err)
	}
	code, _, stderr = runShimIn(t, copied, "", nil, "--input", "a")
	if code != 2 || !strings.Contains(stderr, "degraded: rsdd-unavailable — rsdd-exec.sh missing beside "+copied) {
		t.Errorf("missing library: code=%d stderr=%q", code, stderr)
	}
}

func TestStationModulesShimFollowsASymlink(t *testing.T) {
	bin := buildRsdd(t)
	link := filepath.Join(t.TempDir(), "modules-link.sh")
	if err := os.Symlink(smShim(t), link); err != nil {
		t.Fatal(err)
	}
	fx := smFix(t)
	out := filepath.Join(t.TempDir(), "o.json")
	code, _, stderr := runShimIn(t, link, "", []string{"RSDD_BIN=" + bin}, "--input", fx.bog["valid.bog"], "--install", fx.install, "--output", out)
	if code != 0 || stderr != "" {
		t.Errorf("code=%d stderr=%q", code, stderr)
	}
	if b, err := os.ReadFile(out); err != nil || !strings.Contains(string(b), `"schema": "station-modules.v1"`) {
		t.Errorf("output = %q, %v", b, err)
	}
}
