package niagara

import (
	"bytes"
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// niagara-security-audit.sh is the CLI shim of rsdd_exec (lib/rsdd-exec.sh, template cli): it hands the legacy
// command line to rsdd and passes the exit code, stdout and stderr through. Python is no longer in the chain.

func saShim(t *testing.T) string {
	t.Helper()
	tb, err := filepath.Abs(toolbelt)
	if err != nil {
		t.Fatal(err)
	}
	return filepath.Join(tb, "niagara-security-audit.sh")
}

// runShimIn runs the shim with a working directory.
func runShimIn(t *testing.T, script, cwd string, env []string, args ...string) (code int, stdout, stderr string) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, script, args...)
	cmd.Dir = cwd
	cmd.Env = append(os.Environ(), env...)
	var out, errb bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errb
	err := cmd.Run()
	if ee, ok := err.(*exec.ExitError); ok {
		code = ee.ExitCode()
	} else if err != nil {
		t.Fatalf("%s did not start: %v", script, err)
	}
	return code, out.String(), errb.String()
}

func TestNoPythonHopRemains(t *testing.T) {
	tb, _ := filepath.Abs(toolbelt)
	if _, err := os.Stat(filepath.Join(tb, "niagara_security_audit.py")); err == nil {
		t.Error("niagara_security_audit.py still exists: the shim must call rsdd directly, not through Python")
	}
	b, err := os.ReadFile(saShim(t))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(b), "python") || !strings.Contains(string(b), "rsdd_exec niagara security-audit") {
		t.Errorf("shim does not call rsdd_exec niagara security-audit:\n%s", b)
	}
}

