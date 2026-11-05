package secretscan

import (
	"os"
	"path/filepath"
	"strings"
)

// --committed scans ALL committed content reachable from HEAD: every unique file version across the whole history
// plus every commit object (so a secret deleted from HEAD but still reachable, or typed into a commit message or an
// author field, is found). It is what ensure-remote needs: what is scanned equals what a push would send.
// The two plumbing commands ignore every log.* user setting, and --no-replace-objects stops refs/replace from hiding
// a secret commit.

// cmdSub is `$(...)`: trailing newlines cut.
func cmdSub(s string) string { return strings.TrimRight(s, "\n") }

func physical(p string) (string, bool) {
	r, err := filepath.EvalSymlinks(p)
	if err != nil {
		return "", false
	}
	return r, true
}

// envValue reads KEY from a KEY=VALUE environment (the last entry wins).
func envValue(env []string, key string) string {
	v := ""
	for _, kv := range env {
		if rest, ok := strings.CutPrefix(kv, key+"="); ok {
			v = rest
		}
	}
	return v
}

// preflightHistory refuses (exit 3, typed) every state in which the scanned history could differ from what a push
// sends: no git, not a repository, no commit, a target below the repository root, grafts.
func (s *session) preflightHistory() *stop {
	t := s.req.Target
	if s.git == nil {
		g := s.req.Git
		if g == nil {
			var ok bool
			if g, ok = newExecGit(s.req.Env, s.req.Cwd); !ok {
				return s.fail(rcDegraded, "DEGRADED: git not found — --committed mode requires git")
			}
		}
		s.git = g
	}
	if _, rc := gitText(s.git, s.abs, "rev-parse", "--git-dir"); rc != 0 {
		return s.fail(rcDegraded, "DEGRADED: "+t+" is not a git repository — --committed mode requires a git repo")
	}
	if _, rc := gitText(s.git, s.abs, "rev-parse", "--verify", "HEAD"); rc != 0 {
		return s.fail(rcDegraded, "DEGRADED: "+t+" has no commits — --committed mode requires at least one commit")
	}
	top, _ := gitText(s.git, s.abs, "rev-parse", "--show-toplevel")
	top = cmdSub(top)
	targetReal, _ := physical(s.abs)
	topReal, ok := physical(top)
	if !ok || targetReal != topReal {
		return s.fail(rcDegraded, "DEGRADED: "+t+" is a subdirectory of its git repo (repo root: "+topReal+").\n"+
			"          Pass the repo root to scan the full committed history — pathspecs evaluated\n"+
			"          from a subdirectory silently miss all files outside "+targetReal+".")
	}
	common, _ := gitText(s.git, s.abs, "rev-parse", "--git-common-dir")
	if common = cmdSub(common); common != "" && !filepath.IsAbs(common) {
		common = topReal + "/" + common
	}
	if fi, err := os.Stat(common + "/info/grafts"); common != "" && err == nil && fi.Size() > 0 {
		return s.fail(rcDegraded, "DEGRADED: .git/info/grafts is non-empty — scan scope may diverge from what git push will send.\n"+
			"          Remove or empty .git/info/grafts before scanning.")
	}
	if envValue(s.req.Env, "GIT_GRAFT_FILE") != "" {
		return s.fail(rcDegraded, "DEGRADED: GIT_GRAFT_FILE is set — scan scope may diverge from what git push will send.\n"+
			"          Unset GIT_GRAFT_FILE before scanning.")
	}
	return nil
}
