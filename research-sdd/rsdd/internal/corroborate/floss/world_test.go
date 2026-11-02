//go:build unix

package floss

import (
	"bytes"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// A world is a scratch directory with a fake floss installed in a venv-shaped tree (venv/bin/floss plus
// pyvenv.cfg), a python3 on PATH, an input file and the real bwrap: the command runs for real, only the
// analyzer is a shell script.

const (
	flossHappy = `#!/bin/sh
if [ "$1" = "--version" ]; then echo "floss 3.1.1-fake"; exit 0; fi
cat <<'JSON'
{"strings":{"static_strings":[{"string":"StaticBeta","offset":20,"encoding":"ASCII"},{"string":"StaticAlpha","offset":10,"encoding":"ASCII"},{"string":"AverageLongStaticGamma","offset":30,"encoding":"ASCII"}],"stack_strings":[{"string":"stk","offset":5,"encoding":"ASCII"}],"tight_strings":[],"decoded_strings":[{"string":"decé","offset":7,"encoding":"UTF-16LE"}]}}
JSON
`
	flossSilent    = "#!/bin/sh\nif [ \"$1\" = \"--version\" ]; then echo \"floss 3.1.1-fake\"; exit 0; fi\nexit 0\n"
	flossFails     = "#!/bin/sh\nif [ \"$1\" = \"--version\" ]; then echo \"floss 3.1.1-fake\"; exit 0; fi\necho 'ERROR: not a PE' >&2\nexit 1\n"
	flossJunk      = "#!/bin/sh\nif [ \"$1\" = \"--version\" ]; then echo \"floss 3.1.1-fake\"; exit 0; fi\necho 'not json at all {{{{'\n"
	flossSlow      = "#!/bin/sh\nif [ \"$1\" = \"--version\" ]; then echo \"floss 3.1.1-fake\"; exit 0; fi\nsleep 30\n"
	flossFlood     = "#!/bin/sh\nif [ \"$1\" = \"--version\" ]; then echo \"floss 3.1.1-fake\"; exit 0; fi\nhead -c 6000000 /dev/zero | tr '\\0' 'x'\n"
	flossList      = "#!/bin/sh\nif [ \"$1\" = \"--version\" ]; then echo \"floss 3.1.1-fake\"; exit 0; fi\necho '[1,2]'\n"
	flossNoVersion = "#!/bin/sh\nif [ \"$1\" = \"--version\" ]; then exit 3; fi\nexit 0\n"
)

type world struct {
	t        *testing.T
	root     string
	venv     string
	input    string
	python   string
	manifest string
}

func needBwrap(t *testing.T) {
	t.Helper()
	if _, err := exec.LookPath("bwrap"); err != nil {
		skipOrFail(t, "bwrap not installed")
	}
	if err := exec.Command("bwrap", "--ro-bind", "/", "/", "true").Run(); err != nil {
		skipOrFail(t, "bubblewrap cannot create an unprivileged sandbox here: "+err.Error())
	}
	if _, err := exec.LookPath("python3"); err != nil {
		skipOrFail(t, "python3 not installed (the manifest tool is still Python)")
	}
}

// skipOrFail skips, or fails under RSDD_REQUIRE_BWRAP=1 (CI): a skipped sandbox test proves nothing.
func skipOrFail(t *testing.T, why string) {
	t.Helper()
	if os.Getenv("RSDD_REQUIRE_BWRAP") == "1" {
		t.Fatalf("required tool missing: %s", why)
	}
	t.Skip(why)
}

func newWorld(t *testing.T, script string) *world {
	t.Helper()
	needBwrap(t)
	root := t.TempDir()
	w := &world{t: t, root: root, venv: filepath.Join(root, "venv")}
	must(t, os.MkdirAll(filepath.Join(w.venv, "bin"), 0o755))
	must(t, os.WriteFile(filepath.Join(w.venv, "pyvenv.cfg"), nil, 0o644))
	w.setFloss(script)
	must(t, os.MkdirAll(filepath.Join(root, "pybin"), 0o755))
	py, err := exec.LookPath("python3.12") // the interpreter of the differential oracle, when there is one
	if err != nil {
		py, err = exec.LookPath("python3")
	}
	must(t, err)
	must(t, os.Symlink(py, filepath.Join(root, "pybin", "python3")))
	w.python = filepath.Join(root, "pybin", "python3")
	w.input = filepath.Join(root, "in.bin")
	must(t, os.WriteFile(w.input, []byte("MZ\x90\x00 some binary bytes"), 0o644))
	manifest, err := filepath.Abs("../../core/adapter/testdata/frozen/analysis_manifest.py")
	must(t, err)
	w.manifest = manifest
	return w
}

func (w *world) setFloss(script string) {
	w.t.Helper()
	must(w.t, os.WriteFile(filepath.Join(w.venv, "bin", "floss"), []byte(script), 0o755))
}

func must(t *testing.T, err error) {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
}

func (w *world) out(name string) string { return filepath.Join(w.root, name) }

func (w *world) pathEnv() string {
	return strings.Join([]string{filepath.Join(w.root, "pybin"), filepath.Join(w.venv, "bin"), "/usr/bin", "/bin"}, ":")
}

func (w *world) stdio(out, errw io.Writer, extra map[string]string) cli.Stdio {
	env := map[string]string{
		"PATH": w.pathEnv(), "RSDD_FLOSS": filepath.Join(w.venv, "bin", "floss"), "HOME": os.Getenv("HOME"), "LANG": "C.UTF-8",
	}
	for k, v := range extra {
		env[k] = v
	}
	var environ []string
	for k, v := range env {
		environ = append(environ, k+"="+v)
	}
	return cli.Stdio{
		In: strings.NewReader(""), Out: out, Err: errw, Cwd: w.root,
		Env:     func(k string) string { return env[k] },
		Environ: func() []string { return environ },
		Clock:   time.Now,
	}
}

// run executes `corroborate floss` with the standard flags plus extra.
func (w *world) run(output string, extra ...string) (code int, stdout, stderr string) {
	return w.runEnv(nil, output, extra...)
}

func (w *world) runEnv(env map[string]string, output string, extra ...string) (code int, stdout, stderr string) {
	w.t.Helper()
	var o, e bytes.Buffer
	args := append([]string{"--input", w.input, "--output", output, "--manifest-cli", w.manifest}, extra...)
	code = Run(args, w.stdio(&o, &e, env))
	return code, o.String(), e.String()
}

func (w *world) read(rel string) []byte {
	w.t.Helper()
	b, err := os.ReadFile(filepath.Join(w.root, rel))
	must(w.t, err)
	return b
}
