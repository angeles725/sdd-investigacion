package prpipeline

import (
	"fmt"
	"os/exec"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/kitmaint"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/probe"
)

// Typed exit states of this step group (the pipeline's table, registered in reason-codes.d/kit-pr-pipeline.md).
const (
	exitRestackConflict = 11
	exitPushFailed      = 12
	exitFetchFailed     = 21
	exitBadBaseRef      = 23
	exitDirtyTree       = 24
	exitRestackError    = 25
	exitSizeCheck       = 20
)

// relay passes a child's output on, as the bash children inherited stdout and stderr.
func (p *pipeline) relay(r kitmaint.Res) {
	fmt.Fprint(p.s.Out, r.Out)
	fmt.Fprint(p.s.Err, r.Err)
}

// retryGit is `kit_retry 3 git ARGS` run in the worktree: attempt notes and the child's stderr go to stderr, its
// stdout to stdout.
func (p *pipeline) retryGit(args ...string) kitmaint.Res {
	words := "git " + strings.Join(args, " ")
	r := p.kr.Retry(tool, 3, words, false, func() kitmaint.Res { return p.kr.Git(p.wt, args...) })
	fmt.Fprint(p.s.Out, r.Out)
	return r
}

// restack is step 1: stop on a dirty tree, fetch, and merge the base in only when the branch is behind it.
// It returns (code, true) when the pipeline stops here.
func (p *pipeline) restack() (int, bool) {
	o := p.o
	st := p.kr.Git(p.wt, "status", "--porcelain", "--untracked-files=no")
	if st.RC != 0 {
		// the bash read a failing `git status` as an empty (clean) tree
		p.relay(kitmaint.Res{Err: st.Err})
		return p.fail(exitRestackError, "restack-error", "#%s: git status failed (rc=%d); the tree could not be judged clean", o.pr, st.RC), true
	}
	if strings.TrimRight(st.Out, "\n") != "" {
		return p.fail(exitDirtyTree, "dirty-tree", "#%s: tracked files have uncommitted changes; commit or stash them", o.pr), true
	}
	if !p.retryGit("fetch", "-q", o.remote).OK() {
		return p.fail(exitFetchFailed, "fetch-failed", "git fetch %s failed after 3 tries (#%s)", o.remote, o.pr), true
	}
	anc := p.kr.Git(p.wt, "merge-base", "--is-ancestor", o.base, "HEAD")
	p.relay(kitmaint.Res{Err: anc.Err})
	if anc.RC > 1 {
		return p.fail(exitBadBaseRef, "bad-base-ref", "#%s: %s does not resolve (git merge-base rc=%d)", o.pr, o.base, anc.RC), true
	}
	if anc.RC == 1 {
		m := p.kr.Git(p.wt, "merge", "-q", "--no-edit", o.base)
		p.relay(m)
		if !m.OK() {
			return p.mergeFailed(), true
		}
	}
	return 0, false
}

// mergeFailed tells a conflict (aborted, nothing pushed) from a merge that failed for another reason.
func (p *pipeline) mergeFailed() int {
	o := p.o
	if u := p.kr.Git(p.wt, "ls-files", "-u"); strings.TrimRight(u.Out, "\n") != "" {
		p.relay(p.kr.Git(p.wt, "merge", "--abort"))
		return p.fail(exitRestackConflict, "restack-conflict", "#%s does not merge cleanly onto %s; the merge was aborted", o.pr, o.base)
	}
	return p.fail(exitRestackError, "restack-error", "#%s: merging %s failed without a conflict; resolve by hand", o.pr, o.base)
}

// push is step 2.
func (p *pipeline) push() (int, bool) {
	o := p.o
	if !p.retryGit("push", "-q", o.remote, "HEAD:"+o.branch).OK() {
		return p.fail(exitPushFailed, "push-failed", "git push %s HEAD:%s failed after 3 tries (#%s)", o.remote, o.branch, o.pr), true
	}
	head := strings.TrimRight(p.kr.Git(p.wt, "rev-parse", "--short", "HEAD").Out, "\n")
	p.say("head %s", head)
	return 0, false
}

// sizeCheck is step 3: the optional hook, `bash -c CMD` in the worktree with KIT_PR and KIT_WORKTREE set.
func (p *pipeline) sizeCheck() (int, bool) {
	o := p.o
	if o.sizeCheck == "" {
		return 0, false
	}
	bash, err := probe.New(p.env, p.wt).LookPath("bash")
	if err != nil {
		return p.fail(exitSizeCheck, "size-check-failed", "--size-check could not run: bash is not on PATH (#%s)", o.pr), true
	}
	c := exec.Command(bash, "-c", o.sizeCheck)
	c.Dir = p.wt
	c.Env = append(append([]string(nil), p.env...), "KIT_PR="+o.pr, "KIT_WORKTREE="+p.wt, "PWD="+p.wt)
	c.Stdout, c.Stderr = p.s.Out, p.s.Err
	if err := c.Run(); err != nil {
		return p.fail(exitSizeCheck, "size-check-failed", "--size-check exited non-zero (#%s)", o.pr), true
	}
	return 0, false
}
