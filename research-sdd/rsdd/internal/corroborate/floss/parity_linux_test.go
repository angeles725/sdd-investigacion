//go:build linux && !nodiff

package floss

// The differential half of the floss tests: the frozen legacy script (testdata/legacy/corroborate_floss.py) is
// the oracle, run by Python 3.12 (its argparse and json messages are what the port reproduces). The slow
// tests, so `make teeth` (-tags nodiff) leaves them out; the unit tests carry the mutation kills.

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

const legacyScript = "testdata/legacy/corroborate_floss.py"

// oraclePython is the Python 3.12 interpreter that runs the legacy script.
func oraclePython(t *testing.T) string {
	t.Helper()
	for _, name := range []string{"python3.12", "python3"} {
		py, err := exec.LookPath(name)
		if err != nil {
			continue
		}
		out, err := exec.Command(py, "-I", "-c", "import sys; print('%d.%d' % sys.version_info[:2])").Output()
		if err == nil && strings.TrimSpace(string(out)) == "3.12" {
			return py
		}
	}
	skipOrFail(t, "the oracle needs Python 3.12 (python3.12 on PATH)")
	return ""
}

func absPath(t *testing.T, rel string) string {
	t.Helper()
	p, err := filepath.Abs(rel)
	must(t, err)
	return p
}

// pyRun runs an inline Python program in isolated mode with args, feeding stdin.
func pyRun(t *testing.T, py, program, stdin string, env []string, args ...string) (stdout, stderr string, code int) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()
	cmd := exec.CommandContext(ctx, py, append([]string{"-I", "-c", program}, args...)...)
	var o, e bytes.Buffer
	cmd.Stdin, cmd.Stdout, cmd.Stderr, cmd.Env = strings.NewReader(stdin), &o, &e, env
	err := cmd.Run()
	if ee, ok := err.(*exec.ExitError); ok {
		code = ee.ExitCode()
	} else if err != nil {
		t.Fatalf("python: %v", err)
	}
	return o.String(), e.String(), code
}

// ---------------------------------------------------------------- argparse

const argparseProgram = `
import contextlib, importlib.util, io, json, os, sys
toolbelt, legacy = sys.argv[1], sys.argv[2]
sys.path.insert(0, toolbelt)
spec = importlib.util.spec_from_file_location("legacy_floss", legacy)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
out = []
for case in json.load(sys.stdin):
    os.environ["COLUMNS"] = str(case["columns"])
    o, e = io.StringIO(), io.StringIO()
    res = {}
    try:
        with contextlib.redirect_stdout(o), contextlib.redirect_stderr(e):
            ns = m._parser().parse_args(case["args"])
        res["ns"] = {"input": str(ns.input), "output": str(ns.output), "manifest_cli": str(ns.manifest_cli),
                     "timeout": str(ns.timeout), "max_strings": str(ns.max_strings), "max_string_len": str(ns.max_string_len)}
        res["code"] = 0
    except SystemExit as x:
        res["code"] = x.code
    res["out"], res["err"] = o.getvalue(), e.getvalue()
    out.append(res)
json.dump(out, sys.stdout)
`

func TestParityArgparse(t *testing.T) {
	py := oraclePython(t)
	cases := argparseCorpus()
	in, _ := json.Marshal(cases)
	stdout, stderr, code := pyRun(t, py, argparseProgram, string(in), os.Environ(), absPath(t, "../../core/adapter/testdata/frozen"), absPath(t, legacyScript))
	if code != 0 {
		t.Fatalf("oracle: %s", stderr)
	}
	var want []argResult
	must(t, json.Unmarshal([]byte(stdout), &want))
	syncGoldens(t, argparseGolden, &want)
	checkArgs(t, cases, want)
}

// ---------------------------------------------------------------- JSON decoding

const jsonProgram = `
import json, sys
out = []
for h in json.load(sys.stdin):
    raw = bytes.fromhex(h)
    try:
        v = json.loads(raw)
        out.append({"ok": json.dumps(v, sort_keys=True, separators=(",", ":"), allow_nan=False) + "\n"})
    except json.JSONDecodeError as e:
        out.append({"err": str(e)})
    except ValueError as e:
        out.append({"exc": type(e).__name__})
    except Exception as e:
        out.append({"exc": type(e).__name__})
json.dump(out, sys.stdout)
`

func TestParityJSONDecode(t *testing.T) {
	py := oraclePython(t)
	corpus := jsonCorpus()
	hexes := make([]string, len(corpus))
	for i, b := range corpus {
		hexes[i] = fmt.Sprintf("%x", b)
	}
	in, _ := json.Marshal(hexes)
	stdout, stderr, code := pyRun(t, py, jsonProgram, string(in), nil)
	if code != 0 {
		t.Fatalf("oracle: %s", stderr)
	}
	var want []jsonResult
	must(t, json.Unmarshal([]byte(stdout), &want))
	syncGoldens(t, jsonGolden, &want)
	checkJSON(t, corpus, want)
}

// syncGoldens rewrites the golden from the oracle's output under RSDD_UPDATE_GOLDENS=1, and otherwise asserts
// the committed golden equals what the oracle just produced (the replay in golden_test.go is then trustworthy).
func syncGoldens(t *testing.T, path string, oracle any) {
	t.Helper()
	if os.Getenv("RSDD_UPDATE_GOLDENS") == "1" {
		writeGolden(t, path, oracle)
		return
	}
	got := reflect.New(reflect.TypeOf(oracle).Elem()).Interface()
	readGolden(t, path, got)
	if !reflect.DeepEqual(got, oracle) {
		t.Errorf("%s differs from the oracle: regenerate with RSDD_UPDATE_GOLDENS=1", path)
	}
}
