package decompile

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/proc"
)

// maxOutput caps one program's combined stdout and stderr (a variable only so a test can lower it).
var maxOutput = 64 << 20

// unbounded stands for "no bound": proc needs a positive timeout, so an engine run with --timeout 0 gets a year.
const unbounded = 365 * 24 * time.Hour

const (
	statusTimeout = 124 // what timeout(1) reports for a run it stopped
	statusKilled  = 137 // 128+SIGKILL: the run ignored TERM and was killed after the grace
	statusSpawn   = 127 // the program could not be started
	sigKill       = 9
)

// Cmd is one external program run. Timeout 0 means unbounded.
type Cmd struct {
	Argv    []string
	Dir     string
	Env     []string
	Timeout time.Duration
	Grace   time.Duration // the wait between TERM and KILL
}

// Result is what a run produced: the exit status as the shell would have seen it, and both streams.
type Result struct {
	RC             int
	Stdout, Stderr []byte
}

// runner runs one external program.
type runner func(Cmd) Result

// newProcRunner is the production runner over core/proc (injected so a test can see the Spec and feed Results).
func newProcRunner(run func(proc.Spec) (proc.Result, error)) runner {
	return func(c Cmd) Result {
		timeout := c.Timeout
		if timeout == 0 {
			timeout = unbounded
		}
		res, err := run(proc.Spec{Argv: c.Argv, Dir: c.Dir, Env: c.Env, Timeout: timeout, MaxBytes: maxOutput, Grace: c.Grace})
		var spawn *proc.SpawnError
		if errors.As(err, &spawn) || errors.Is(err, proc.ErrInvalidSpec) {
			return Result{RC: statusSpawn, Stderr: []byte(err.Error() + "\n")}
		}
		return Result{RC: exitStatus(res), Stdout: res.Stdout, Stderr: res.Stderr}
	}
}

// exitStatus maps a proc result to the status timeout(1) --kill-after would have given the shell: a stopped run
// is 124, or 137 when only the KILL ended it; any other signal N is 128+N; a run cut at the output cap never
// reads as success.
func exitStatus(res proc.Result) int {
	rc := res.ReturnCode
	switch {
	case res.Reason == proc.ReasonTimeout && rc == -sigKill:
		return statusKilled
	case res.Reason == proc.ReasonTimeout:
		return statusTimeout
	case rc < 0:
		return 128 - rc
	case res.Reason == proc.ReasonOutputCap && rc == 0:
		return 1
	}
	return rc
}

// reasonOf is the typed cause of a non-zero engine exit.
func reasonOf(rc int) string {
	switch rc {
	case statusTimeout:
		return "timeout"
	case statusKilled:
		return "killed"
	}
	return "error"
}

// engineJar is the jar of engine e: the --jar override applies to the PRIMARY engine only.
func (j *job) engineJar(e string) (string, error) {
	if j.cfg.jarOverride != "" && e == j.cfg.engine {
		return j.cfg.jarOverride, nil
	}
	return j.d.tools.JavaJar(e)
}

// engineArgv is the command line of engine e on input in, writing to out.
func (j *job) engineArgv(e, jar, in, out string) []string {
	argv := append([]string{j.java}, j.cfg.javaArgs...)
	argv = append(argv, "-jar", jar)
	switch e {
	case "vineflower":
		if j.cfg.threadCount != "" {
			argv = append(argv, "--thread-count="+j.cfg.threadCount)
		}
		return append(argv, in, out)
	case "cfr":
		return append(argv, in, "--outputdir", out)
	}
	if strings.HasSuffix(strings.ToLower(in), ".jar") { // procyon
		return append(argv, "-jar", in, "-o", out)
	}
	return append(argv, "-o", out, in)
}

// runEngine is one bounded engine invocation. rc: 0 ok, 124 timeout, 137 killed, 3 engine jar unavailable, else
// the engine's exit code. The engine's own output is passed through.
func (j *job) runEngine(e, in, out string) int {
	jar, _ := j.engineJar(e) // an unresolvable jar is ""
	if !isFile(j.path(jar)) {
		return 3
	}
	j.must(os.MkdirAll(j.path(out), 0o755))
	t := j.cfg.timeout
	// During isolation the run is also capped at the REMAINING isolation budget: the budget bounds a unit's
	// engine run and the sweep, not just the gaps between units.
	if j.isolating && j.cfg.isolateBudget > 0 && j.haveTimeout {
		rem := max(j.cfg.isolateBudget-j.elapsed(), 1)
		t = rem
		if j.cfg.timeout > 0 {
			t = min(t, j.cfg.timeout)
		}
	}
	cmd := Cmd{Argv: j.engineArgv(e, jar, in, out), Dir: j.s.Cwd, Env: j.s.Environ()}
	if t > 0 {
		cmd.Timeout, cmd.Grace = time.Duration(t)*time.Second, time.Duration(j.cfg.killAfter)*time.Second
	}
	res := j.d.run(cmd)
	_, _ = j.s.Out.Write(res.Stdout)
	_, _ = j.s.Err.Write(res.Stderr)
	return res.RC
}

// elapsed is the whole seconds since the isolation phase began.
func (j *job) elapsed() int { return int(j.s.Clock().Sub(j.isoT0) / time.Second) }

// budgetExhausted: the isolation time budget is spent.
func (j *job) budgetExhausted() bool {
	return j.cfg.isolateBudget > 0 && j.elapsed() >= j.cfg.isolateBudget
}

// canonical is canonical_launcher: the launcher with symlinks resolved, a regular executable file.
func canonical(launcher string) (string, bool) {
	resolved, err := filepath.EvalSymlinks(launcher)
	if err != nil {
		return "", false
	}
	fi, err := os.Stat(resolved)
	if err != nil || !fi.Mode().IsRegular() || fi.Mode().Perm()&0o111 == 0 {
		return "", false
	}
	return resolved, true
}
