//go:build linux && !nodiff

package floss

// End-to-end differential tests: the legacy script and the port run the same scenario against the same fake
// floss and the real bwrap, and must agree on exit code, stdout, stderr and the published tree (names, modes,
// bytes; the manifest with its run times blanked).

import (
	"bytes"
	"encoding/json"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/jsonout"
)

const e2eProgram = `
import importlib.util, sys
toolbelt, legacy = sys.argv[1], sys.argv[2]
sys.path.insert(0, toolbelt)
spec = importlib.util.spec_from_file_location("legacy_floss", legacy)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
sys.exit(m.main(sys.argv[3:]))
`

// envList is the environment both implementations run under.
func (w *world) envList(extra map[string]string) []string {
	env := map[string]string{"PATH": w.pathEnv(), "RSDD_FLOSS": filepath.Join(w.venv, "bin", "floss"), "HOME": os.Getenv("HOME"), "LANG": "C.UTF-8"}
	for k, v := range extra {
		env[k] = v
	}
	var out []string
	for k, v := range env {
		out = append(out, k+"="+v)
	}
	sort.Strings(out)
	return out
}

type outcome struct {
	code           int
	stdout, stderr string
}

// both runs the legacy script and the port with the same arguments (output directories "py-<tag>" and
// "go-<tag>" for the harness-named ones) and returns the two outcomes, each output directory name replaced by
// <OUT>.
func (w *world) both(t *testing.T, py, tag string, env map[string]string, args func(out string) []string) (legacy, port outcome) {
	t.Helper()
	pyOut, goOut := w.out("py-"+tag), w.out("go-"+tag)
	so, se, code := pyRun(t, py, e2eProgram, "", w.envList(env), append([]string{absPath(t, "../../../../toolbelt"), absPath(t, legacyScript)}, args(pyOut)...)...)
	legacy = outcome{code, strings.ReplaceAll(so, pyOut, "<OUT>"), strings.ReplaceAll(se, pyOut, "<OUT>")}
	var o, e bytes.Buffer
	port.code = Run(args(goOut), w.stdio(&o, &e, env))
	port.stdout, port.stderr = strings.ReplaceAll(o.String(), goOut, "<OUT>"), strings.ReplaceAll(e.String(), goOut, "<OUT>")
	return legacy, port
}

func (w *world) args(extra ...string) func(string) []string {
	return func(out string) []string {
		return append([]string{"--input", w.input, "--output", out, "--manifest-cli", w.manifest}, extra...)
	}
}

// fixedOut makes a case use one output path for both implementations.
func (w *world) fixedOut(path string, extra ...string) func(string) []string {
	return func(string) []string { return w.args(extra...)(path) }
}

type treeEntry struct {
	Kind string
	Perm fs.FileMode
	Body string
}

// tree lists a directory: relative path, kind, permission bits and content. The manifest's run times and its
// identity digest (a hash over them) are the only timing-dependent bytes; they are blanked.
func tree(t *testing.T, root string) map[string]treeEntry {
	t.Helper()
	out := map[string]treeEntry{}
	err := filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(root, p)
		info, err := d.Info()
		if err != nil {
			return err
		}
		e := treeEntry{Perm: info.Mode().Perm()}
		switch {
		case d.IsDir():
			e.Kind = "dir"
		case info.Mode().IsRegular():
			e.Kind = "file"
			b, err := os.ReadFile(p)
			if err != nil {
				return err
			}
			e.Body = string(b)
			if filepath.Base(p) == "analysis-manifest.v1.json" {
				e.Body = normalizeManifest(t, b)
			}
		default:
			e.Kind = info.Mode().Type().String()
		}
		out[rel] = e
		return nil
	})
	must(t, err)
	return out
}

func normalizeManifest(t *testing.T, b []byte) string {
	t.Helper()
	var m map[string]any
	must(t, json.Unmarshal(b, &m))
	delete(m, "identity")
	if run, ok := m["run"].(map[string]any); ok {
		for _, k := range []string{"started_at", "ended_at", "duration_ms"} {
			delete(run, k)
		}
	}
	out, err := jsonout.Canonical(m)
	must(t, err)
	return string(out)
}

func compareTrees(t *testing.T, w *world, tag string) {
	t.Helper()
	a, b := tree(t, w.out("py-"+tag)), tree(t, w.out("go-"+tag))
	if len(a) < 5 {
		t.Fatalf("%s: the legacy script published %d entries: the comparison would prove nothing", tag, len(a))
	}
	for rel, ea := range a {
		eb, ok := b[rel]
		switch {
		case !ok:
			t.Errorf("%s: %s published by the legacy script only", tag, rel)
		case ea.Kind != eb.Kind || ea.Perm != eb.Perm:
			t.Errorf("%s: %s legacy %s %v, port %s %v", tag, rel, ea.Kind, ea.Perm, eb.Kind, eb.Perm)
		case ea.Body != eb.Body:
			t.Errorf("%s: %s differs\nlegacy: %.600s\nport:   %.600s", tag, rel, ea.Body, eb.Body)
		}
	}
	for rel := range b {
		if _, ok := a[rel]; !ok {
			t.Errorf("%s: %s published by the port only", tag, rel)
		}
	}
}

