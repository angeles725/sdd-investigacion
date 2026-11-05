package gate

import (
	"bytes"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/kitwait"
)

// waitMerge is kit-wait-merge.sh --base-ref BASE --expect-head HEAD <worktree> <pr>, in process (core/kitwait, shared
// with `rsdd maint wait-merge`): poll the PR's CI checks, then run the merge gate (RunMerge, no merge-gate.sh child)
// and confirm the PR is MERGED at the gated head. It returns the typed exit code of the bash tool: 0 merged,
// 17 ci-failed, 18 merge-degraded, 19 not-merged, 33 merged-out-of-band.
func (g *train) waitMerge(wt, pr, expectHead string) int {
	return kitwait.Run(kitwait.Opts{
		Out: g.s.Out, R: g.kr, Getenv: g.s.Env, Sleep: g.d.sleep, Poll: g.poll,
		Wt: wt, PR: pr, Base: g.base, ExpectHead: expectHead,
		// the train's retry note has always elided the jq expression of this read
		HeadReadWords: "gh pr view " + pr + " --json headRefOid,mergeCommit -q ...",
		MergeGate: func(args []string) (int, string) {
			var buf bytes.Buffer
			mg := g.s
			mg.Out, mg.Err, mg.Cwd = &buf, &buf, wt
			rc := g.d.mergeGate(args, mg)
			return rc, buf.String()
		},
	})
}
