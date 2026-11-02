package gate

import (
	"bytes"
	"fmt"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

const mtWaitTool = "kit-wait-merge"

var mtFailWord = regexp.MustCompile(`\bfail\b`)

func (g *train) waitSay(format string, a ...any) {
	fmt.Fprintf(g.s.Out, "%s: %s\n", mtWaitTool, fmt.Sprintf(format, a...))
}

// intOr is `[ n -lt $VAR ]` with the default: a value that is not an integer makes the comparison fail (0 here).
func intOr(v string, def int) int {
	if v == "" {
		return def
	}
	n, err := strconv.Atoi(strings.TrimSpace(v))
	if err != nil {
		return 0
	}
	return n
}

// waitMerge is kit-wait-merge.sh --base-ref BASE --expect-head HEAD <worktree> <pr>, in-process: poll the PR's CI
// checks, then run the merge gate (RunMerge, no merge-gate.sh child) and confirm the PR is MERGED at the gated
// head. It returns the typed exit code of the bash tool: 0 merged, 17 ci-failed, 18 merge-degraded, 19 not-merged,
// 33 merged-out-of-band.
func (g *train) waitMerge(wt, pr, expectHead string) int {
	pollMax, tries := intOr(g.s.Env("KIT_POLL_MAX"), 120), intOr(g.s.Env("KIT_MERGE_TRIES"), 3)
	green := false
	for n := 0; n < pollMax; {
		n++
		c := g.gh(wt, "pr", "checks", pr)
		if c.rc == 0 {
			green = true
			break
		}
		out := c.out + c.err
		if mtFailWord.MatchString(out) {
			for _, ln := range strings.Split(strings.TrimRight(out, "\n"), "\n") {
				if mtFailWord.MatchString(ln) {
					fmt.Fprintln(g.s.Out, ln)
				}
			}
			g.waitSay("ci-failed: a CI check failed for #%s", pr)
			return 17
		}
		g.d.sleep(time.Duration(intOr(g.s.Env("KIT_POLL_SLEEP"), 60)) * time.Second)
	}
	if !green {
		g.waitSay("ci-wait: no green result after %d polls; merge-gate decides", pollMax)
	}

	last := ""
	for i := 1; i <= tries; i++ {
		var buf bytes.Buffer
		mg := g.s
		mg.Out, mg.Err, mg.Cwd = &buf, &buf, wt
		mrc := g.d.mergeGate([]string{"--cwd", wt, "--base-ref", g.base, "--merge", pr}, mg)
		mgout := strings.TrimRight(buf.String(), "\n")
		lines := strings.Split(mgout, "\n")
		if len(lines) > 5 {
			lines = lines[len(lines)-5:]
		}
		fmt.Fprintln(g.s.Out, strings.Join(lines, "\n"))
		g.poll()

		st := strings.TrimRight(g.retryAs(mtWaitTool, 3, "gh pr view "+pr+" --json state -q .state", false, func() mtRes {
			return g.gh(wt, "pr", "view", pr, "--json", "state", "-q", ".state")
		}).out, "\n")
		if st == "MERGED" {
			info := strings.TrimRight(g.retryAs(mtWaitTool, 3, "gh pr view "+pr+" --json headRefOid,mergeCommit -q ...", false, func() mtRes {
				return g.gh(wt, "pr", "view", pr, "--json", "headRefOid,mergeCommit", "-q", `.headRefOid + " " + (.mergeCommit.oid // "")`)
			}).out, "\n")
			if info == "" {
				g.waitSay("merge-degraded: #%s is MERGED but its head and merge commit could not be read", pr)
				return 18
			}
			head, mc, _ := strings.Cut(info, " ")
			if head != expectHead {
				g.waitSay("merged-out-of-band: #%s is MERGED at head %s, not the gated head %s", pr, head, expectHead)
				return 33
			}
			g.waitSay("merged: #%s (merge commit %s)", pr, mc)
			return 0
		}
		switch {
		case mrc == cli.ExitDegraded:
			last = "degraded"
		case mrc == 0 || strings.Contains(mgout, "refuse: ci_pending"):
			last = "pending"
		default:
			last = "refused"
		}
		if last == "refused" {
			break
		}
		g.waitSay("retry %d/%d (%s)", i, tries, last)
		g.d.sleep(time.Duration(intOr(g.s.Env("KIT_MERGE_SLEEP"), 30)) * time.Second)
	}
	if last == "degraded" {
		g.waitSay("merge-degraded: merge-gate stayed degraded for #%s", pr)
		return 18
	}
	g.waitSay("not-merged: #%s is not merged (%s)", pr, last)
	return 19
}

var mtGateLines = regexp.MustCompile(`AGGREGATE|passed|failed|Suites|FAIL  |leftovers|hermeticity`)

const (
	mtGateDefaultCmd = "bash research-sdd/toolbelt/tests/run-all.sh -j 4 --prove-teeth"
	mtGateSerialCmd  = "bash research-sdd/toolbelt/tests/run-all.sh --prove-teeth"
)
