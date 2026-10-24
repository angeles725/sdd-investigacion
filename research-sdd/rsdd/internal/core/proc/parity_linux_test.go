//go:build linux

package proc

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strconv"
	"testing"
	"time"
)

// pyRun is the driver's JSON object.
type pyRun struct {
	OK       bool     `json:"ok"`
	Class    string   `json:"class"`
	Errors   []string `json:"errors"`
	ExitCode *int     `json:"exit_code"`
	Signal   *int     `json:"signal"`
	Stdout   []byte   `json:"stdout"`
	Stderr   []byte   `json:"stderr"`
}

const toolbeltDir = "../../../../toolbelt"

// runPy runs the real run_bounded through testdata/parity_driver.py. A
// missing python3 FAILS the test: a skipped parity test proves nothing.
func runPy(t *testing.T, timeoutS, maxBytes int, argv ...string) pyRun {
	t.Helper()
	py, err := exec.LookPath("python3")
	if err != nil {
		t.Fatalf("python3 is required for the parity tests and was not found: %v", err)
	}
	tb, err := filepath.Abs(toolbeltDir)
	if err != nil {
		t.Fatal(err)
	}
	args := append([]string{"-I", "testdata/parity_driver.py", tb, t.TempDir(), strconv.Itoa(timeoutS), strconv.Itoa(maxBytes)}, argv...)
	cmd := exec.Command(py, args...)
	var out, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &stderr
	if err := cmd.Run(); err != nil {
		t.Fatalf("driver failed: %v\n%s", err, stderr.String())
	}
	var r pyRun
	if err := json.Unmarshal(out.Bytes(), &r); err != nil {
		t.Fatalf("driver output %q: %v", out.String(), err)
	}
	return r
}

// returnCode rebuilds Popen's return code from the run record.
func (p pyRun) returnCode() int {
	if p.Signal != nil {
		return -*p.Signal
	}
	return *p.ExitCode
}

// Commands whose outcome is deterministic on both sides. In the capped cases
// the return code is not compared: run_bounded polls every 20 ms, so the
// child may exit before or after the stop, while the error list and the
// kept bytes are the same either way. The rlimit case pins the FSIZE
// preexec: the child's write past the cap gets SIGXFSZ (exit 153 from sh).
func TestParityRunBounded(t *testing.T) {
	cases := []struct {
		name     string
		timeoutS int
		max      int
		capped   bool
		argv     []string
	}{
		{"clean", 10, 1000, false, []string{"/bin/sh", "-c", "printf out; printf err >&2"}},
		{"exit code", 10, 1000, false, []string{"/bin/sh", "-c", "printf x; exit 3"}},
		{"signal", 10, 1000, false, []string{"/bin/sh", "-c", "kill -USR1 $$"}},
		{"path lookup", 10, 1000, false, []string{"echo", "found"}},
		{"under cap", 10, 100, false, []string{"head", "-c", "99", "/dev/zero"}},
		{"at cap", 10, 100, true, []string{"head", "-c", "100", "/dev/zero"}},
		{"joint cap", 10, 100, true, []string{"/bin/sh", "-c", "printf '%060d' 0; printf '%060d' 1 >&2"}},
		{"endless writer", 10, 4096, true, []string{"yes"}},
		{"fsize limit", 10, 100, false, []string{"/bin/sh", "-c", "head -c 200 /dev/zero > big; echo $?"}},
		{"timeout", 1, 1000, false, []string{"sleep", "30"}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			py := runPy(t, c.timeoutS, c.max, c.argv...)
			if !py.OK {
				t.Fatalf("run_bounded raised %s", py.Class)
			}
			got, err := Run(Spec{
				Argv: c.argv, Dir: t.TempDir(), Env: []string{testPath},
				Timeout: time.Duration(c.timeoutS) * time.Second, MaxBytes: c.max,
				Limits: []Limit{{"fsize", uint64(c.max)}}, Helper: os.Args[0],
			})
			if err != nil {
				t.Fatalf("Run: %v", err)
			}
			if !slices.Equal(got.Errors(), py.Errors) && len(got.Errors())+len(py.Errors) > 0 {
				t.Errorf("errors: python %q go %q", py.Errors, got.Errors())
			}
			if !bytes.Equal(got.Stdout, py.Stdout) || !bytes.Equal(got.Stderr, py.Stderr) {
				t.Errorf("output: python %q/%q go %q/%q", py.Stdout, py.Stderr, got.Stdout, got.Stderr)
			}
			if !c.capped && got.ReturnCode != py.returnCode() {
				t.Errorf("return code: python %d go %d", py.returnCode(), got.ReturnCode)
			}
		})
	}
}

func TestParityRunBoundedSpawnFailure(t *testing.T) {
	for _, argv0 := range []string{"no-such-program-2283", "/nonexistent/prog"} {
		py := runPy(t, 1, 10, argv0)
		_, err := Run(Spec{Argv: []string{argv0}, Dir: t.TempDir(), Env: []string{testPath}, Timeout: time.Second, MaxBytes: 10})
		var se *SpawnError
		if py.OK || py.Class != "FileNotFoundError" || !errors.As(err, &se) {
			t.Errorf("%s: python ok=%v class=%s, go %v; want both to fail to spawn", argv0, py.OK, py.Class, err)
		}
	}
}
