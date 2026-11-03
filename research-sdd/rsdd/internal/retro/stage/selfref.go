package stage

import "strings"

// localMain is the branch the guard compares with origin/main. The script checked it out before the guard, so
// "HEAD" was main; the port does not switch branches, so it names the branch.
const localMain = "main"

// guardSelfReference is the self-referential-target guard. TARGETS.md can list the kit repo itself as a research
// target, so a retro may live INSIDE the kit repo. The branch is created from origin/main, which replaces the
// whole working tree: a retro that origin/main does not hold with the SAME content would vanish from the disk the
// instant the branch is checked out. Comparing blob shas, not just presence, also catches a retro that origin/main
// holds from an earlier push while the local one has since changed. It runs after the fetch and before any
// checkout, and refuses with exit 7 and advice worded per case.
func (s *stager) guardSelfReference() (int, bool) {
	abs := s.retroAbs()
	if !strings.HasPrefix(abs, s.o.KitRoot+"/") {
		return 0, false
	}
	rel := strings.TrimPrefix(abs, s.o.KitRoot+"/")
	originBlob := s.revParse("origin/main:" + rel)
	headBlob := s.revParse(localMain + ":" + rel)
	if originBlob != "" && originBlob == headBlob {
		return 0, false
	}
	kit := s.o.KitRoot
	s.errf("this retro lives inside the kit repo itself (%s) and origin/main does\n", rel)
	s.errf("not have the SAME content as the local commit — staging would branch from origin/main\n")
	s.errf("and silently stage a stale (or entirely missing) version of this file.\n")
	// The advice is worded per case: "push origin main" is wrong when the retro is not on local main at all, or
	// when origin is the side that is ahead.
	switch {
	case headBlob == "" && originBlob != "" && s.isAncestor(localMain, "origin/main"):
		s.errf("origin/main is AHEAD of local main: it has this retro, local main does not. Fast-forward\n")
		s.errf("local main first:  git -C \"%s\" merge --ff-only origin/main\n", kit)
	case headBlob == "" && originBlob != "":
		s.errf("local main and origin/main have DIVERGED: origin/main has this retro, local main does not.\n")
		s.errf("Reconcile them (rebase or merge origin/main into local main), then re-stage.\n")
	case headBlob == "":
		s.errf("this retro exists only on another branch (or is untracked): it is not committed on local\n")
		s.errf("main. Commit/merge it onto main first, then push:  git -C \"%s\" push origin main\n", kit)
	case s.isAncestor("origin/main", localMain):
		s.errf("local main is AHEAD of origin/main. Push it first:  git -C \"%s\" push origin main\n", kit)
	case s.isAncestor(localMain, "origin/main"):
		s.errf("origin/main is AHEAD of local main. Fast-forward local main first:\n")
		s.errf("    git -C \"%s\" merge --ff-only origin/main\n", kit)
	default:
		s.errf("local main and origin/main have DIVERGED for this file. Reconcile them (rebase or merge),\n")
		s.errf("then push, before staging.\n")
	}
	s.errf("...then re-run stage-retro.sh.\n")
	return exitSelfRef, true
}

// revParse is `git rev-parse -q --verify <spec>`: the object name, "" when there is none (or git cannot say,
// which refuses the staging: the safe direction).
func (s *stager) revParse(spec string) string {
	out, err := s.git.Run(s.o.KitRoot, "rev-parse", "-q", "--verify", spec)
	if err != nil {
		return ""
	}
	return strings.TrimRight(string(out), "\n")
}

func (s *stager) isAncestor(a, b string) bool {
	ok, err := s.git.IsAncestor(s.o.KitRoot, a, b)
	return err == nil && ok
}
