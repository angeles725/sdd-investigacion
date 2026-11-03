//go:build linux && !nodiff

package pcap

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

// legacyBootstrap runs a frozen legacy script as __main__ with --manifest-cli optional and always pointing at the
// real analysis_manifest.py (its first argument): the port accepts the flag and ignores it, so the oracle must not
// depend on what the caller passed for it. Everything else is the legacy tool, unmodified (sys.argv[0] stays the
// script, so argparse's prog is unchanged).
const legacyBootstrap = `
import argparse, runpy, sys
from pathlib import Path
manifest = sys.argv[1]
sys.argv = sys.argv[2:]
_add, _parse = argparse.ArgumentParser.add_argument, argparse.ArgumentParser.parse_args
def add_argument(self, *a, **k):
    if "--manifest-cli" in a: k["required"] = False
    return _add(self, *a, **k)
def parse_args(self, args=None, namespace=None):
    ns = _parse(self, args, namespace)
    if hasattr(ns, "manifest_cli"): ns.manifest_cli = Path(manifest)
    return ns
argparse.ArgumentParser.add_argument = add_argument
argparse.ArgumentParser.parse_args = parse_args
runpy.run_path(sys.argv[0], run_name="__main__")
`

func runLegacy(t *testing.T, tl tool, cwd string, loose bool, env []string, args []string) outcome {
	t.Helper()
	legacy, err := filepath.Abs(filepath.Join(legacyDir, tl.legacy))
	if err != nil {
		t.Fatal(err)
	}
	full := append([]string{"-c", legacyBootstrap, manifestCLI(t), legacy}, args...)
	cmd := exec.Command(python(t), full...)
	cmd.Dir, cmd.Env = cwd, env
	var out, errb bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errb
	code := 0
	if err := cmd.Run(); err != nil {
		ee, ok := err.(*exec.ExitError)
		if !ok {
			t.Fatalf("legacy %s: %v", tl.legacy, err)
		}
		code = ee.ExitCode()
	}
	return snapshot(t, cwd, loose, code, out.String(), errb.String())
}

func asOutcome(f frozen) outcome {
	return outcome{code: f.Code, stdout: f.Stdout, stderr: f.Stderr, tree: f.Tree}
}

// TestOracleEndToEnd compares the legacy tools with the Go commands. With RSDD_UPDATE_GOLDENS=1 it also freezes the
// legacy outcomes (and the manifest spec the Go command hands to its tool) under testdata/goldens; otherwise it
// asserts the committed goldens still equal what the legacy tools do.
func TestOracleEndToEnd(t *testing.T) {
	hostReady(t)
	update := os.Getenv("RSDD_UPDATE_GOLDENS") == "1"
	sets := map[string]goldenSet{evidenceTool.name: {}, flowsTool.name: {}}
	var mu sync.Mutex
	if update {
		t.Cleanup(func() {
			if !t.Failed() {
				for name, g := range sets {
					g.write(t, "scenarios-"+name+".json")
				}
			}
		})
	}
	for _, sc := range scenarios() {
		for _, tl := range sc.tools {
			t.Run(tl.name+"/"+sc.name, func(t *testing.T) {
				t.Parallel()
				r := newRig(t)
				roots := map[string]string{}
				for _, who := range []string{"py", "go"} {
					dir, err := filepath.EvalSymlinks(t.TempDir())
					if err != nil {
						t.Fatal(err)
					}
					writePcap(t, filepath.Join(dir, "in.pcap"))
					roots[who] = dir
				}
				if sc.prep != nil {
					for _, who := range []string{"py", "go"} {
						sc.prep(r, roots[who])
					}
				}
				env := r.env(python(t), sc.env...)
				args := append([]string(nil), sc.args...)
				if sc.raw { // the scenario places --manifest-cli itself, as @MANIFEST@
					for i, a := range args {
						args[i] = strings.ReplaceAll(a, "@MANIFEST@", manifestCLI(t))
					}
				} else {
					args = append(args, "--manifest-cli", manifestCLI(t))
				}
				want := runLegacy(t, tl, roots["py"], sc.loose, env, args)
				got := runGo(t, tl, roots["go"], sc.loose, env, args)
				if sc.diverges != nil {
					sc.diverges(t, tl, want, got)
					return
				}
				report(t, want, got)
				f, _ := freeze(want, r.dir, sc.name, sc.loose)
				key := goldenKey(tl, sc)
				if update {
					_, f.Spec = replay(t, tl, sc)
					mu.Lock()
					sets[tl.name][key] = f
					mu.Unlock()
					return
				}
				g, ok := readGolden[frozen](t, "scenarios-"+tl.name+".json")[key]
				if !ok {
					t.Fatalf("no golden for %s", key)
				}
				report(t, asOutcome(g), asOutcome(f))
			})
		}
	}
}
