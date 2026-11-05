// Package waitmerge is `rsdd maint wait-merge`, the port of toolbelt/maint/kit-wait-merge.sh (kit issue #2212, Go
// port): wait for the PR's CI checks, run the merge gate with --merge and confirm the PR is MERGED. The run itself
// lives in core/kitwait, shared with the merge train; this package owns the command line, the help text, the
// dependency probe and the choice of merge gate.
//
// Intended divergences from the bash, each pinned by a test and listed in tool-registry.d/kit-pr-pipeline.md:
//   - without KIT_MERGE_GATE the merge gate is the rsdd binary's own `gate merge` (no merge-gate.sh, no bash hop);
//     KIT_MERGE_GATE still names a script that is run with bash, and a missing one is the same typed degraded exit;
//   - a relative <worktree> is made absolute once (the bash cd'd into it and then passed the relative path to the
//     merge gate, which no longer resolved);
//   - a degraded exit 3 also writes `DEGRADED: <why>` to stderr (the rsdd process contract);
//   - rsdd buffers stdout until the command returns, so the typed lines appear at the end.
package waitmerge

import (
	_ "embed"
	"fmt"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/kitmaint"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/kitwait"
)

//go:embed help.txt
var help string

// deps is what the command takes from outside: sleeping and the path of the running binary. Tests replace them.
type deps struct {
	sleep func(time.Duration)
	self  string
}

// Run is `rsdd maint wait-merge`.
func Run(args []string, s cli.Stdio) int {
	return run(args, s, deps{sleep: time.Sleep, self: kitwait.Self()})
}

func run(args []string, s cli.Stdio, d deps) int {
	o, err := parse(args)
	if err != nil {
		fmt.Fprintf(s.Out, "%s: usage: %s\n", kitwait.Tool, err)
		return cli.ExitUsage
	}
	if o.help {
		fmt.Fprint(s.Out, help)
		return cli.ExitOK
	}
	if bad := kitwait.BadKnob(s.Env); bad != "" {
		fmt.Fprintf(s.Out, "%s: usage: %s must be a whole number: %s\n", kitwait.Tool, bad, s.Env(bad))
		return cli.ExitUsage
	}
	if !kitmaint.IsDir(kitmaint.Abs(s.Cwd, o.wt)) {
		fmt.Fprintf(s.Out, "%s: usage: worktree is not a directory: %s\n", kitwait.Tool, o.wt)
		return cli.ExitUsage
	}
	env := s.Environ()
	if !kitmaint.ProbeDeps(s.Out, s.Err, kitwait.Tool, env, s.Cwd, "gh") {
		return cli.ExitDegraded
	}
	script := s.Env("KIT_MERGE_GATE")
	if missing := kitwait.MergeGateMissing(script, d.self, s.Cwd); missing != "" {
		fmt.Fprintf(s.Out, "%s: degraded: merge-gate.sh not found: %s\n", kitwait.Tool, missing)
		fmt.Fprintf(s.Err, "DEGRADED: merge-gate.sh not found: %s\n", missing)
		return cli.ExitDegraded
	}
	wt := kitmaint.Abs(s.Cwd, o.wt)
	runner := &kitmaint.Runner{Env: env, Cwd: wt, Now: s.Clock, Err: s.Err, Getenv: s.Env, Sleep: d.sleep}
	if script != "" {
		script = kitmaint.Abs(s.Cwd, script)
	}
	return kitwait.Run(kitwait.Opts{
		Out: s.Out, R: runner, Getenv: s.Env, Sleep: d.sleep, Wt: wt, PR: o.pr, Base: o.base, ExpectHead: o.expectHead,
		MergeGate: kitwait.ExecMergeGate(env, wt, script, d.self),
	})
}
