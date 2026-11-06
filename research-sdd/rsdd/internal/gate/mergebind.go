package gate

import (
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// bindPR reads the PR head and base over REST (`gh pr view --json` has no baseRefOid in gh 2.45, kit issue
// #1272 F1) and refuses a head or range that is not the PR's.
func (g *mergeGate) bindPR() (code int, done bool) {
	c := g.r.GH(g.cwd, "api", "repos/{owner}/{repo}/pulls/"+g.pr, "--jq", "{headRefOid:.head.sha, baseRefOid:.base.sha, baseRefName:.base.ref}")
	prJSON := ""
	if c.RC == 0 {
		prJSON = cmdSub(string(c.Stdout))
	}
	if prJSON == "" {
		return g.degraded("cannot read PR #" + g.pr + " (gh api failed)"), true
	}
	vals, _ := jqStream(prJSON)
	prHead := jqEach(vals, jqOptKey("headRefOid"))
	if prHead == "" {
		return g.degraded("cannot read PR #" + g.pr + " head (no headRefOid)"), true
	}
	if prHead != g.head {
		g.say("refuse: head_mismatch (PR #%s head %s != checked HEAD %s)", g.pr, prHead, g.head)
		return cli.ExitOperational, true
	}
	g.prBase = jqEach(vals, jqOptKey("baseRefOid"))
	if g.prBase == "" {
		return g.degraded("cannot read PR #" + g.pr + " base (no baseRefOid)"), true
	}
	if _, ok := g.git("cat-file", "-e", g.prBase+"^{commit}"); !ok {
		return g.degraded("PR #" + g.pr + " base " + g.prBase + " is not present locally (git fetch first)"), true
	}
	prMB, ok := g.git("merge-base", "HEAD", g.prBase)
	if !ok {
		return g.degraded("no common ancestor between HEAD and PR #" + g.pr + " base"), true
	}
	if _, isAncestor := g.git("merge-base", "--is-ancestor", g.mb, prMB); !isAncestor {
		g.say("refuse: base_excludes_pr_commits (assessed range starts at %s, after the PR branch point %s) — use the PR base as --base-ref", g.mb, prMB)
		return cli.ExitOperational, true
	}
	return 0, false
}
