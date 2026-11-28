// Package reviewslices is `rsdd lint review-slices`, the port of toolbelt/plan-review-slices.sh (kit issue #1276): it
// plans reviewable slices of merge-base(BASE,HEAD)..HEAD. It walks the first-parent commits oldest first, counts the
// authored changed lines of each (additions + deletions of `git diff --numstat` against the commit's first parent) and
// groups CONSECUTIVE commits greedily into slices of at most --max-lines, cutting only at commit boundaries. A single
// commit over the budget is never cut: it is its own slice, typed UNSPLITTABLE. Report-only: it runs git and creates
// no branch, ref or file.
//
// The output, the typed states and the exit codes (0 plan or EMPTY-RANGE, 2 usage / not a repository / bad ref /
// unreadable git answer, 3 git missing) are the script's, byte for byte, and are pinned by a differential test against
// the frozen script (testdata/legacy). The intended divergences (listed in tool-registry.d/plan-review-slices.md, each
// pinned by a scenario that also proves the script differs): a --max-lines above int64 is refused (see maxLines), awk
// is no longer a dependency (the script printed lines=0 without it), a numstat count beyond int64 is malformed.
//
// The git calls are the script's, one question each: a failure of any one is its own typed exit 2, and no failed lookup
// ever reads as a root commit. The per-commit questions run four at a time and are consumed in commit order (walk.go).
package reviewslices

import (
	"fmt"
	"io"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/kitmaint"
)

// exitDegraded is the script's exit for a missing git (stdout DEGRADED line, nothing on stderr).
const exitDegraded = 3

// Run is `rsdd lint review-slices`. Every message, including the errors, goes to stdout, as the script printed them.
func Run(args []string, s cli.Stdio) int {
	env := gitEnv(s)
	if len(kitmaint.MissingDeps(env, s.Cwd, "git")) > 0 {
		fmt.Fprintln(s.Out, "DEGRADED: git not found — cannot plan slices")
		return exitDegraded
	}
	o, msg := parse(args)
	if msg != "" {
		return refuse(s, msg)
	}
	if o.cwd == "" || !kitmaint.IsDir(kitmaint.Abs(s.Cwd, o.cwd)) {
		return refuse(s, fmt.Sprintf("plan-review-slices: --cwd '%s' is not a directory", o.cwd))
	}
	runner := &kitmaint.Runner{Env: env, Cwd: s.Cwd, Now: s.Clock, Err: io.Discard, Getenv: s.Env}
	// git is `git -C <cwd>`; its answer is the trimmed stdout, the way $(...) reads it.
	git := func(a ...string) (string, bool) {
		r := runner.Git(o.cwd, a...)
		return strings.TrimRight(r.Out, "\n"), r.OK()
	}
	if _, ok := git("rev-parse", "--git-dir"); !ok {
		return refuse(s, fmt.Sprintf("plan-review-slices: '%s' is not a git repository", o.cwd))
	}
	if _, ok := git("rev-parse", "--verify", "--quiet", o.base+"^{commit}"); !ok {
		return refuse(s, fmt.Sprintf("plan-review-slices: base ref '%s' does not resolve to a commit (pass --base-ref)", o.base))
	}
	mb, ok := git("merge-base", o.base, "HEAD")
	if !ok || mb == "" {
		return refuse(s, fmt.Sprintf("plan-review-slices: no merge-base between '%s' and HEAD (unrelated or shallow history)", o.base))
	}
	// stderr is deliberately not part of what is parsed: a git warning must never become a "commit".
	listed, ok := git("rev-list", "--first-parent", "--reverse", mb+"..HEAD")
	if !ok {
		return refuse(s, fmt.Sprintf("plan-review-slices: git rev-list failed for %s..HEAD", mb))
	}
	commits := strings.Fields(listed)
	if len(commits) == 0 {
		fmt.Fprintf(s.Out, "EMPTY-RANGE base=%s\n", o.base)
		return cli.ExitOK
	}
	p := &planner{max: o.max, out: s.Out}
	failed := ""
	measureAll(git, commits, func(m commit, msg string) bool {
		if msg != "" {
			failed = msg
			return false
		}
		p.add(m)
		return true
	})
	if failed != "" {
		return refuse(s, failed)
	}
	p.finish()
	return cli.ExitOK
}

// refuse prints a typed failure on stdout (the script's channel) and returns exit 2.
func refuse(s cli.Stdio, msg string) int {
	fmt.Fprintln(s.Out, msg)
	return cli.ExitUsage
}

func firstLine(s string) string {
	l, _, _ := strings.Cut(s, "\n")
	return l
}

// gitEnv is the environment of every git run: the caller's, minus the four variables the script unset (they would
// point git at another repository than --cwd). A Stdio without Environ (a golden case) carries only its Env.
func gitEnv(s cli.Stdio) []string {
	env := s.Environment()
	if env == nil {
		return []string{"PATH=" + s.Env("PATH")}
	}
	out := make([]string, 0, len(env))
	for _, kv := range env {
		switch k, _, _ := strings.Cut(kv, "="); k {
		case "GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR":
		default:
			out = append(out, kv)
		}
	}
	return out
}
