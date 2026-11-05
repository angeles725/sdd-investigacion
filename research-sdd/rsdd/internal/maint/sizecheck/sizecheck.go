// Package sizecheck is `rsdd maint size-check`, the port of toolbelt/maint/kit-size-check.sh (kit issue #2214, Go
// port): the pre-RDD size guard. It measures the authored changed lines of `git diff --numstat BASE...HEAD`, names
// mechanical-churn hotspots, and refuses or warns above the review budget. Read-only: it only runs git.
//
// Exit codes: 0 ok / empty-input / all-excluded / unmeasured / over-budget, 3 over-budget under --strict and refuse
// (a verdict, not a degraded state: the command is registered PlainExit3), 2 degraded or bad usage.
//
// Intended divergences from the bash, each pinned by a test and listed in tool-registry.d/kit-size-check.md:
//   - awk and mktemp are no longer needed (the hotspot reader and the numstat file are Go), so a PATH without awk is
//     not a degraded state;
//   - a numstat count that is neither digits nor "-" is a typed degraded state (the bash did arithmetic on the text);
//   - git runs as `git -C <cwd>` (the working directory of the command), so a relative path never depends on the
//     process directory;
//   - control characters are the bytes below space and DEL (the C locale the legacy tests run in).
package sizecheck

import (
	_ "embed"
	"fmt"
	"io"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/kitmaint"
)

//go:embed help.txt
var help string

const tool = "kit-size-check"

// Exit codes beyond 0.
const (
	exitDegraded = 2
	exitVerdict  = 3
)

// Run is `rsdd maint size-check`.
func Run(args []string, s cli.Stdio) int {
	o, f := parse(args)
	if o.help && f == nil {
		fmt.Fprint(s.Out, help)
		return cli.ExitOK
	}
	if f != nil {
		if f.showUsage {
			fmt.Fprint(s.Err, help)
		}
		return degrade(s, f.format, f.why)
	}
	env := s.Environ()
	if len(kitmaint.MissingDeps(env, s.Cwd, "git")) > 0 {
		return degrade(s, o.format, "git is not installed")
	}
	runner := &kitmaint.Runner{Env: env, Cwd: s.Cwd, Now: s.Clock, Err: io.Discard, Getenv: s.Env}
	git := func(a ...string) kitmaint.Res { return runner.Git(s.Cwd, a...) }
	if r := git("rev-parse", "--is-inside-work-tree"); r.RC != 0 || r.Out != "true\n" {
		return degrade(s, o.format, "not inside a git work tree")
	}
	if !git("rev-parse", "--verify", "--quiet", o.base+"^{commit}").OK() {
		return degrade(s, o.format, "base ref does not resolve to a commit: "+o.base)
	}
	if !git("rev-parse", "--verify", "--quiet", o.head+"^{commit}").OK() {
		return degrade(s, o.format, "head ref does not resolve to a commit: "+o.head)
	}
	if !git("merge-base", o.base, o.head).OK() {
		return degrade(s, o.format, "no merge base between "+o.base+" and "+o.head)
	}
	rng := o.base + "..." + o.head
	diff := git("diff", "--no-ext-diff", "-M", "--numstat", "-z", rng)
	if !diff.OK() {
		return degrade(s, o.format, "git diff failed for "+rng)
	}
	entries, why := parseNumstat(diff.Out)
	if why != "" {
		return degrade(s, o.format, why)
	}
	return report(s, o, rng, classify(entries), func(a ...string) (string, bool) {
		r := git(a...)
		return r.Out, r.OK()
	})
}

// report decides the verdict, adds hotspots and the split suggestion, and prints in the requested format.
func report(s cli.Stdio, o options, rng string, t tally, git func(...string) (string, bool)) int {
	r := result{o: o, rng: rng, t: t, state: t.verdict(o.budget, o.hard)}
	r.hot, r.unchecked = hotspots(t, rng, git)
	if r.state == stOver || r.state == stRefuse {
		r.chunks = split(t.files, o.budget)
	}
	if o.format == "json" {
		writeJSON(s.Out, r)
	} else {
		writeReport(s.Out, r)
	}
	if r.state == stRefuse || (r.state == stOver && o.strict) {
		return exitVerdict
	}
	return cli.ExitOK
}

// degrade is the typed degraded state: the why on stderr, `size: degraded` (or its JSON document) on stdout.
func degrade(s cli.Stdio, format, why string) int {
	fmt.Fprintf(s.Err, "degraded: %s: %s\n", tool, why)
	if format == "json" {
		fmt.Fprintf(s.Out, "{\"state\":\"degraded\",\"reason\":%s}\n", quoted(why))
	} else {
		fmt.Fprintln(s.Out, "size: degraded")
	}
	return exitDegraded
}