func TestAuditShimExecsRsdd(t *testing.T) {
	bin := buildRsdd(t)
	env := []string{"RSDD_BIN=" + bin}
	shim := saShim(t)
	fx := fixtures(t)
	for _, tc := range []struct {
		name  string
		root  string
		extra []string
	}{
		{"secure", fx.secure, nil},
		{"insecure with a station", fx.insecure, []string{"--station", fx.bog["bog-exec-on.zip"]}},
		{"empty", fx.empty, nil},
		{"licence hit", fx.licHit, nil},
		{"wildcard module", fx.modulesWild, nil},
	} {
		t.Run(tc.name, func(t *testing.T) {
			want := filepath.Join(t.TempDir(), "want.json")
			wantCode, _, _ := runSA(append([]string{tc.root, "--output", want}, tc.extra...)...)
			got := filepath.Join(t.TempDir(), "got.json")
			code, stdout, stderr := runShimIn(t, shim, "", env, append([]string{tc.root, "--output", got}, tc.extra...)...)
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
	missing := filepath.Join(t.TempDir(), "nope")
	code, _, stderr := runShimIn(t, shim, "", env, missing, "--output", filepath.Join(t.TempDir(), "o.json"))
	if code != 2 || stderr != "niagara-security-audit: "+missing+": No such file or directory\n" {
		t.Errorf("absent root: code=%d stderr=%q", code, stderr)
	}
	code, out, _ := runShimIn(t, shim, "", env, "--help")
	if code != 0 || out != saHelp {
		t.Errorf("--help: code=%d out=%q", code, out)
	}
	code, _, stderr = runShimIn(t, shim, "", env)
	if code != 2 || stderr != saUsageErr("the following arguments are required: INSTALL_ROOT, --output") {
		t.Errorf("no args: code=%d stderr=%q", code, stderr)
	}
}

// A relative root and a relative --output resolve against the caller's working directory.
func TestAuditShimRelativePathsUseTheCallersDirectory(t *testing.T) {
	bin := buildRsdd(t)
	dir := t.TempDir()
	saWrite(t, filepath.Join(dir, "home", "system.properties"), []byte("niagara.moduleVerificationMode=high\n"))
	saMkdir(t, filepath.Join(dir, "real"))
	if err := os.Symlink("real", filepath.Join(dir, "sym")); err != nil {
		t.Fatal(err)
	}
	env := []string{"RSDD_BIN=" + bin}
	code, _, stderr := runShimIn(t, saShim(t), dir, env, "home", "--output", "out.json")
	if code != 0 || stderr != "" {
		t.Fatalf("code=%d stderr=%q", code, stderr)
	}
	raw, err := os.ReadFile(filepath.Join(dir, "out.json"))
	if err != nil || !strings.Contains(string(raw), `"install_root": "home"`) || !strings.Contains(string(raw), `"observed": "high"`) {
		t.Errorf("relative run wrote %q, %v", raw, err)
	}
	// the symlink guard and the containment check work on relative paths too
	code, _, stderr = runShimIn(t, saShim(t), dir, env, "sym/", "--output", "out2.json")
	if code != 2 || stderr != "niagara-security-audit: sym: is a symbolic link (rejected)\n" {
		t.Errorf("relative symlink root: code=%d stderr=%q", code, stderr)
	}
	saMkdir(t, filepath.Join(dir, "outside", "licenses"))
	saWrite(t, filepath.Join(dir, "outside", "licenses", "d.license"), []byte(`smDeveloperMode="true"`))
	saMkdir(t, filepath.Join(dir, "rel", "security"))
	if err := os.Symlink("../../outside/licenses", filepath.Join(dir, "rel", "security", "licenses")); err != nil {
		t.Fatal(err)
	}
	code, _, _ = runShimIn(t, saShim(t), dir, env, "rel", "--output", "out3.json")
	raw, _ = os.ReadFile(filepath.Join(dir, "out3.json"))
	if code != 0 || !strings.Contains(string(raw), `"verdict": "NA"`) || strings.Contains(string(raw), "d.license") {
		t.Errorf("a relative symlink out of a relative root was followed: code=%d %s", code, raw)
	}
}

func TestAuditShimDegradesLoudly(t *testing.T) {
	if testing.Short() {
		t.Skip("shim process tests")
	}
	shim := saShim(t)
	code, stdout, stderr := runShimIn(t, shim, "", []string{"RSDD_BIN=" + filepath.Join(t.TempDir(), "not-there")}, "a", "--output", "b")
	if code != 2 || stdout != "" || !strings.HasPrefix(stderr, "degraded: rsdd-unavailable — RSDD_BIN not executable: ") {
		t.Errorf("missing binary: code=%d stdout=%q stderr=%q", code, stdout, stderr)
	}

	// The shim copied away from its library reports the missing helper instead of passing silently.
	lone := t.TempDir()
	src, err := os.ReadFile(shim)
	if err != nil {
		t.Fatal(err)
	}
	copied := filepath.Join(lone, "niagara-security-audit.sh")
	if err := os.WriteFile(copied, src, 0o700); err != nil {
		t.Fatal(err)
	}
	code, _, stderr = runShimIn(t, copied, "", nil, "a", "--output", "b")
	if code != 2 || !strings.Contains(stderr, "degraded: rsdd-unavailable — rsdd-exec.sh missing beside "+copied) {
		t.Errorf("missing library: code=%d stderr=%q", code, stderr)
	}
}

func TestAuditShimFollowsASymlink(t *testing.T) {
	bin := buildRsdd(t)
	link := filepath.Join(t.TempDir(), "audit-link.sh")
	if err := os.Symlink(saShim(t), link); err != nil {
		t.Fatal(err)
	}
	out := filepath.Join(t.TempDir(), "o.json")
	code, _, stderr := runShimIn(t, link, "", []string{"RSDD_BIN=" + bin}, fixtures(t).secure, "--output", out)
	if code != 0 || stderr != "" {
		t.Errorf("code=%d stderr=%q", code, stderr)
	}
	if b, err := os.ReadFile(out); err != nil || !strings.Contains(string(b), `"schema": "niagara-audit.v1"`) {
		t.Errorf("output = %q, %v", b, err)
	}
}
