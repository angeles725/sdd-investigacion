package lint

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

type result struct {
	out, err string
	rc       int
}

// toolbelt is the kit's toolbelt, home of the shared fixtures and of the pack engine (U3.2 owns its retirement).
const toolbelt = "../../../toolbelt"

func fixtures(t *testing.T) string {
	t.Helper()
	d, err := filepath.Abs(filepath.Join(toolbelt, "tests/fixtures/lint-block"))
	if err != nil {
		t.Fatal(err)
	}
	if st, err := os.Stat(d); err != nil || !st.IsDir() {
		t.Fatalf("absent-input: fixture dir %s", d)
	}
	return d
}

func packEnv(t *testing.T) (helper, packs string) {
	t.Helper()
	h, _ := filepath.Abs(filepath.Join(toolbelt, "lint_block.py"))
	p, _ := filepath.Abs(filepath.Join(toolbelt, "lint-block-packs"))
	return h, p
}

// goRun runs the Go command in-process with cwd as its working directory.
func goRun(t *testing.T, cwd string, args ...string) result {
	t.Helper()
	return goRunEnv(t, cwd, nil, args...)
}

// goRunEnv is goRun with extra environment overriding the defaults.
func goRunEnv(t *testing.T, cwd string, extra map[string]string, args ...string) result {
	t.Helper()
	helper, packs := packEnv(t)
	env := map[string]string{"LINT_BLOCK_HELPER": helper, "LINT_BLOCK_PACKS_DIR": packs}
	for k, v := range extra {
		env[k] = v
	}
	var o, e bytes.Buffer
	rc := Run(args, cli.Stdio{
		In: strings.NewReader(""), Out: &o, Err: &e, Cwd: cwd,
		Env:   func(k string) string { return env[k] },
		Clock: time.Now,
	})
	return result{o.String(), e.String(), rc}
}

// legacyRun runs the frozen lint-block.sh (+ lint_block.py + lib) copy.
func legacyRun(t *testing.T, cwd string, args ...string) result {
	t.Helper()
	script, _ := filepath.Abs("testdata/legacy/lint-block.sh")
	_, packs := packEnv(t)
	cmd := exec.Command("bash", append([]string{script}, args...)...)
	cmd.Dir = cwd
	cmd.Env = append(os.Environ(), "LINT_BLOCK_PACKS_DIR="+packs)
	var o, e bytes.Buffer
	cmd.Stdout, cmd.Stderr = &o, &e
	err := cmd.Run()
	rc := 0
	if ee, ok := err.(*exec.ExitError); ok {
		rc = ee.ExitCode()
	} else if err != nil {
		t.Fatalf("legacy run: %v", err)
	}
	return result{o.String(), e.String(), rc}
}

// same compares stdout, stderr and the exit code of the Go command and the frozen legacy script exactly.
func same(t *testing.T, name, cwd string, args ...string) result {
	t.Helper()
	want := legacyRun(t, cwd, args...)
	got := goRun(t, cwd, args...)
	if got != want {
		t.Errorf("%s: args %q differ\n--- legacy (rc=%d)\nstdout:\n%s\nstderr:\n%s\n--- go (rc=%d)\nstdout:\n%s\nstderr:\n%s",
			name, args, want.rc, want.out, want.err, got.rc, got.out, got.err)
	}
	return want
}

var ws2 = re("^[" + wsClass + "]$")

func write(t *testing.T, dir, name, content string) string {
	t.Helper()
	p := filepath.Join(dir, name)
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	return p
}

func fixtureFiles(t *testing.T, dir string) []string {
	t.Helper()
	ents, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	var out []string
	for _, e := range ents {
		if !e.IsDir() && strings.HasSuffix(e.Name(), ".md") {
			out = append(out, e.Name())
		}
	}
	sort.Strings(out)
	if len(out) < 60 {
		t.Fatalf("empty-input: only %d fixtures in %s", len(out), dir)
	}
	return out
}
