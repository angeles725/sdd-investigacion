//go:build unix && !nodiff

package gh

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"testing"
)

// Differential test: the REAL lib/gh-visibility.sh (testdata/gh-driver.sh) and core/gh must report the same
// return code and the same GHV_* fields - and, for gh_bounded_run, the same stdout and stderr - for the same stub
// gh, environment and bound. Both sides see one PATH: the stub gh plus links to the tools the lib needs and the
// real timeout(1), the bounder every Linux host uses. Bash runs under LC_ALL=C. Build tag nodiff drops this file
// for mutation runs (each case can cost a bound); `make check` always runs it. A missing bash, timeout or
// toolbelt FAILS: a skipped parity test proves nothing.
//
// Declared divergences (doc.go): Bound for GH_MISSING (the bash leaves its unvalidated default) is not compared;
// a TERM-ignoring gh under the probe is not run (`timeout` without -k would wait for it to finish); bash's own
// job notices ("Terminated", "<pid> Killed ...") are cut from the pass-through stderr, being the caller shell's
// and not gh's; a program the kernel cannot execute is not run (glibc execvp, inside timeout(1), retries it as a
// /bin/sh script, so the bash reports sh's 127 where core/proc reports env(1)'s 126).

const (
	toolbeltRel = "../../../../toolbelt"
	harnessRC   = 97
)

type dcase struct {
	name string
	mode string   // probe | run
	args []string // probe: repo; run: gh arguments
	env  []string
	bin  string // gh program; "" is the stub
	cwd  string // probe only
}

// diffBin is the shared PATH: the stub gh and links to what the bash lib runs.
func diffBin(t *testing.T) string {
	t.Helper()
	dir := fakeBin(t)
	for _, tool := range []string{"mktemp", "cat", "rm", "env", "sleep", "sed", "tr", "timeout"} {
		p, err := exec.LookPath(tool)
		if err != nil {
			t.Fatalf("%s is required for the differential test: %v", tool, err)
		}
		if err := os.Symlink(p, filepath.Join(dir, tool)); err != nil {
			t.Fatal(err)
		}
	}
	return dir
}

func runDriver(t *testing.T, c dcase, environ []string) string {
	t.Helper()
	bash, err := exec.LookPath("bash")
	if err != nil {
		t.Fatalf("bash is required for the differential test: %v", err)
	}
	tb, _ := filepath.Abs(toolbeltRel)
	driver, _ := filepath.Abs("testdata/gh-driver.sh")
	out := t.TempDir()
	argv := []string{driver, tb, out, c.mode, c.bin}
	if c.mode == "probe" && c.cwd != "" {
		argv = append(argv, c.args[0], c.cwd)
	} else {
		argv = append(argv, c.args...)
	}
	cmd := exec.Command(bash, argv...)
	cmd.Env = environ
	var stdout, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	if err := cmd.Run(); err != nil {
		var ee *exec.ExitError
		if !errors.As(err, &ee) || ee.ExitCode() == harnessRC {
			t.Fatalf("driver harness failure: %v: %s", err, stderr.String())
		}
	}
	return stdout.String() + streams(t, out)
}

// streams reads the pass-through output gh_bounded_run left in dir ("" for a probe).
func streams(t *testing.T, dir string) string {
	t.Helper()
	o, errO := os.ReadFile(filepath.Join(dir, "stdout"))
	e, errE := os.ReadFile(filepath.Join(dir, "stderr"))
	if errors.Is(errO, os.ErrNotExist) && errors.Is(errE, os.ErrNotExist) {
		return ""
	}
	return fmt.Sprintf("stdout=%s\nstderr=%s\n", o, jobNotice.ReplaceAll(e, nil))
}

// jobNotice is a bash job-status line about the bounded command (a declared divergence).
var jobNotice = regexp.MustCompile(`(?m)^(Terminated|.*: line [0-9]+: +[0-9]+ Killed +.*)\n`)

// runPort answers like the driver.
func runPort(t *testing.T, c dcase, environ []string) string {
	t.Helper()
	o := Options{Bin: c.bin, Env: environ, Dir: c.cwd, Knob: lookupOr(environ, "GHV_BOUND_ENV", "")}
	o.Default, _ = strconv.Atoi(lookupOr(environ, "GHV_BOUND_DEFAULT", lookupOr(environ, "GHV_DEFAULT_BOUND", "0")))
	if c.mode == "probe" {
		v, err := Probe(o, c.args[0])
		if err != nil {
			t.Fatal(err)
		}
		rc := 1
		if v.State.Decided() {
			rc = 0
		}
		return record(rc, v.State, v.RC, v.Why, v.Raw, v.Bound)
	}
	r, err := Run(o, c.args...)
	if err != nil {
		t.Fatal(err)
	}
	return record(r.RC, r.State, r.RC, "", "", r.Bound) + fmt.Sprintf("stdout=%s\nstderr=%s\n", r.Stdout, r.Stderr)
}

func record(rc int, s State, code int, why, raw string, b Bound) string {
	bad := 0
	if b.Bad {
		bad = 1
	}
	return fmt.Sprintf("rc=%d\nstate=%s\nRC=%d\nwhy=%s\nraw=%s\nbound=%d\nbad=%d\n", rc, s, code, why, raw, b.Seconds, bad)
}

func lookupOr(environ []string, key, dflt string) string {
	if v, ok := lookup(environ, key); ok {
		return v
	}
	return dflt
}

