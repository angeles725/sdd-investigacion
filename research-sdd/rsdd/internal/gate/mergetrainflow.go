package gate

import (
	"encoding/json"
	"fmt"
	"strings"
)

// mtJqRaw is `jq -r KEY` over the object; alt is the `// empty` form (null and false read as empty).
func mtJqRaw(obj map[string]any, key string, alt bool) string {
	v, present := obj[key]
	if alt && (!present || v == nil || v == false) {
		return ""
	}
	switch t := v.(type) {
	case nil:
		return "null"
	case string:
		return t
	case bool:
		if t {
			return "true"
		}
		return "false"
	default:
		b, _ := json.Marshal(t)
		return string(b)
	}
}

func mtParseObj(s string) map[string]any {
	var m map[string]any
	if json.Unmarshal([]byte(s), &m) != nil {
		return nil
	}
	return m
}

// mtPinMatches: the pin (7+ hex, case-free) must be a prefix of the PR head.
func mtPinMatches(oid, pin string) bool {
	return strings.HasPrefix(strings.ToLower(oid), strings.ToLower(pin))
}

// prCwdOK: --pr-cwd PR=DIR must be a worktree of THIS repo (same common git dir) whose HEAD is the pinned head;
// it is resolved to its physical path. RDD authority is bound to the worktree where the review ran.
func (g *train) prCwdOK(p, oid string) bool {
	d := g.pcwd[p]
	if !isDir(g.abs(d)) {
		return false
	}
	a := g.git(d, "rev-parse", "--path-format=absolute", "--git-common-dir")
	if a.rc != 0 {
		return false
	}
	b := g.git(g.repo, "rev-parse", "--path-format=absolute", "--git-common-dir")
	if b.rc != 0 {
		return false
	}
	ca, cb := strings.TrimRight(a.out, "\n"), strings.TrimRight(b.out, "\n")
	if ca == "" || ca != cb {
		return false
	}
	if h := g.git(d, "rev-parse", "HEAD"); h.rc != 0 || strings.TrimRight(h.out, "\n") != oid {
		return false
	}
	phys, err := g.resolveDir(d)
	if err != nil {
		return false
	}
	g.pcwd[p] = phys
	return true
}

// checkPRs is step 1: per PR open, not a draft, on the train base, RDD head pin, head fetched and equal to gh's.
func (g *train) checkPRs() {
	for _, p := range g.prs {
		row := g.rows[p]
		words := "gh pr view " + p + " --json state,isDraft,headRefOid,baseRefName"
		info := g.retry(words, true, func() mtRes {
			return g.gh(g.s.Cwd, "pr", "view", p, "--json", "state,isDraft,headRefOid,baseRefName")
		})
		if !info.ok() || strings.TrimRight(info.out, "\n") == "" {
			row.status, row.reason = "refused", "gh-view-failed"
			g.say("train-refused #%s: gh pr view failed", p)
			continue
		}
		obj := mtParseObj(strings.TrimRight(info.out, "\n"))
		oid := mtJqRaw(obj, "headRefOid", true)
		row.head = oid
		why := ""
		switch {
		case mtJqRaw(obj, "state", true) != "OPEN":
			why = "not-open"
		case mtJqRaw(obj, "isDraft", false) != "false":
			why = "draft"
		case mtJqRaw(obj, "baseRefName", true) != g.baseBranch:
			why = "base-not-" + g.baseBranch
		case oid == "":
			why = "no-head"
		case g.pin[p] == "":
			why = "rdd-unconfirmed"
		case !mtPinMatches(oid, g.pin[p]):
			why = "rdd-head-mismatch"
		case g.pcwd[p] != "" && !g.prCwdOK(p, oid):
			why = "pr-cwd-mismatch"
		default:
			ref := "refs/train/" + g.ts + "/" + p
			f := g.retry("git -C "+g.repo+" fetch -q "+g.remote, true, func() mtRes {
				return g.git(g.repo, "fetch", "-q", g.remote, "+refs/pull/"+p+"/head:"+ref)
			})
			if !f.ok() || strings.TrimRight(g.git(g.repo, "rev-parse", ref).out, "\n") != oid {
				why = "head-moved"
			}
		}
		if why != "" {
			row.status, row.reason = "refused", why
			g.say("train-refused #%s: %s", p, why)
			continue
		}
		g.keep = append(g.keep, p)
	}
}

func (g *train) mergeNoFF(p string) mtRes {
	return g.git(g.wt, "merge", "-q", "--no-ff", "-m", "train: merge #"+p, g.rows[p].head)
}

