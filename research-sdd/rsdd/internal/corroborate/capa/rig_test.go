package capa

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// rig is a hermetic stand-in for the host: a fake bwrap that runs the command after "--" directly, a fake
// capa inside a venv-shaped directory whose behaviour is steered by files, a capa-rules directory and an
// output directory. The real bwrap and capa are not needed (the slow lane of tests/capa.test.sh covers them).
type rig struct {
	t       *testing.T
	root    string
	bin     string // fake bwrap
	venv    string // venv/ with pyvenv.cfg; capa lives in venv/bin
	rules   string
	outDir  string
	home    string
	extraEv []string
}

const fakeBwrap = `#!/bin/sh
while [ "$#" -gt 0 ]; do
  if [ "$1" = "--" ]; then shift; break; fi
  shift
done
exec "$@"
`

const fakeCapa = `#!/bin/sh
d="$(dirname "$0")/.."
if [ "$1" = "--version" ]; then cat "$d/version" 2>/dev/null || echo "capa 9.4.0"; exit 0; fi
if [ -f "$d/sleep" ]; then sleep "$(cat "$d/sleep")"; fi
if [ -f "$d/out.json" ]; then cat "$d/out.json"; fi
if [ -f "$d/err.txt" ]; then cat "$d/err.txt" >&2; fi
exit "$(cat "$d/rc" 2>/dev/null || echo 0)"
`

// sampleJSON is a small capa document: three rules in two namespaces, one with ATT&CK and MBC ids.
const sampleJSON = `{"rules": {
 "write file": {"meta": {"namespace": "host-interaction/file-system/write", "attack": [{"id": "T1105"}, {"id": ""}], "mbc": [{"id": "C0052"}]}, "matches": [[1, {}], [2, {}]]},
 "delete file": {"meta": {"namespace": "host-interaction/file-system/delete"}, "matches": [[1, {}]]},
 "compiled with gcc": {"meta": {"namespace": "compiler/gcc"}, "matches": []}}}`

func newRig(t *testing.T) *rig {
	t.Helper()
	root := t.TempDir()
	r := &rig{t: t, root: root, bin: filepath.Join(root, "bin"), venv: filepath.Join(root, "venv"),
		rules: filepath.Join(root, "rules"), outDir: filepath.Join(root, "out"), home: filepath.Join(root, "home")}
	for _, d := range []string{r.bin, filepath.Join(r.venv, "bin"), filepath.Join(r.rules, "lib"), r.outDir, r.home} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	r.write(filepath.Join(r.bin, "bwrap"), fakeBwrap, 0o755)
	r.write(filepath.Join(r.venv, "bin", "capa"), fakeCapa, 0o755)
	r.write(filepath.Join(r.venv, "pyvenv.cfg"), "home = /usr/bin\n", 0o644)
	r.write(filepath.Join(r.rules, "lib", "a.yml"), "rule: {}\n", 0o644)
	r.write(filepath.Join(root, "sample.bin"), "MZ sample bytes", 0o644)
	r.write(filepath.Join(root, "manifest-cli"), "# stands in for analysis_manifest.py: validated, never executed\n", 0o644)
	r.capaOutput(sampleJSON)
	return r
}

func (r *rig) write(path, content string, mode os.FileMode) {
	r.t.Helper()
	if err := os.WriteFile(path, []byte(content), mode); err != nil {
		r.t.Fatal(err)
	}
}

// capaOutput sets what the fake capa prints on stdout.
func (r *rig) capaOutput(s string) { r.write(filepath.Join(r.venv, "out.json"), s, 0o644) }

// capaFile sets one of the fake capa's steering files (rc, sleep, err.txt, version).
func (r *rig) capaFile(name, content string) { r.write(filepath.Join(r.venv, name), content, 0o644) }

func (r *rig) input() string             { return filepath.Join(r.root, "sample.bin") }
func (r *rig) output(name string) string { return filepath.Join(r.outDir, name) }

// base is the arguments every run needs; extra arguments follow.
func (r *rig) args(outName string, extra ...string) []string {
	a := []string{"--input", r.input(), "--output", r.output(outName), "--rules", r.rules, "--manifest-cli", filepath.Join(r.root, "manifest-cli")}
	return append(a, extra...)
}

func (r *rig) environ() []string {
	return append(append([]string{}, r.extraEv...),
		"PATH="+filepath.Join(r.venv, "bin")+":"+r.bin+":/usr/bin:/bin", "HOME="+r.home, "LANG=C.UTF-8")
}

// run executes the command and returns its exit code, stdout and stderr.
func (r *rig) run(args ...string) (int, string, string) {
	r.t.Helper()
	var out, errb bytes.Buffer
	env := r.environ()
	lookup := func(k string) string {
		for _, kv := range env {
			if strings.HasPrefix(kv, k+"=") {
				return kv[len(k)+1:]
			}
		}
		return ""
	}
	s := cli.Stdio{In: strings.NewReader(""), Out: &out, Err: &errb, Env: lookup, Environ: func() []string { return env },
		Clock: time.Now, Cwd: r.root}
	code := Run(args, s)
	return code, out.String(), errb.String()
}

// evidence reads the published capa-evidence.v1.json of an output directory.
func (r *rig) evidence(outName string) map[string]any {
	r.t.Helper()
	b, err := os.ReadFile(filepath.Join(r.output(outName), "capa-evidence.v1.json"))
	if err != nil {
		r.t.Fatalf("evidence not published: %v", err)
	}
	var doc map[string]any
	if err := json.Unmarshal(b, &doc); err != nil {
		r.t.Fatal(err)
	}
	return doc
}

func (r *rig) published(outName string) bool {
	_, err := os.Stat(filepath.Join(r.output(outName), "capa-evidence.v1.json"))
	return err == nil
}
