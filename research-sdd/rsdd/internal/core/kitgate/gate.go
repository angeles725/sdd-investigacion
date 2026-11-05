// Package kitgate is toolbelt/maint/kit-gate.sh in process (kit issue #2212, Go port): ONE serial full gate under a
// flock on <state>/gate.lock, its output in <state>/gate-<label>.log, the summary lines echoed. `rsdd maint gate` and
// the merge train (`rsdd gate merge-train`) both run it.
package kitgate

import (
	"fmt"
	"io"
	"os"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/kitmaint"
)

// Tool is the prefix of every line kit-gate prints.
const Tool = "kit-gate"

// The gate commands kit-gate runs with `bash -c` inside the worktree.
const (
	DefaultCmd = "bash research-sdd/toolbelt/tests/run-all.sh -j 4 --prove-teeth"
	SerialCmd  = "bash research-sdd/toolbelt/tests/run-all.sh --prove-teeth"
)

// Typed exit states of kit-gate.
const (
	ExitPassed      = 0
	ExitUsage       = 2
	ExitDegraded    = 3
	ExitGateFailed  = 16
	ExitLockTimeout = 22
)

// Opts is one gate run. Cmd (when set) wins over Serial; LockTimeout is the raw text of --lock-timeout /
// KIT_GATE_LOCK_TIMEOUT ("" is the default 14400 seconds).
type Opts struct {
	Out         io.Writer
	R           *kitmaint.Runner
	Wt, Label   string
	State       string
	Cmd         string
	Serial      bool
	LockTimeout string
	// Probe runs after the worktree is known to exist (kit_probe_deps flock git): false ends the run with the
	// degraded exit, the probe having printed its own line.
	Probe func() bool
	// SilentNoBash leaves out the `kit-gate: degraded: missing runtime dependency: bash` line (exit 3 either way): the
	// merge train never probed for bash and never printed one.
	SilentNoBash bool
	// OverflowTriesOnce reads a lock timeout too long for an int as 0 seconds (one try), as the merge train always
	// did; by default such a timeout waits as long as a lock can be waited for (see lockSeconds).
	OverflowTriesOnce bool
	// Sig delivers INT/TERM: the first one is forwarded to the gate's process group (nil: never).
	Sig <-chan os.Signal
}

// Result is the typed exit code plus the gate command's own rc (only for ExitGateFailed) and whether a signal ended
// the run, in which case the bash tool died with no `gate rc=` line and no summary.
type Result struct {
	Code, GateRC int
	Interrupted  bool
}

func (o *Opts) say(format string, a ...any) {
	fmt.Fprintf(o.Out, "%s: %s\n", Tool, fmt.Sprintf(format, a...))
}

func usage(o *Opts, format string, a ...any) Result {
	o.say("usage: "+format, a...)
	return Result{Code: ExitUsage}
}

// Run is kit-gate.sh from the lock-timeout check on; the caller has already validated its own arguments.
func Run(o Opts) Result {
	lockTimeout := o.LockTimeout
	if lockTimeout == "" {
		lockTimeout = DefaultLockTimeout
	}
	if !ValidLockTimeout(lockTimeout) {
		return usage(&o, MsgBadLockTimeout)
	}
	cmd := o.Cmd
	switch {
	case cmd != "":
	case o.Serial:
		cmd = SerialCmd
	default:
		cmd = DefaultCmd
	}
	cwd := o.R.Cwd
	if !kitmaint.IsDir(kitmaint.Abs(cwd, o.Wt)) {
		return usage(&o, "worktree is not a directory: %s", o.Wt)
	}
	if o.Probe != nil && !o.Probe() {
		return Result{Code: ExitDegraded}
	}
	wtPhys, err := kitmaint.ResolveDir(cwd, o.Wt)
	if err != nil {
		return usage(&o, "cannot resolve the worktree")
	}
	state, err := kitmaint.PhysPath(cwd, o.State)
	if err != nil {
		return usage(&o, "cannot resolve --state-dir %s", o.State)
	}
	if kitmaint.Inside(state, wtPhys) {
		return usage(&o, "--state-dir %s is inside the worktree; state never lives in the repo", state)
	}
	if err := os.MkdirAll(state, 0o777); err != nil {
		return usage(&o, "cannot create state dir %s", state)
	}
	lock, err := os.OpenFile(state+"/gate.lock", os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o666)
	if err != nil {
		return usage(&o, "cannot open the gate lock")
	}
	defer lock.Close()
	if !kitmaint.Flock(lock, lockSeconds(lockTimeout, o.OverflowTriesOnce), o.R.Sleep) {
		o.say("gate-lock-timeout: could not take %s/gate.lock within %ss", state, lockTimeout)
		return Result{Code: ExitLockTimeout}
	}
	return runLocked(&o, cmd, wtPhys, state, lock)
}

// runLocked runs the gate command with the lock held and writes the log and the echoed summary.
func runLocked(o *Opts, cmd, wtPhys, state string, lock *os.File) Result {
	log := state + "/gate-" + o.Label + ".log"
	short := strings.TrimRight(o.R.Git(wtPhys, "rev-parse", "--short", "HEAD").Out, "\n")
	if err := os.WriteFile(log, []byte("head "+short+"\n"), 0o666); err != nil {
		return usage(o, "cannot write %s", log)
	}
	rc, interrupted, fail := execGate(o, cmd, wtPhys, log, lock)
	if fail != 0 {
		return Result{Code: fail}
	}
	if interrupted {
		return Result{Code: ExitGateFailed, GateRC: rc, Interrupted: true}
	}
	appendLine(log, fmt.Sprintf("gate rc=%d\n", rc))
	writeSummary(o.Out, log)
	o.say("gate rc=%d log=%s", rc, log)
	if rc != 0 {
		return Result{Code: ExitGateFailed, GateRC: rc}
	}
	return Result{Code: ExitPassed}
}

func appendLine(path, line string) {
	if f, err := os.OpenFile(path, os.O_WRONLY|os.O_APPEND, 0); err == nil {
		_, _ = f.WriteString(line)
		f.Close()
	}
}
