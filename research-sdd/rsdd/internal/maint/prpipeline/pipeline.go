// Package prpipeline is `rsdd maint pr-pipeline`, the port of toolbelt/maint/kit-pr-pipeline.sh (kit issue #2212, Go
// port): restack onto the base, push, run the size-check hook, the native review (RDD), ONE serial gate under a
// flock, then wait for CI and merge. Every step runs in process: the gate and the merge wait are the shared engines of
// core/kitgate and core/kitwait, and the review steps are the rdd-start and rdd-drive commands of the parent package,
// injected by the caller (a sub-package cannot import its parent).
//
// Intended divergences from the bash, each pinned by a test and listed in tool-registry.d/kit-pr-pipeline.md:
//   - python3 is no longer a probed dependency (nothing in the pipeline runs it any more);
//   - the default merge gate is the rsdd binary's own `gate merge` (KIT_MERGE_GATE still names a script);
//   - a failing `git status` is a typed restack-error (25) instead of being read as a clean tree;
//   - a degraded exit 3 also writes `DEGRADED: <why>` to stderr (the rsdd process contract);
//   - the gate's lock is taken in process, so no `flock` child runs (flock is still a probed dependency);
//   - rsdd buffers stdout until the command returns;
//   - a signal during the gate is forwarded to the gate's process group and ends the run with `interrupted`, exit 16;
//   - a non-numeric KIT_POLL_MAX, KIT_POLL_SLEEP, KIT_MERGE_TRIES, KIT_MERGE_SLEEP or KIT_RETRY_SLEEP is a usage error
//     before anything runs (the bash read it as 0 and skipped the CI wait);
//   - the review output lines are cut at 300 characters, never inside a character (the bash `cut -c` counted bytes).
package prpipeline

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
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/kitwait"
)

const tool = "kit-pr-pipeline"

//go:embed help.txt
var help string

// Step is an injected command (rdd-start, rdd-drive): the Run contract of a cli.Command.
type Step func(args []string, s cli.Stdio) int

// deps is what the command takes from outside; tests replace the sleeper and the binary path.
type deps struct {
	start, drive Step
	sleep        func(time.Duration)
	self         string
	notify       func() (<-chan os.Signal, func()) // INT/TERM source for the gate step (nil: none)
}

// New is the command: start and drive are the review steps of the maint domain.
func New(start, drive Step) func([]string, cli.Stdio) int {
	return func(args []string, s cli.Stdio) int {
		return run(args, s, deps{start: start, drive: drive, sleep: time.Sleep, self: kitwait.Self(),
			notify: func() (<-chan os.Signal, func()) {
				ch := make(chan os.Signal, 4)
				signal.Notify(ch, syscall.SIGINT, syscall.SIGTERM)
				return ch, func() { signal.Stop(ch) }
			}})
	}
}

// pipeline is one run.
type pipeline struct {
	o         options
	s         cli.Stdio
	env       []string
	kr        *kitmaint.Runner
	wt, state string
	d         deps
}

func (p *pipeline) start(args []string, s cli.Stdio) int    { return p.d.start(args, s) }
func (p *pipeline) driveRDD(args []string, s cli.Stdio) int { return p.d.drive(args, s) }

func run(args []string, s cli.Stdio, d deps) int {
	o, err := parse(args)
	if err != nil {
		fmt.Fprintf(s.Out, "%s: usage: %s\n", tool, err)
		return cli.ExitUsage
	}
	if o.help {
		fmt.Fprint(s.Out, help)
		return cli.ExitOK
	}
	if bad := kitwait.BadKnob(s.Env); bad != "" {
		fmt.Fprintf(s.Out, "%s: usage: %s must be a whole number: %s\n", tool, bad, s.Env(bad))
		return cli.ExitUsage
	}
	p := &pipeline{o: o, s: s, env: s.Environ(), d: d}
	if code, stop := p.prepare(); stop {
		return code
	}
	if o.dryRun {
		p.printPlan()
		return cli.ExitOK
	}
	if err := os.MkdirAll(p.state, 0o777); err != nil {
		return p.fail(cli.ExitUsage, "usage", "cannot create state dir %s", p.state)
	}
	p.kr = &kitmaint.Runner{Env: p.env, Cwd: p.wt, Now: s.Clock, Err: s.Err, Getenv: s.Env, Sleep: d.sleep}
	for _, step := range []func() (int, bool){p.restack, p.push, p.sizeCheck, p.rdd, p.gate} {
		if code, stop := step(); stop {
			return code
		}
	}
	return p.wait()
}

