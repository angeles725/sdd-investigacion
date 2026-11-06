package cleancheck

import (
	"os"
	"strconv"
	"strings"
)

// worktreeScan is the outcome of class (e): the summary field, and the full ref of every branch some worktree has
// checked out (the main one included), which the merged-branch scan never reports. known is false when git could not
// list the worktrees, so the checked-out set is unknown.
type worktreeScan struct {
	state   string
	checked map[string]bool
	known   bool
}

// listWorktrees runs `git worktree list --porcelain -z` and falls back to the line form on a git older than 2.36.
// It returns the porcelain lines, and false when neither form worked.
func (r *run) listWorktrees() ([]string, bool) {
	if g := r.git("worktree", "list", "--porcelain", "-z"); g.rc == 0 {
		return strings.Split(strings.TrimSuffix(g.out, "\x00"), "\x00"), true
	}
	if g := r.git("worktree", "list", "--porcelain"); g.rc == 0 {
		return strings.Split(strings.TrimSuffix(g.out, "\n"), "\n"), true
	}
	return nil, false
}

// scanWorktrees is class (e), report-only: every registered worktree but the first (the main one) whose path is gone
// or that git marks prunable. A listing that fails is the typed DEGRADED-WORKTREE-SCAN, never a quiet zero.
func (r *run) scanWorktrees() worktreeScan {
	lines, ok := r.listWorktrees()
	if !ok {
		why := oneLine(strings.TrimRight(r.git("worktree", "list", "--porcelain").err, "\n"))
		if why == "" {
			why = "git exited non-zero without output"
		}
		r.degrade(DegradedWorktree, "DEGRADED-WORKTREE-SCAN git worktree list failed: "+why, "worktree scan failed")
		return worktreeScan{state: "degraded", checked: map[string]bool{}}
	}
	ws := worktreeScan{checked: map[string]bool{}, known: true}
	n, stale := 0, 0
	var path, prunable, branch string
	locked, bare := false, false
	flush := func() {
		if path == "" {
			return
		}
		if branch != "" {
			ws.checked[branch] = true
		}
		if n > 0 && !bare {
			suffix := ""
			if locked {
				suffix = " (locked)"
			}
			if _, err := os.Stat(path); err != nil {
				r.warn("stale-worktree " + path + " missing" + suffix)
				stale++
			} else if prunable != "" {
				r.warn("stale-worktree " + path + " prunable (" + prunable + ")" + suffix)
				stale++
			}
		}
		n++
		path, prunable, branch, locked, bare = "", "", "", false, false
	}
	for _, l := range lines {
		switch {
		case strings.HasPrefix(l, "worktree "):
			flush()
			path = strings.TrimPrefix(l, "worktree ")
		case strings.HasPrefix(l, "prunable"):
			prunable = strings.TrimPrefix(strings.TrimPrefix(l, "prunable"), " ")
			if prunable == "" {
				prunable = "prunable"
			}
		case strings.HasPrefix(l, "locked"):
			locked = true
		case l == "bare":
			bare = true
		case strings.HasPrefix(l, "branch "):
			branch = strings.TrimPrefix(l, "branch ")
		}
	}
	flush()
	ws.state = strconv.Itoa(n) + " registered, " + strconv.Itoa(stale) + " stale"
	return ws
}
