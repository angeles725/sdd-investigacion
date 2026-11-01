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

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/niagara/bogtest"
)

// The compatibility shims (toolbelt/bog_nav.py and the bog-nav.sh wrapper that execs it) must hand the legacy
// command line to the real rsdd binary and pass its exit code, stdout and stderr through unchanged.

const toolbelt = "../../../toolbelt"

func buildRsdd(t *testing.T) string {
	t.Helper()
	if testing.Short() {
		t.Skip("builds the rsdd binary")
	}
	if _, err := exec.LookPath("go"); err != nil {
		t.Skip("shim: go toolchain not found; the shim is NOT proven against a built binary in this run")
	}
	bin := filepath.Join(t.TempDir(), "rsdd")
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()
	cmd := exec.CommandContext(ctx, "go", "build", "-o", bin, "./cmd/rsdd")
	cmd.Dir = filepath.Join("..", "..")
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("go build ./cmd/rsdd: %v\n%s", err, out)
	}
	return bin
}

func runShim(t *testing.T, script string, env []string, args ...string) (code int, stdout, stderr string) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, script, args...)
	if strings.HasSuffix(script, ".py") { // callers run the Python entry point through the interpreter
		cmd = exec.CommandContext(ctx, "python3", append([]string{script}, args...)...)
	}
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

func TestShimsExecRsdd(t *testing.T) {
	bin := buildRsdd(t)
	python(t)
	tb, err := filepath.Abs(toolbelt)
	if err != nil {
		t.Fatal(err)
	}
	env := []string{"RSDD_BIN=" + bin}
	fx := suite(t)
	for _, entry := range []string{"bog_nav.py", "bog-nav.sh"} {
		script := filepath.Join(tb, entry)
		t.Run(entry, func(t *testing.T) {
			for _, fixture := range []string{"valid.bog", "plaintext.bog", "binary.bog", "method99.bog"} {
				want := filepath.Join(t.TempDir(), "want.json")
				wantCode, _, _ := run("--input", fx[fixture], "--output", want)
				got := filepath.Join(t.TempDir(), "got.json")
				code, stdout, stderr := runShim(t, script, env, "--input", fx[fixture], "--output", got)
				if code != wantCode || stdout != "" || stderr != "" {
					t.Errorf("%s: code=%d (want %d) stdout=%q stderr=%q", fixture, code, wantCode, stdout, stderr)
				}
				a, _ := os.ReadFile(want)
				b, _ := os.ReadFile(got)
				if !bytes.Equal(a, b) || len(a) == 0 {
					t.Errorf("%s: shim output differs from the in-process command", fixture)
				}
			}
			// exit 2 and the usage text pass through
			code, _, stderr := runShim(t, script, env, "--input", filepath.Join(t.TempDir(), "absent"), "--output", filepath.Join(t.TempDir(), "o.json"))
			if code != 2 || !strings.Contains(stderr, "No such file or directory") {
				t.Errorf("absent input: code=%d stderr=%q", code, stderr)
			}
			code, out, _ := runShim(t, script, env, "--help")
			if code != 0 || out != wantHelp {
				t.Errorf("--help: code=%d out=%q", code, out)
			}
			code, _, stderr = runShim(t, script, env)
			if code != 2 || stderr != wantUsage+"bog-nav: error: the following arguments are required: --input, --output\n" {
				t.Errorf("no args: code=%d stderr=%q", code, stderr)
			}
		})
	}
}

func TestShimDegradesLoudly(t *testing.T) {
	if testing.Short() {
		t.Skip("shim process tests")
	}
	tb, _ := filepath.Abs(toolbelt)
	script := filepath.Join(tb, "bog_nav.py")
	code, stdout, stderr := runShim(t, script, []string{"RSDD_BIN=" + filepath.Join(t.TempDir(), "not-there")}, "--input", "a", "--output", "b")
	if code != 2 || stdout != "" || !strings.HasPrefix(stderr, "degraded: rsdd-unavailable — RSDD_BIN not executable: ") {
		t.Errorf("missing binary: code=%d stdout=%q stderr=%q", code, stdout, stderr)
	}

	// The shim copied away from its library reports the missing helper instead of passing silently.
	lone := t.TempDir()
	src, err := os.ReadFile(script)
	if err != nil {
		t.Fatal(err)
	}
	copied := filepath.Join(lone, "bog_nav.py")
	if err := os.WriteFile(copied, src, 0o700); err != nil {
		t.Fatal(err)
	}
	code, _, stderr = runShim(t, copied, nil, "--input", "a", "--output", "b")
	if code != 2 || !strings.Contains(stderr, "degraded: rsdd-unavailable — rsdd-exec.sh missing beside "+copied) {
		t.Errorf("missing library: code=%d stderr=%q", code, stderr)
	}
}

func TestShimFollowsASymlink(t *testing.T) {
	bin := buildRsdd(t)
	tb, _ := filepath.Abs(toolbelt)
	link := filepath.Join(t.TempDir(), "bog_nav_link.py")
	if err := os.Symlink(filepath.Join(tb, "bog_nav.py"), link); err != nil {
		t.Fatal(err)
	}
	in := filepath.Join(t.TempDir(), "in.bog")
	if err := os.WriteFile(in, bogtest.Bog(bogtest.ValidXML), 0o600); err != nil {
		t.Fatal(err)
	}
	out := filepath.Join(t.TempDir(), "o.json")
	code, _, stderr := runShim(t, link, []string{"RSDD_BIN=" + bin}, "--input", in, "--output", out)
	if code != 0 || stderr != "" {
		t.Errorf("code=%d stderr=%q", code, stderr)
	}
	if b, err := os.ReadFile(out); err != nil || !strings.Contains(string(b), `"schema": "bog-nav.v1"`) {
		t.Errorf("output = %q, %v", b, err)
	}
}