// buildTrain is step 2: the local train branch in its own worktree, one `git merge --no-ff` per PR head.
func (g *train) buildTrain() {
	if err := mkdirAll(g.wtroot); err != nil {
		g.finish(29, "train-error", "cannot create "+g.wtroot)
	}
	if r := g.git(g.repo, "worktree", "add", "-q", "-b", g.branch, g.wt, g.baseSHA); !r.ok() {
		g.finish(29, "train-error", "cannot create the train worktree "+g.wt)
	}
	g.started = true
	g.madeWts = append(g.madeWts, g.wt)
	for _, p := range g.keep {
		if g.mergeNoFF(p).ok() {
			g.merged = append(g.merged, p)
			continue
		}
		unmerged := strings.TrimRight(g.git(g.wt, "ls-files", "-u").out, "\n") != ""
		g.git(g.wt, "merge", "--abort")
		if !unmerged {
			g.finish(29, "train-error", "merging #"+p+" failed without a conflict")
		}
		g.rows[p].status, g.rows[p].reason = "dropped", "train-conflict"
		g.say("train-conflict #%s: dropped from the batch", p)
	}
	if len(g.merged) == 0 {
		g.finish(28, "train-empty", "every PR conflicted")
	}
	g.trainSHA = strings.TrimRight(g.git(g.wt, "rev-parse", "HEAD").out, "\n")
}

// runGate is run_gate: sets gateRC / gateLog; returns 0 green, 16 red, 22 lock timeout (bisect only, else it
// finishes).
func (g *train) runGate(label string) int {
	g.gateLog = g.state + "/gate-" + label + ".log"
	rc, grc := g.kitGate(label)
	g.poll()
	switch rc {
	case 0:
		g.gateRC = "0"
	case 16:
		g.gateRC = fmt.Sprint(grc)
	case 22:
		if g.inBisect {
			return 22
		}
		g.finish(22, "gate-lock-timeout", "another gate holds the lock")
	default:
		g.finish(29, "train-error", fmt.Sprintf("kit-gate.sh exited %d", rc))
	}
	return rc
}

// runTrainGate is step 3: ONE gate on the train head; on red, optionally bisect, then the train-gate-failed stop.
func (g *train) runTrainGate() {
	if g.runGate("train-"+g.ts) == 0 {
		return
	}
	incomplete := ""
	if g.bisect {
		g.finalGateRC, g.finalGateLog, g.inBisect = g.gateRC, g.gateLog, true
		lo, hi := 0, len(g.merged)
		for hi-lo > 1 {
			mid := (lo + hi) / 2
			if r := g.git(g.wt, "reset", "-q", "--hard", g.baseSHA); !r.ok() {
				g.finish(29, "train-error", "bisect reset failed")
			}
			for i := 0; i < mid; i++ {
				if !g.mergeNoFF(g.merged[i]).ok() {
					g.finish(29, "train-error", "bisect re-merge of #"+g.merged[i]+" failed")
				}
			}
			g.say("bisect: gating the first %d of %d PRs", mid, len(g.merged))
			r := g.runGate(fmt.Sprintf("train-%s-bisect-%d", g.ts, mid))
			if r == 0 {
				lo = mid
			} else if r == 22 {
				incomplete = "gate-lock-timeout"
				break
			} else {
				hi = mid
			}
		}
		g.inBisect = false
		// the FULL gate's verdict stays the receipt's gate result, whatever the bisect runs did
		g.gateRC, g.gateLog = g.finalGateRC, g.finalGateLog
		if incomplete == "" {
			g.culprit = g.merged[hi-1]
			g.rows[g.culprit].status, g.rows[g.culprit].reason = "culprit", "first-red-prefix"
			g.say("bisect: first red prefix ends at #%s (the base is assumed green; may be an interaction)", g.culprit)
		}
	}
	msg := "the combined gate was red"
	if g.culprit != "" {
		msg += "; culprit #" + g.culprit
	}
	if incomplete != "" {
		msg += "; bisect-incomplete: " + incomplete
	}
	g.finish(26, "train-gate-failed", msg+"; nothing merged (log "+g.gateLog+")")
}

// preMerge is step 4: main must still be where the train was built.
func (g *train) preMerge() {
	if !g.retry("git -C "+g.repo+" fetch -q "+g.remote, false, func() mtRes { return g.git(g.repo, "fetch", "-q", g.remote) }).ok() {
		g.finish(21, "fetch-failed", "git fetch "+g.remote+" failing after the gate")
	}
	cur := strings.TrimRight(g.git(g.repo, "rev-parse", g.base+"^{commit}").out, "\n")
	if cur != g.baseSHA {
		if cur == "" {
			cur = "unknown"
		}
		g.finish(30, "base-moved", fmt.Sprintf("%s moved from %s to %s during the gate; nothing merged, re-run", g.base, g.baseSHA, cur))
	}
	g.expTip = g.baseSHA
}