func TestParityEndToEnd(t *testing.T) {
	py := oraclePython(t)
	scenarios := []struct {
		name   string
		script string
		extra  []string
	}{
		{"happy", flossHappy, nil},
		{"string-cap", flossHappy, []string{"--max-strings", "2"}},
		{"length-cap", flossHappy, []string{"--max-string-len", "5"}},
		{"both-caps", flossHappy, []string{"--max-strings", "3", "--max-string-len", "8", "--timeout", "60"}},
		{"huge-caps", flossHappy, []string{"--max-strings", "99999999999999999999", "--max-string-len", "88888888888888888888"}},
		{"silent", flossSilent, nil},
		{"fails", flossFails, nil},
		{"junk", flossJunk, nil},
		{"timeout", flossSlow, []string{"--timeout", "1"}},
		{"flood", flossFlood, nil},
		{"no-version", flossNoVersion, nil},
	}
	for _, sc := range scenarios {
		t.Run(sc.name, func(t *testing.T) {
			w := newWorld(t, sc.script)
			legacy, port := w.both(t, py, sc.name, nil, w.args(sc.extra...))
			if legacy != port {
				t.Fatalf("legacy %+v\nport   %+v", legacy, port)
			}
			compareTrees(t, w, sc.name)
		})
	}
}

func TestParityRefusals(t *testing.T) {
	py := oraclePython(t)
	w := newWorld(t, flossHappy)
	must(t, os.Mkdir(w.out("taken"), 0o755))
	must(t, os.Symlink(w.out("taken"), w.out("link")))
	must(t, os.Symlink(w.out("missing-target"), w.out("dangling")))
	must(t, os.WriteFile(w.out("floss"), []byte("#!/bin/sh\nexit 0\n"), 0o755))
	must(t, os.WriteFile(w.out("plainfile"), []byte("x"), 0o644))
	noInput := func(out string) []string {
		return []string{"--input", w.out("nope.bin"), "--output", out, "--manifest-cli", w.manifest}
	}
	dirInput := func(out string) []string {
		return []string{"--input", w.root, "--output", out, "--manifest-cli", w.manifest}
	}
	noManifest := func(out string) []string {
		return []string{"--input", w.input, "--output", out, "--manifest-cli", w.out("nope.py")}
	}
	wrapperEnv := map[string]string{"PATH": filepath.Join(w.root, "pybin") + ":" + w.root + ":/usr/bin:/bin", "RSDD_FLOSS": w.out("floss")}
	cases := []struct {
		name string
		env  map[string]string
		args func(out string) []string
	}{
		{"no-args", nil, func(string) []string { return nil }},
		{"help", nil, func(string) []string { return []string{"-h"} }},
		{"bad-int", nil, w.args("--timeout", "x")},
		{"unknown-option", nil, w.args("--bogus")},
		{"ambiguous", nil, w.args("--max-s", "3")},
		{"timeout-zero", nil, w.args("--timeout", "0")},
		{"timeout-negative", nil, w.args("--timeout", "-7")},
		{"max-strings-zero", nil, w.args("--max-strings", "0")},
		{"max-string-len-zero", nil, w.args("--max-string-len", "0")},
		{"dotdot", nil, w.fixedOut(w.root + "/x/../dd")},
		{"backslash", nil, w.fixedOut(w.root + `/b\s`)},
		{"exists", nil, w.fixedOut(w.out("taken"))},
		{"symlink-output", nil, w.fixedOut(w.out("link"))},
		{"dangling-output", nil, w.fixedOut(w.out("dangling"))},
		{"parent-missing", nil, w.fixedOut(w.out("nodir/o"))},
		{"parent-is-file", nil, w.fixedOut(w.out("plainfile/o"))},
		{"floss-missing", map[string]string{"PATH": "/usr/bin:/bin"}, w.args()},
		{"floss-wrapper", wrapperEnv, w.args()},
		{"floss-override-missing", map[string]string{"RSDD_FLOSS": w.out("nonexistent")}, w.args()},
		{"bwrap-override-missing", map[string]string{"RSDD_BWRAP": w.out("nonexistent")}, w.args()},
		{"input-missing", nil, noInput},
		{"input-directory", nil, dirInput},
		{"manifest-missing", nil, noManifest},
	}
	for i, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			legacy, port := w.both(t, py, string(rune('a'+i)), c.env, c.args)
			if c.name == "floss-wrapper" {
				// Intended difference: the script lets VenvBindError escape (a traceback, exit 1) although
				// floss-evidence.v1.md promises exit 2 and a message; the port keeps the promise.
				msg := "tool executable is not inside a 'bin/' directory: " + w.out("floss")
				if legacy.code != 1 || !strings.Contains(legacy.stderr, "VenvBindError: "+msg) ||
					port.code != 2 || port.stderr != "corroborate-floss: "+msg+"\n" {
					t.Fatalf("legacy %+v\nport   %+v", legacy, port)
				}
				return
			}
			if legacy != port {
				t.Fatalf("legacy %+v\nport   %+v", legacy, port)
			}
			if legacy.code != 2 && c.name != "help" {
				t.Errorf("a refusal case must exit 2, got %d: the case proves nothing", legacy.code)
			}
		})
	}
	if entries, _ := os.ReadDir(w.out("taken")); len(entries) != 0 {
		t.Errorf("an existing output directory must stay untouched: %v", entries)
	}
}
