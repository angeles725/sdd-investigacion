package cleancheck

import "testing"

// The base and its twin on the other side (local main for origin/main) are never reported as merged into the base;
// the other merged branches are, once as a local and once as a remote one.
func TestBaseAndItsTwinAreNotReported(t *testing.T) {
	w := newWorld(t)
	keep(w, "")
	withOrigin(w)
	w.git("checkout", "-q", "r-ahead") // main is no longer checked out, so only the twin rule can hide it
	r := w.check()
	for _, want := range []string{
		"WARN merged-branch r-merged merged into origin/main",
		"WARN merged-remote-branch origin/r-merged merged into origin/main",
	} {
		if !has(r, want) {
			t.Errorf("missing %q:\n%s", want, w.dump(r))
		}
	}
	if r.Warnings != 2 {
		t.Errorf("only the two merged r-merged refs are reported, got %d warnings:\n%s", r.Warnings, w.dump(r))
	}
	for _, l := range r.Lines {
		if l.Text == "WARN merged-branch main merged into origin/main" || l.Text == "WARN merged-remote-branch origin/main merged into origin/main" {
			t.Errorf("the base or its twin was reported: %q", l.Text)
		}
	}
}

// The first worktree git lists is the main one and is never judged, even when its path is gone; a later one that is
// gone is stale. Git is stubbed because a repository cannot be made to list a missing main worktree.
func TestMainWorktreeIsNeverStale(t *testing.T) {
	w := newWorld(t)
	keep(w, "")
	listing := "worktree /nonexistent/main\\0HEAD 0\\0branch refs/heads/main\\0\\0worktree " + w.root + "/gone\\0HEAD 0\\0branch refs/heads/gone\\0"
	w.stubRules(rule{match: "worktree list --porcelain -z", out: listing})
	r := w.check()
	if !has(r, "WARN stale-worktree "+w.root+"/gone missing") {
		t.Errorf("a later missing worktree is stale:\n%s", w.dump(r))
	}
	if hasPrefix(r, "WARN stale-worktree /nonexistent") {
		t.Errorf("the main worktree was judged:\n%s", w.dump(r))
	}
	if r.Warnings != 1 || !hasPrefix(r, "CLEAN-CHECK: ") {
		t.Errorf("%d warnings:\n%s", r.Warnings, w.dump(r))
	}
}

// -iname folds ASCII only, and both ends of A-Z fold.
func TestAsciiFoldEnds(t *testing.T) {
	if got := asciiFold("AZaz@[`{"); got != "azaz@[`{" {
		t.Errorf("asciiFold = %q", got)
	}
}
