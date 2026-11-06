package cleancheck

import (
	"strconv"
	"strings"
)

// scanBranches is class (f), report-only: the local branches and remote-tracking refs git lists as merged into the
// base. Never reported: the base itself, its twin on the other side (main for origin/main), a remote HEAD alias and
// any branch a worktree has checked out. Without the worktree list the checked-out set is unknown, so the local
// branches are not judged at all (a false WARN is worse than none) and an INFO line says so. It returns the summary
// field: `no base` (the typed ABSENT-BASE line), `degraded`, or the counts.
func (r *run) scanBranches(ws worktreeScan) string {
	if !r.base.found() {
		r.absent(AbsentBase, "", "ABSENT-BASE no --base, origin/HEAD, main or master found; merged-branch scan skipped")
		return "no base"
	}
	g := r.git("for-each-ref", "--merged="+r.base.commit, "--format=%(refname)", "refs/heads", "refs/remotes")
	if g.rc != 0 {
		why := oneLine(strings.TrimRight(g.err, "\n"))
		if why == "" {
			why = "git exited non-zero without output"
		}
		r.degrade(DegradedBranch, "DEGRADED-BRANCH-SCAN git for-each-ref failed: "+why, "branch scan failed")
		return "degraded"
	}
	if !ws.known {
		r.stdout("INFO merged-branch scan of local branches skipped: worktree scan degraded, checked-out branches unknown")
	}
	twin := r.base.twinName()
	local, remote := 0, 0
	for _, ref := range strings.Split(g.trimmed(), "\n") {
		name, bare, kind, ok := splitRef(ref)
		if !ok || ref == r.base.full || (twin != "" && bare == twin) || ws.checked[ref] {
			continue
		}
		if kind == localBranch && !ws.known {
			continue
		}
		r.warn(kind + " " + name + " merged into " + r.base.label)
		if kind == localBranch {
			local++
		} else {
			remote++
		}
	}
	return "base " + r.base.label + ", " + strconv.Itoa(local) + " local, " + strconv.Itoa(remote) + " remote"
}

// The two WARN classes of the scan.
const (
	localBranch  = "merged-branch"
	remoteBranch = "merged-remote-branch"
)

// splitRef reads a full ref name: its display name (without refs/heads/ or refs/remotes/), the branch name without a
// remote, and which class it is. Anything else, and a remote's HEAD alias, is skipped (ok false).
func splitRef(ref string) (name, bare, kind string, ok bool) {
	switch {
	case strings.HasPrefix(ref, "refs/heads/"):
		name = strings.TrimPrefix(ref, "refs/heads/")
		return name, name, localBranch, true
	case strings.HasPrefix(ref, "refs/remotes/"):
		name = strings.TrimPrefix(ref, "refs/remotes/")
		var found bool
		if _, bare, found = strings.Cut(name, "/"); !found {
			bare = name
		}
		return name, bare, remoteBranch, bare != "HEAD"
	}
	return "", "", "", false
}

// twinName is the base's own branch name without refs/heads/ or refs/remotes/<remote>/ ("" for a hash or a tag).
func (b baseRef) twinName() string {
	switch {
	case strings.HasPrefix(b.full, "refs/remotes/"):
		_, rest, _ := strings.Cut(strings.TrimPrefix(b.full, "refs/remotes/"), "/")
		return rest
	case strings.HasPrefix(b.full, "refs/heads/"):
		return strings.TrimPrefix(b.full, "refs/heads/")
	}
	return ""
}
