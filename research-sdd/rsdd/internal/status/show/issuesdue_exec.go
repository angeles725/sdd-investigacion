package show

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/gh"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/issuesdue"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/kit"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/proc"
)

// The subprocesses of the --next terminal, each behind a variable a test replaces. The port can start exactly
// these, and no others:
//
//	gh issue list ...            the one batch prefetch of the open issue bodies (core/gh, bounded)
//	rsdd retro reconcile ...     one re-verify per retro the batch reports untracked rows for, and every probe when
//	                             there is no batch cache (this binary, bounded)
//	bash clean-check.sh ...      the terminal no-garbage check of an exhausted STOP (bounded)
//
// The probe of a retro against the batch cache is not a subprocess: dueRun answers it in process through
// core/issuesdue, the code `rsdd retro reconcile --issues-cache` itself runs (kit issue #2644), so a status run
// pays no process start per probed retro.
//
// The script ran timeout(1)/gtimeout around gh and reconcile-issues.sh; the bound is core/proc's here, so the
// "no timeout binary" states of the script do not exist. The script ran reconcile-issues.sh through bash and the
// shim; the port runs this binary directly, so a status run pays no extra bash start and shim resolution.
var (
	ghList          = gh.Run
	dueRun          = inprocDue
	reconcileRun    = execReconcile
	reconcilePrefix = defaultReconcilePrefix
	cleanCheckRun   = execCleanCheck
)

// execMaxBytes caps the joint output of a probe, as core/gh does for gh.
const execMaxBytes = gh.DefaultMaxBytes

// probeResult is what a bounded child answered: its stdout and stderr and the exit code the shell would report
// (124 when the bound fired, 128+N for a signal, 127 when it could not be started).
type probeResult struct {
	out, err string
	rc       int
}

// inprocDue is the probe of retro against the batch cache file: the answer of `rsdd retro reconcile [--toolbelt dir]
// --issues-cache cache retro`, computed here. A stop the command exits 1 on is rc 1 with its stderr; a marker out of
// scope is rc 0 with that line on stderr; otherwise rc 0 with one `untracked:` line per open row no issue tracks (the
// gate counts those lines, nothing else of the command's stdout).
func inprocDue(retro, cache string, s cli.Stdio) probeResult {
	r := issuesdue.Probe(issuesdue.Query{Retro: retro, Cache: cache, Toolbelt: s.Env("RSDD_TOOLBELT_DIR"), Cwd: s.Cwd, Env: s.Env})
	switch {
	case r.Failure != "":
		return probeResult{err: r.Failure + "\n", rc: 1}
	case r.OutOfScope != "":
		return probeResult{err: r.OutOfScope + "\n"}
	}
	var out strings.Builder
	for _, id := range r.Untracked {
		out.WriteString("untracked: row " + id + "\n")
	}
	return probeResult{out: out.String()}
}

// defaultReconcilePrefix is the command that runs `retro reconcile` for the toolbelt the status script lives in:
// this binary, as reconcile-issues.sh's own shim runs it (`rsdd retro reconcile --toolbelt <dir>`). Without
// RSDD_TOOLBELT_DIR the command resolves the kit itself.
func defaultReconcilePrefix(toolbelt string, self func() (string, error)) ([]string, error) {
	exe, err := self()
	if err != nil {
		return nil, err
	}
	argv := []string{exe, "retro", "reconcile"}
	if toolbelt != "" {
		argv = append(argv, "--toolbelt", toolbelt)
	}
	return argv, nil
}

// execReconcile runs `rsdd retro reconcile [--toolbelt dir] args...` from the caller's working directory, bounded
// by timeout. The child is a Go binary, not a shim, but it gets the same environment a shim would (kit.ShimEnv).
func execReconcile(args []string, timeout time.Duration, s cli.Stdio) probeResult {
	prefix, err := reconcilePrefix(s.Env("RSDD_TOOLBELT_DIR"), os.Executable)
	if err != nil {
		return probeResult{err: "cannot locate the rsdd binary: " + err.Error(), rc: 127}
	}
	return boundedRun(append(prefix, args...), timeout, 0, s)
}

// execCleanCheck runs `bash script --target dir` bounded by timeout, with the 5 s kill grace of `timeout -k 5`.
func execCleanCheck(script, target string, timeout time.Duration, s cli.Stdio) probeResult {
	return boundedRun([]string{"bash", script, "--target", target}, timeout, cleanCheckGrace, s)
}

// boundedRun is core/proc over argv in the caller's directory and environment.
func boundedRun(argv []string, timeout, grace time.Duration, s cli.Stdio) probeResult {
	var env []string
	if environ := s.Environment(); environ != nil {
		env = kit.ShimEnv(environ, os.Executable)
	}
	res, err := proc.Run(proc.Spec{Argv: argv, Dir: s.Cwd, Env: env, Timeout: timeout, MaxBytes: execMaxBytes, Grace: grace, Now: s.Clock})
	var spawn *proc.SpawnError
	switch {
	case errors.As(err, &spawn):
		return probeResult{err: spawn.Error(), rc: 127}
	case err != nil:
		return probeResult{err: err.Error(), rc: 1}
	}
	return probeResult{out: string(res.Stdout), err: string(res.Stderr), rc: shellRC(res)}
}

// shellRC is the exit code a shell reports for res.
func shellRC(res proc.Result) int {
	switch {
	case res.Reason == proc.ReasonTimeout:
		return 124
	case res.ReturnCode < 0:
		return 128 - res.ReturnCode
	}
	return res.ReturnCode
}

// toolbeltDir is the directory the status script lived in: RSDD_TOOLBELT_DIR, which the shim hands over.
func (c *ctx) toolbeltDir() string { return c.s.Env("RSDD_TOOLBELT_DIR") }

// toolbeltFile is "$here/<name>" when the toolbelt is known.
func (c *ctx) toolbeltFile(name string) (string, bool) {
	dir := c.toolbeltDir()
	if dir == "" {
		return "", false
	}
	return filepath.Join(dir, name), true
}

// ghOptions is the gh call of the batch prefetch: the caller's environment and working directory, the bound of
// _IDG_RECONCILE_TIMEOUT_SECS (default 15 s, as the per-retro probes).
func (c *ctx) ghOptions() gh.Options {
	return gh.Options{Env: c.s.Environment(), Dir: c.s.Cwd, Knob: "_IDG_RECONCILE_TIMEOUT_SECS", Default: idgDefaultTimeout, Now: c.s.Clock}
}

// shellExit is the "exit N" a failed gh call is reported with: the shell code, never 0 for a failure.
func shellExit(r gh.RunResult, err error) int {
	switch {
	case err != nil:
		return 1
	case r.RC != 0:
		return r.RC
	}
	return 1
}
