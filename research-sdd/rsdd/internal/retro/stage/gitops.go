package stage

import (
	"errors"
	"path/filepath"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/git"
)

// targetRoot is the directory that holds the retros/ directory, as the script computed it for `git -C`:
// two levels above the retro, logical (symlinks not followed), made absolute.
func (s *stager) targetRoot() string {
	root := filepath.Dir(filepath.Dir(s.retro))
	if !filepath.IsAbs(root) {
		root = filepath.Join(s.o.Cwd, root)
	}
	return root
}

// retroAbs is the retro with its directory resolved physically. `git log -- <path>` must be given an absolute
// path: a relative one would be resolved against the rebased `-C` directory, miss a tracked retro and drop the
// sha silently. The physical form also makes a retro reached through a symlink match the kit root for the
// self-referential guard.
func (s *stager) retroAbs() string {
	dir := filepath.Dir(s.path)
	if real, err := filepath.EvalSymlinks(dir); err == nil {
		dir = real
	}
	return dir + "/" + filepath.Base(s.retro)
}

// trackedSHA is the abbreviated sha of the last commit of the target repo that touched the retro: the `@<sha>`
// of the Retro: trailer. "" (no suffix) when the retro is untracked or git cannot say.
func (s *stager) trackedSHA() string {
	out, err := s.git.Run(s.targetRoot(), "log", "-1", "--format=%h", "--", s.retroAbs())
	if err != nil {
		return ""
	}
	return strings.TrimRight(string(out), "\n")
}

// gitFailed prints the degraded line for a git call that could not answer and returns its exit code.
func (s *stager) gitFailed(what string, err error) int {
	if errors.Is(err, git.ErrMissing) {
		s.errf("degraded: git not found on PATH — cannot %s; nothing was changed.\n", what)
	} else {
		s.errf("degraded: git could not %s in %s (%v) — nothing was changed.\n", what, s.o.KitRoot, err)
	}
	return exitGitState
}

// preflight reads the state the run needs before it changes anything: the kit repo is a usable git repository
// with a clean tree, and the branch name is a valid ref. The script ran `git status` unchecked, so a kit root that
// was not a repository read as "clean" and the run failed later; and a name git refuses (a file called
// `a..b.md`, a target label with a `~`) was found only after the fetch.
func (s *stager) preflight() (int, bool) {
	out, err := s.git.Run(s.o.KitRoot, "status", "--porcelain")
	if err != nil {
		var ee *git.ExitError
		if errors.As(err, &ee) {
			s.errf("%s", ee.Stderr)
		}
		return s.gitFailed("read the state of the kit repo", err), true
	}
	if len(out) > 0 {
		s.errf("kit repo has uncommitted changes — commit/stash them first, then re-run.\n")
		return exitDirty, true
	}
	if _, err := s.git.Run(s.o.KitRoot, "check-ref-format", "refs/heads/"+s.branch); err != nil {
		var ee *git.ExitError
		if !errors.As(err, &ee) {
			return s.gitFailed("check the branch name", err), true
		}
		s.errf("stage-retro: '%s' is not a valid branch name (target '%s', file '%s') — nothing was changed; rename the retro file or register a plain target name.\n", s.branch, s.label, filepath.Base(s.retro))
		return exitBranch, true
	}
	return 0, false
}

// fetch is `git fetch -q origin`, bounded; on failure it returns git's own stderr to replay.
func (s *stager) fetch() (string, error) {
	r := s.git
	r.Timeout = s.o.FetchTimeout
	if r.Timeout == 0 {
		r.Timeout = DefaultFetchTimeout
	}
	_, err := r.Run(s.o.KitRoot, "fetch", "-q", "origin")
	if err == nil {
		return "", nil
	}
	var ee *git.ExitError
	if errors.As(err, &ee) {
		return ee.Stderr, err
	}
	return err.Error() + "\n", err
}

// head is where the kit checkout stands before the run: the branch name, or the commit when detached. The
// script switched to main first, whatever the checkout was on, and "switched back" to main on exit 8; the port
// never leaves the branch it was started on until the new branch is created, and returns to it.
type head struct {
	name     string
	detached bool
}

func (s *stager) currentHead() head {
	if out, err := s.git.Run(s.o.KitRoot, "symbolic-ref", "-q", "--short", "HEAD"); err == nil {
		if n := strings.TrimRight(string(out), "\n"); n != "" {
			return head{name: n}
		}
	}
	if out, err := s.git.Run(s.o.KitRoot, "rev-parse", "HEAD"); err == nil {
		if n := strings.TrimRight(string(out), "\n"); n != "" {
			return head{name: n, detached: true}
		}
	}
	return head{name: "main"}
}

// checkoutArgs returns to the head.
func (h head) checkoutArgs() []string {
	if h.detached {
		return []string{"checkout", "-q", "--detach", h.name}
	}
	return []string{"checkout", "-q", h.name}
}

func (h head) command(kitRoot string) string {
	if h.detached {
		return "git -C \"" + kitRoot + "\" checkout --detach " + h.name
	}
	return "git -C \"" + kitRoot + "\" checkout " + h.name
}

// checkout creates the branch from origin/main, or checks out the one that already exists. --no-track: origin/main
// never becomes the upstream (a bare `git push` could otherwise target main).
func (s *stager) checkout(orig head) (int, bool) {
	exists := true
	if _, err := s.git.Run(s.o.KitRoot, "show-ref", "--quiet", "refs/heads/"+s.branch); err != nil {
		exists = false
	}
	args := []string{"checkout", "-q", "--no-track", "-b", s.branch, "origin/main"}
	fail := "cannot create branch " + s.branch + " from origin/main"
	if exists {
		s.outf("branch %s already exists — checking it out.\n", s.branch)
		args = []string{"checkout", "-q", s.branch}
		fail = "cannot check out existing branch " + s.branch
	}
	if _, err := s.git.Run(s.o.KitRoot, args...); err != nil {
		var ee *git.ExitError
		if errors.As(err, &ee) {
			s.errf("%s", ee.Stderr)
		}
		s.errf("%s\n", fail)
		return exitBranch, true
	}
	s.orig = orig
	return 0, false
}

// retroGone is the defensive re-check after the checkout: a pre-existing branch can predate the retro, so the
// checkout makes it vanish from the worktree even though origin/main holds it. Back to the starting point first:
// `git branch -D` refuses to delete the checked-out branch, and the advice below says to delete it.
func (s *stager) retroGone() int {
	s.errf("retro file %s is not readable on branch %s after checkout — refusing to\nprint stale/empty deltas.\n", s.retro, s.branch)
	if _, err := s.git.Run(s.o.KitRoot, s.orig.checkoutArgs()...); err == nil {
		s.errf("Switched back to %s. If %s is a stale leftover branch that predates this retro,\n", s.orig.name, s.branch)
	} else {
		s.errf("Could NOT switch back to %s (the checkout failed) — the repo is still on %s.\n", s.orig.name, s.branch)
		s.errf("If %s is a stale leftover branch that predates this retro,\n", s.branch)
	}
	s.errf("delete it: %s && git -C \"%s\" branch -D %s\n", s.orig.command(s.o.KitRoot), s.o.KitRoot, s.branch)
	return exitStaleRetro
}