// verifyTree: the tree on main must equal the tree of base + the PRs actually merged.
func (g *train) verifyTree() {
	if len(g.mergedOK) == 0 {
		return
	}
	var want string
	if len(g.mergedOK) == len(g.merged) {
		want = strings.TrimRight(g.git(g.wt, "rev-parse", g.trainSHA+"^{tree}").out, "\n")
	} else {
		if r := g.git(g.wt, "reset", "-q", "--hard", g.baseSHA); !r.ok() {
			g.finish(29, "train-error", "prefix tree reset failed")
		}
		for _, p := range g.mergedOK {
			if !g.mergeNoFF(p).ok() {
				g.finish(29, "train-error", "prefix tree re-merge of #"+p+" failed")
			}
		}
		want = strings.TrimRight(g.git(g.wt, "rev-parse", "HEAD^{tree}").out, "\n")
	}
	got := strings.TrimRight(g.git(g.repo, "rev-parse", g.base+"^{tree}").out, "\n")
	if got != want {
		g.finish(32, "tree-mismatch", fmt.Sprintf("%s tree %s differs from the train tree %s for the merged PRs (%s); inspect main", g.base, got, want, strings.Join(g.mergedOK, " ")))
	}
}

// mergeAll is step 5: merge in order, each in a worktree at the PR's own head.
func (g *train) mergeAll() {
	for _, p := range g.merged {
		row := g.rows[p]
		if g.stopped != "" {
			row.status, row.reason = "pending", "after #"+g.stopped
			continue
		}
		pw, own := g.pcwd[p], false
		if pw == "" {
			pw, own = g.wtroot+"/train-"+g.ts+"-pr"+p, true
			if r := g.git(g.repo, "worktree", "add", "-q", "--detach", pw, row.head); !r.ok() {
				g.stopped, g.stopRC = p, 29
				row.status, row.reason = "pending", "worktree-failed"
				continue
			}
			g.madeWts = append(g.madeWts, pw)
		}
		mrc := g.waitMerge(pw, p, row.head)
		if own {
			g.git(g.repo, "worktree", "remove", "--force", pw)
		}
		switch mrc {
		case 0:
			row.status = "merged"
			g.mergedOK = append(g.mergedOK, p)
			if !g.retry("git -C "+g.repo+" fetch -q "+g.remote, false, func() mtRes { return g.git(g.repo, "fetch", "-q", g.remote) }).ok() {
				g.stopped, g.stopRC = p, 21
				row.reason = "fetch after the merge failed"
				continue
			}
			cur := strings.TrimRight(g.git(g.repo, "rev-parse", g.base+"^{commit}").out, "\n")
			if strings.TrimRight(g.git(g.repo, "rev-parse", g.base+"^").out, "\n") != g.expTip {
				g.stopped, g.stopRC = p, 31
				row.reason = "main-raced: " + g.base + "^ is not the expected tip " + g.expTip
			} else {
				g.expTip = cur
			}
		case 33:
			g.stopped, g.stopRC = p, 33
			row.status, row.reason = "out-of-band", "MERGED with a head other than the gated "+row.head
		default:
			g.stopped, g.stopRC = p, mrc
			row.status, row.reason = "pending", fmt.Sprintf("stopped: kit-wait-merge rc=%d", mrc)
		}
	}
	if g.stopped != "" {
		st := ""
		switch g.stopRC {
		case 17:
			st = "ci-failed"
		case 18:
			st = "merge-degraded"
		case 21:
			st = "fetch-failed"
		case 29:
			st = "train-error"
		case 31:
			st = "main-raced"
		case 33:
			st = "merged-out-of-band"
		default:
			st, g.stopRC = "not-merged", 19
		}
		switch st {
		case "not-merged", "ci-failed", "merge-degraded":
			g.verifyTree()
		}
		none := strings.Join(g.mergedOK, " ")
		if none == "" {
			none = "none"
		}
		g.finish(g.stopRC, st, "#"+g.stopped+" stopped the train; merged so far: "+none+"; the PRs after it are pending")
	}
	g.verifyTree()
	for _, p := range g.prs {
		if g.rows[p].status != "merged" {
			g.finish(27, "train-partial", "merged: "+strings.Join(g.mergedOK, " ")+"; refused or dropped: see the receipt")
		}
	}
	g.finish(0, "merged", fmt.Sprintf("all %d PRs merged after one gate on train %s", len(g.mergedOK), g.trainSHA))
}
