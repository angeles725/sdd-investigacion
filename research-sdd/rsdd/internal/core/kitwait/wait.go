// Package kitwait is toolbelt/maint/kit-wait-merge.sh in process (kit issue #2212, Go port): wait for the PR's CI
// checks, run the merge gate with --merge and confirm the PR is MERGED (at the gated head when ExpectHead is set).
// `rsdd maint wait-merge` and the merge train (`rsdd gate merge-train`) both run it; the merge gate itself is
// injected, because it lives in another domain.
package kitwait

import (
	"fmt"
	"io"
	"regexp"
	"strings"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/kitmaint"
)

// Tool is the prefix of every line kit-wait-merge prints.
const Tool = "kit-wait-merge"

// Typed exit states of kit-wait-merge.
const (
	ExitMerged          = 0
	ExitUsage           = 2
	ExitDegraded        = 3
	ExitCIFailed        = 17
	ExitMergeDegraded   = 18
	ExitNotMerged       = 19
	ExitMergedOutOfBand = 33
)

// Defaults of the numeric knobs (environment KIT_POLL_MAX, KIT_POLL_SLEEP, KIT_MERGE_TRIES, KIT_MERGE_SLEEP).
const (
	defPollMax   = 120
	defPollSleep = 60
	defTries     = 3
	defMergeWait = 30
	ghTries      = 3
	tailLines    = 5
)

// Runner is what the wait needs of its gh children; *kitmaint.Runner is the real one.
type Runner interface {
	Gh(dir string, args ...string) kitmaint.Res
	Retry(tool string, tries int, words string, quiet bool, f func() kitmaint.Res) kitmaint.Res
}

// Opts is one wait-and-merge run.
type Opts struct {
	Out        io.Writer
	R          Runner
	Getenv     func(string) string
	Sleep      func(time.Duration)
	Poll       func() // called after the merge gate: where a pending INT/TERM may end the run (nil: none)
	Wt, PR     string
	Base       string
	ExpectHead string
	// HeadReadWords is the command line a retry note names for the head/merge-commit read. Empty is the whole
	// command, jq expression included, as kit-wait-merge.sh printed it; the merge train passes its own elided form.
	HeadReadWords string
	// MergeGate runs the merge gate with args and returns its rc and its stdout+stderr as one text (the bash 2>&1).
	MergeGate func(args []string) (rc int, out string)
}

var failWord = regexp.MustCompile(`\bfail\b`)

func (o *Opts) say(format string, a ...any) {
	fmt.Fprintf(o.Out, "%s: %s\n", Tool, fmt.Sprintf(format, a...))
}

// Run is kit-wait-merge.sh after its argument and dependency checks. It returns the typed exit code.
func Run(o Opts) int {
	if code := waitCI(&o); code != 0 {
		return code
	}
	return mergeLoop(&o)
}

// waitCI polls `gh pr checks`: green ends the wait, a `fail` line is ci-failed, anything else (pending, a network
// blip) sleeps and polls again, at most KIT_POLL_MAX times; then the merge gate decides.
func waitCI(o *Opts) int {
	pollMax := kitmaint.IntOr(o.Getenv("KIT_POLL_MAX"), defPollMax)
	for n := 0; n < pollMax; {
		n++
		c := o.R.Gh(o.Wt, "pr", "checks", o.PR)
		if c.RC == 0 {
			return 0
		}
		out := c.Out + c.Err
		if failWord.MatchString(out) {
			for _, ln := range strings.Split(strings.TrimRight(out, "\n"), "\n") {
				if failWord.MatchString(ln) {
					fmt.Fprintln(o.Out, ln)
				}
			}
			o.say("ci-failed: a CI check failed for #%s", o.PR)
			return ExitCIFailed
		}
		o.Sleep(time.Duration(kitmaint.IntOr(o.Getenv("KIT_POLL_SLEEP"), defPollSleep)) * time.Second)
	}
	o.say("ci-wait: no green result after %d polls; merge-gate decides", pollMax)
	return 0
}

// state is `gh pr view PR --json FIELDS -q EXPR` under kit_retry, trailing newline trimmed.
func (o *Opts) view(fields, expr, words string) string {
	if words == "" {
		words = "gh pr view " + o.PR + " --json " + fields + " -q " + expr
	}
	r := o.R.Retry(Tool, ghTries, words, false, func() kitmaint.Res {
		return o.R.Gh(o.Wt, "pr", "view", o.PR, "--json", fields, "-q", expr)
	})
	return strings.TrimRight(r.Out, "\n")
}

// mergeLoop runs the merge gate up to KIT_MERGE_TRIES times and confirms MERGED. Retried: merge-gate rc 3 (degraded),
// `refuse: ci_pending`, or an allow that has not shown MERGED yet; any other refusal stops at once.
func mergeLoop(o *Opts) int {
	tries := kitmaint.IntOr(o.Getenv("KIT_MERGE_TRIES"), defTries)
	last := ""
	for i := 1; i <= tries; i++ {
		mrc, mgout := o.MergeGate([]string{"--cwd", o.Wt, "--base-ref", o.Base, "--merge", o.PR})
		mgout = strings.TrimRight(mgout, "\n")
		lines := strings.Split(mgout, "\n")
		lines = lines[max(0, len(lines)-tailLines):]
		fmt.Fprintln(o.Out, strings.Join(lines, "\n"))
		if o.Poll != nil {
			o.Poll()
		}
		if o.view("state", ".state", "") == "MERGED" {
			return confirmMerged(o)
		}
		switch {
		case mrc == ExitDegraded:
			last = "degraded"
		case mrc == 0 || strings.Contains(mgout, "refuse: ci_pending"):
			last = "pending"
		default:
			last = "refused"
		}
		if last == "refused" {
			break
		}
		o.say("retry %d/%d (%s)", i, tries, last)
		o.Sleep(time.Duration(kitmaint.IntOr(o.Getenv("KIT_MERGE_SLEEP"), defMergeWait)) * time.Second)
	}
	if last == "degraded" {
		o.say("merge-degraded: merge-gate stayed degraded for #%s", o.PR)
		return ExitMergeDegraded
	}
	o.say("not-merged: #%s is not merged (%s)", o.PR, last)
	return ExitNotMerged
}

// confirmMerged is the MERGED branch: with ExpectHead, MERGED only counts when GitHub merged the gated head
// (kit issue #2213 S1).
func confirmMerged(o *Opts) int {
	if o.ExpectHead == "" {
		o.say("merged: #%s", o.PR)
		return ExitMerged
	}
	info := o.view("headRefOid,mergeCommit", `.headRefOid + " " + (.mergeCommit.oid // "")`, o.HeadReadWords)
	if info == "" {
		o.say("merge-degraded: #%s is MERGED but its head and merge commit could not be read", o.PR)
		return ExitMergeDegraded
	}
	head, mc, _ := strings.Cut(info, " ")
	if head != o.ExpectHead {
		o.say("merged-out-of-band: #%s is MERGED at head %s, not the gated head %s", o.PR, head, o.ExpectHead)
		return ExitMergedOutOfBand
	}
	o.say("merged: #%s (merge commit %s)", o.PR, mc)
	return ExitMerged
}