// prepare resolves the worktree and the state dir and probes the dependencies, in the order of the bash tool.
func (p *pipeline) prepare() (int, bool) {
	o, s := p.o, p.s
	wt := kitmaint.Abs(s.Cwd, o.wt)
	if !kitmaint.IsDir(wt) {
		return p.usage("worktree is not a directory: %s", o.wt), true
	}
	phys, err := kitmaint.ResolveDir(s.Cwd, o.wt)
	if err != nil {
		return p.usage("cannot resolve the worktree"), true
	}
	p.wt = phys
	deps := []string{"git", "gh", "gentle-ai"}
	if !o.noGate {
		deps = append(deps, "flock")
	}
	if !kitmaint.ProbeDeps(s.Out, s.Err, tool, p.env, s.Cwd, deps...) {
		return cli.ExitDegraded, true
	}
	state := o.state
	if state == "" {
		state = kitmaint.StateDir(s.Env)
	}
	sp, err := kitmaint.PhysPath(s.Cwd, state)
	if err != nil {
		return p.usage("cannot resolve --state-dir %s", state), true
	}
	if kitmaint.Inside(sp, p.wt) {
		return p.usage("--state-dir %s is inside the worktree; state never lives in the repo", sp), true
	}
	p.state = sp
	return 0, false
}

func (p *pipeline) usage(format string, a ...any) int {
	return p.fail(cli.ExitUsage, "usage", format, a...)
}

// gate is step 5: ONE serial gate under the flock, in process.
func (p *pipeline) gate() (int, bool) {
	o := p.o
	if o.noGate {
		return 0, false
	}
	// INT/TERM are taken only while the gate runs: the gate is in its own process group (it holds the lock as fd 3), so
	// the signal must be forwarded to stop it; the legacy kit-gate.sh shared the caller's group and died with it.
	var sig <-chan os.Signal
	if p.d.notify != nil {
		var stop func()
		sig, stop = p.d.notify()
		defer stop()
	}
	res := kitgate.Run(kitgate.Opts{
		Out: p.s.Out, R: p.kr, Wt: p.wt, Label: "pr" + o.pr, State: p.state, Cmd: o.gateCmd, Serial: o.serial,
		LockTimeout: lockTimeout(p.s.Env), Probe: func() bool { return true }, Sig: sig,
	})
	if res.Interrupted {
		return p.fail(kitgate.ExitGateFailed, "interrupted", "#%s: the gate was stopped by a signal; CI and merge were not attempted", o.pr), true
	}
	switch res.Code {
	case 0:
		return 0, false
	case kitgate.ExitUsage:
		return p.fail(cli.ExitUsage, "usage", "#%s: kit-gate.sh rejected its arguments", o.pr), true
	case kitgate.ExitDegraded:
		return p.fail(cli.ExitDegraded, "degraded", "kit-gate.sh reported a missing dependency"), true
	case kitgate.ExitLockTimeout:
		return p.fail(kitgate.ExitLockTimeout, "gate-lock-timeout", "#%s: another gate holds the lock; re-run when it finishes", o.pr), true
	}
	return p.fail(kitgate.ExitGateFailed, "gate-failed", "#%s: the gate exited non-zero (kit-gate rc=%d); CI and merge were not attempted", o.pr, res.Code), true
}

// lockTimeout is KIT_GATE_LOCK_TIMEOUT, the default when unset.
func lockTimeout(getenv func(string) string) string {
	if v := getenv("KIT_GATE_LOCK_TIMEOUT"); v != "" {
		return v
	}
	return kitgate.DefaultLockTimeout
}

// wait is step 6: CI wait, then the merge gate and the confirmation.
func (p *pipeline) wait() int {
	o := p.o
	// the legacy pipeline had cd'd into the worktree, so a relative KIT_MERGE_GATE names a file under it
	script := p.s.Env("KIT_MERGE_GATE")
	if missing := kitwait.MergeGateMissing(script, p.d.self, p.wt); missing != "" {
		fmt.Fprintf(p.s.Out, "%s: degraded: merge-gate.sh not found: %s\n", kitwait.Tool, missing)
		return p.fail(cli.ExitDegraded, "degraded", "kit-wait-merge.sh reported a missing dependency")
	}
	if script != "" {
		script = kitmaint.Abs(p.wt, script)
	}
	rc := kitwait.Run(kitwait.Opts{
		Out: p.s.Out, R: p.kr, Getenv: p.s.Env, Sleep: p.d.sleep, Wt: p.wt, PR: o.pr, Base: o.base,
		MergeGate: kitwait.ExecMergeGate(p.env, p.wt, script, p.d.self),
	})
	switch rc {
	case 0:
		p.say("merged: #%s", o.pr)
		return 0
	case cli.ExitDegraded:
		return p.fail(cli.ExitDegraded, "degraded", "kit-wait-merge.sh reported a missing dependency")
	case kitwait.ExitCIFailed:
		return p.fail(kitwait.ExitCIFailed, "ci-failed", "#%s", o.pr)
	case kitwait.ExitMergeDegraded:
		return p.fail(kitwait.ExitMergeDegraded, "merge-degraded", "#%s: merge-gate stayed degraded", o.pr)
	}
	return p.fail(kitwait.ExitNotMerged, "not-merged", "#%s (kit-wait-merge.sh exited %d)", o.pr, rc)
}