// unbounded hides the bound fields of a GH_MISSING record (a declared divergence).
func unbounded(rec string) string {
	if !strings.Contains(rec, "\nstate=GH_MISSING\n") {
		return rec
	}
	lines := strings.Split(rec, "\n")
	for i, l := range lines {
		if strings.HasPrefix(l, "bound=") || strings.HasPrefix(l, "bad=") {
			lines[i] = "<not compared>"
		}
	}
	return strings.Join(lines, "\n")
}

func TestDifferentialWithGhVisibility(t *testing.T) {
	repo := []string{"owner/repo"}
	cases := []dcase{
		{name: "public", mode: "probe", args: repo, env: []string{"GH_OUT=PUBLIC\n"}},
		{name: "private lower-case", mode: "probe", args: repo, env: []string{"GH_OUT=private\n\n"}},
		{name: "internal mixed case", mode: "probe", args: repo, env: []string{"GH_OUT=Internal"}},
		{name: "error printing PRIVATE", mode: "probe", args: repo, env: []string{"GH_OUT=PRIVATE", "GH_RC=1", "GH_ERR=HTTP 401: bad\nmore"}},
		{name: "unrecognised", mode: "probe", args: repo, env: []string{"GH_OUT=weird"}},
		{name: "empty answer", mode: "probe", args: repo},
		{name: "inner newline", mode: "probe", args: repo, env: []string{"GH_OUT=PRIVATE\nX"}},
		{name: "non-ASCII", mode: "probe", args: repo, env: []string{"GH_OUT=prïvate"}},
		{name: "NUL byte", mode: "probe", args: repo, env: []string{`GH_OUT=PUB\0LIC`}},
		{name: "blank first stderr line", mode: "probe", args: repo, env: []string{"GH_RC=4", "GH_ERR=\nsecond"}},
		{name: "probe missing gh", mode: "probe", args: repo, bin: "gh-absent", env: []string{"GHV_DEFAULT_BOUND=10"}},
		{name: "probe missing cwd", mode: "probe", args: repo, cwd: "/nonexistent-rsdd-dir", env: []string{"GH_OUT=PUBLIC"}},
		{name: "probe exit 124", mode: "probe", args: repo, env: []string{"GH_RC=124"}},
		{name: "probe KILLed gh", mode: "probe", args: repo, env: []string{"GH_SELFKILL=KILL"}},
		{name: "probe TERMed gh", mode: "probe", args: repo, env: []string{"GH_SELFKILL=TERM"}},
		{name: "bound 007", mode: "probe", args: repo, env: []string{"GH_OUT=PUBLIC", "RSDD_GH_TIMEOUT=007"}},
		{name: "bound garbage", mode: "probe", args: repo, env: []string{"GH_OUT=PUBLIC", "RSDD_GH_TIMEOUT=abc"}},
		{name: "bound empty", mode: "probe", args: repo, env: []string{"GH_OUT=PUBLIC", "RSDD_GH_TIMEOUT="}},
		{name: "bound zeros", mode: "probe", args: repo, env: []string{"GH_OUT=PUBLIC", "RSDD_GH_TIMEOUT=000"}},
		{name: "bound ten digits", mode: "probe", args: repo, env: []string{"GH_OUT=PUBLIC", "RSDD_GH_TIMEOUT=1234567890"}},
		{name: "bound padded nine", mode: "probe", args: repo, env: []string{"GH_OUT=PUBLIC", "RSDD_GH_TIMEOUT=0000000005"}},
		{name: "caller default", mode: "probe", args: repo, env: []string{"GH_OUT=PUBLIC", "GHV_DEFAULT_BOUND=10", "RSDD_GH_TIMEOUT=-5"}},
		{name: "probe timeout", mode: "probe", args: repo, env: []string{"RSDD_GH_TIMEOUT=1", "GH_SLEEP=30", "GH_OUT=PRIVATE"}},
		{name: "run success", mode: "run", args: []string{"repo", "create", "o/r"}, env: []string{"GH_OUT=made\n", "GH_ERR=note\n"}},
		{name: "run failure", mode: "run", args: []string{"repo", "edit"}, env: []string{"GH_RC=3", "GH_ERR=boom"}},
		{name: "run missing gh", mode: "run", bin: "gh-absent"},
		{name: "run exit 124", mode: "run", env: []string{"GH_RC=124"}},
		{name: "run KILLed gh", mode: "run", env: []string{"GH_SELFKILL=KILL"}},
		{name: "run TERMed gh", mode: "run", env: []string{"GH_SELFKILL=TERM"}},
		{name: "run own knob", mode: "run", env: []string{"GHV_BOUND_ENV=K", "GHV_BOUND_DEFAULT=60", "K=x", "RSDD_GH_TIMEOUT=3"}},
		{name: "run own knob value", mode: "run", env: []string{"GHV_BOUND_ENV=K", "GHV_BOUND_DEFAULT=60", "K=7"}},
		{name: "run timeout", mode: "run", env: []string{"RSDD_GH_TIMEOUT=1", "GH_SLEEP=30"}},
		{name: "run TERM-ignoring timeout", mode: "run", env: []string{"RSDD_GH_TIMEOUT=1", "GH_SLEEP=30", "GH_IGNORE_TERM=1"}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			t.Parallel()
			environ := append([]string{"LC_ALL=C", "PATH=" + diffBin(t)}, c.env...)
			if c.bin == "" {
				c.bin = "gh"
			}
			bash, port := unbounded(runDriver(t, c, environ)), unbounded(runPort(t, c, environ))
			if bash != port {
				t.Fatalf("bash:\n%s\ngo:\n%s", bash, port)
			}
		})
	}
}
