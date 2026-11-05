// Package gate is `rsdd maint gate`, the port of toolbelt/maint/kit-gate.sh (kit issue #2212, Go port): ONE serial
// full gate under a flock, its output in a log, the summary lines echoed. The run itself lives in core/kitgate,
// shared with the merge train; this package owns the command line, the help text and the dependency probe.
//
// Intended divergences from the bash, each pinned by a test and listed in tool-registry.d/kit-pr-pipeline.md:
//   - the lock is taken in process (syscall flock), not by the flock binary; flock stays a probed dependency;
//   - a degraded exit 3 also writes `DEGRADED: <why>` to stderr (the rsdd process contract);
//   - a signal is forwarded to the gate's process group and ends the run with `kit-gate: interrupted` and exit 16;
//   - `--lock-timeout` of a number too large for an int waits as long as it can, not not at all;
//   - rsdd buffers stdout until the command returns, so the typed lines appear at the end.
package gate

import (
	_ "embed"
	"fmt"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/kitgate"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/kitmaint"
)

//go:embed help.txt
var help string

// deps is what the command takes from outside: the INT/TERM source and sleeping. Tests replace them.
type deps struct {
	notify func() (<-chan os.Signal, func())
	sleep  func(time.Duration)
}

// Run is `rsdd maint gate`.
func Run(args []string, s cli.Stdio) int {
	return run(args, s, deps{sleep: time.Sleep, notify: func() (<-chan os.Signal, func()) {
		ch := make(chan os.Signal, 4)
		signal.Notify(ch, syscall.SIGINT, syscall.SIGTERM)
		return ch, func() { signal.Stop(ch) }
	}})
}

func run(args []string, s cli.Stdio, d deps) int {
	o, err := parse(args, s.Env("KIT_GATE_LOCK_TIMEOUT"))
	if err != nil {
		fmt.Fprintf(s.Out, "%s: usage: %s\n", kitgate.Tool, err)
		return cli.ExitUsage
	}
	if o.help {
		fmt.Fprint(s.Out, help)
		return cli.ExitOK
	}
	state := o.state
	if state == "" {
		state = kitmaint.StateDir(s.Env)
	}
	cmd := o.cmd
	if o.cmdGiven && cmd == "" {
		cmd = ":" // `--cmd ''` runs nothing and passes, as bash -c '' did; the engine reads "" as "the default gate"
	}
	var sig <-chan os.Signal
	if d.notify != nil {
		var stop func()
		sig, stop = d.notify()
		defer stop()
	}
	env := s.Environ()
	runner := &kitmaint.Runner{Env: env, Cwd: s.Cwd, Now: s.Clock, Err: s.Err, Getenv: s.Env, Sleep: d.sleep}
	probe := func() bool { return kitmaint.ProbeDeps(s.Out, s.Err, kitgate.Tool, env, s.Cwd, "flock", "git") }
	res := kitgate.Run(kitgate.Opts{
		Out: s.Out, R: runner, Wt: o.wt, Label: o.label, State: state, Cmd: cmd, Serial: o.serial,
		LockTimeout: o.lockTimeout, Probe: probe, Sig: sig,
	})
	if res.Interrupted {
		fmt.Fprintf(s.Out, "%s: interrupted: the gate was stopped by a signal\n", kitgate.Tool)
	}
	return res.Code
}
