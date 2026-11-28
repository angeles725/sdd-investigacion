package reviewslices

import (
	"strings"
	"sync/atomic"
)

// workers bounds the git runs in flight: the commits are independent read-only questions, and nearly all of the time
// of a plan is the forks of those questions.
const workers = 4

// measureAll measures the commits concurrently and hands the results to yield IN COMMIT ORDER, which is what keeps the
// output (and the slices already printed when a measurement fails) the script's: yield returns false to stop at the
// first failure, and the commits not started by then are skipped. A panic of a worker is re-raised here, inside the
// command, where the cli boundary turns it into the typed internal error.
func measureAll(git func(...string) (string, bool), commits []string, yield func(commit, string) bool) {
	type outcome struct {
		m     commit
		msg   string
		panic any
	}
	results := make([]chan outcome, len(commits))
	var stop atomic.Bool
	sem := make(chan struct{}, workers)
	for i, c := range commits {
		results[i] = make(chan outcome, 1)
		go func() {
			sem <- struct{}{}
			defer func() { <-sem }()
			if stop.Load() {
				results[i] <- outcome{}
				return
			}
			defer func() {
				if r := recover(); r != nil {
					results[i] <- outcome{panic: r}
				}
			}()
			m, msg := measure(git, c)
			results[i] <- outcome{m: m, msg: msg}
		}()
	}
	for _, ch := range results {
		o := <-ch
		if o.panic != nil {
			stop.Store(true)
			panic(o.panic)
		}
		if !yield(o.m, o.msg) {
			stop.Store(true)
			return
		}
	}
}

// measure is one commit measured against its first parent (the empty tree for a root commit): its short sha, its
// parent's, its authored changed lines and its binary files. A message is a typed failure (exit 2).
func measure(git func(...string) (string, bool), c string) (commit, string) {
	short, ok := git("rev-parse", "--short=12", c)
	if !ok {
		return commit{}, "plan-review-slices: cannot abbreviate " + c
	}
	// `rev-list --parents -n 1` prints "<commit> [<parent>...]": a failure is an error; only an authoritative empty
	// parent list means root. A failed lookup must never read as a root commit.
	ps, ok := git("rev-list", "--parents", "-n", "1", c)
	if !ok {
		return commit{}, "plan-review-slices: cannot read parents of " + short
	}
	var from, pshort string
	if f := strings.Fields(firstLine(ps)); len(f) >= 2 {
		from = f[1]
		if pshort, ok = git("rev-parse", "--short=12", from); !ok {
			return commit{}, "plan-review-slices: cannot abbreviate parent of " + short
		}
	} else {
		pshort = "ROOT"
		if from, ok = git("hash-object", "-t", "tree", "/dev/null"); !ok {
			return commit{}, "plan-review-slices: cannot compute the empty tree for root commit " + short
		}
	}
	ns, ok := git("diff", "--numstat", from, c)
	if !ok {
		return commit{}, "plan-review-slices: git diff failed for " + short
	}
	lines, bin, ok := parseNumstat(ns)
	if !ok {
		return commit{}, "plan-review-slices: malformed numstat row for " + short
	}
	return commit{short: short, base: pshort, lines: lines, bin: bin}, ""
}
