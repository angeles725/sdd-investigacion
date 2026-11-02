package native

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
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/proc"
)

// fakeBwrap strips the Bubblewrap flags up to `--` and runs the rest in the working directory, which is the
// stage: it stands in for the sandbox so the real process runner is exercised with no kernel namespaces.
const fakeBwrap = `#!/bin/sh
while [ "$#" -gt 0 ]; do
  case "$1" in
    --) shift; break ;;
    --ro-bind|--bind|--setenv) shift 3 ;;
    --proc|--dev|--tmpfs|--dir|--chdir) shift 2 ;;
    *) shift ;;
  esac
done
exec "$@"
`

const mountExt4 = "1 0 0:1 / / rw - ext4 /dev/sda rw\n"

var fixedNow = time.Date(2026, 11, 2, 12, 0, 0, 123456000, time.UTC)

// world is one hermetic scenario: a scratch tree, a fake r2 and bwrap on a private PATH, injected deps.
type world struct {
	t      *testing.T
	root   string
	input  string
	bin    string
	env    map[string]string
	d      deps
	out    bytes.Buffer
	errBuf bytes.Buffer
}

func newWorld(t *testing.T) *world {
	t.Helper()
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	w := &world{t: t, root: root, bin: filepath.Join(root, "bin"), input: filepath.Join(root, "target.elf")}
	must(t, os.MkdirAll(w.bin, 0o755))
	must(t, os.WriteFile(w.input, []byte("\x7fELF fake target\n"), 0o644))
	w.script("bwrap", fakeBwrap)
	w.r2(`[{"name":"main","offset":4096,"size":10,"nargs":0,"nbbs":1,"type":"fcn","extra":1}]`)
	w.env = map[string]string{"PATH": w.bin + ":/usr/bin:/bin"}
	mount := filepath.Join(root, "mount")
	w.d = deps{
		run:       proc.Run,
		mountinfo: func() (string, error) { return mountExt4, nil },
		mountRoot: mount,
		uid:       os.Getuid(),
		bwrapOK:   func(os.FileInfo) error { return nil },
	}
	return w
}

func must(t *testing.T, err error) {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
}

// script writes an executable file in the fake bin directory.
func (w *world) script(name, body string) string {
	p := filepath.Join(w.bin, name)
	must(w.t, os.WriteFile(p, []byte(body), 0o755))
	return p
}

// r2 installs a fake radare2 whose `aflj` run prints body (and exits with status).
func (w *world) r2(body string) { w.r2Raw("echo '" + body + "'") }

func (w *world) r2Raw(run string) {
	w.script("r2", "#!/bin/sh\n[ \"${1:-}\" = -v ] && { echo 'radare2 fake 1'; exit 0; }\n"+run+"\n")
}

func (w *world) stdio() cli.Stdio {
	env := w.env
	return cli.Stdio{
		In: strings.NewReader(""), Out: &w.out, Err: &w.errBuf, Cwd: w.root,
		Env: func(k string) string { return env[k] },
		Environ: func() []string {
			var l []string
			for k, v := range env {
				l = append(l, k+"="+v)
			}
			return l
		},
		Clock: func() time.Time { return fixedNow },
	}
}

// run executes the command with the default input and the given output (relative to the scratch root) plus extra args.
func (w *world) run(output string, extra ...string) int {
	w.t.Helper()
	return w.exec(append([]string{"--input", w.input, "--output", filepath.Join(w.root, output)}, extra...)...)
}

// exec runs the command with exactly these arguments on fresh output buffers.
func (w *world) exec(args ...string) int {
	w.t.Helper()
	w.out.Reset()
	w.errBuf.Reset()
	return execute(args, w.stdio(), w.d)
}

func (w *world) path(rel string) string { return filepath.Join(w.root, rel) }

func (w *world) readJSON(rel string) map[string]any {
	w.t.Helper()
	b, err := os.ReadFile(w.path(rel))
	if err != nil {
		w.t.Fatal(err)
	}
	var v map[string]any
	if err := json.Unmarshal(b, &v); err != nil {
		w.t.Fatalf("%s: %v", rel, err)
	}
	return v
}

// verify runs the manifest CLI port's `verify` over a published output, as the legacy tests ran analysis_manifest.py.
func (w *world) verify(out string) {
	w.t.Helper()
	var o, e bytes.Buffer
	s := w.stdio()
	s.Out, s.Err = &o, &e
	m := filepath.Join(out, "engine/analysis-manifest.v1.json")
	if rc := adapter.ManifestRun([]string{"validate", m}, s); rc != 0 {
		w.t.Fatalf("manifest validate rc=%d: %s", rc, e.String())
	}
	if rc := adapter.ManifestRun([]string{"verify", "--root", out, m}, s); rc != 0 {
		w.t.Fatalf("manifest verify rc=%d: %s", rc, e.String())
	}
}

func (w *world) exists(rel string) bool {
	_, err := os.Lstat(w.path(rel))
	return err == nil
}

func sub(m map[string]any, keys ...string) any {
	var v any = m
	for _, k := range keys {
		v = v.(map[string]any)[k]
	}
	return v
}
