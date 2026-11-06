package gate

import (
	"bytes"
	"fmt"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// RunMerge is `rsdd gate merge`, the port of toolbelt/merge-gate.sh (kit issue #1272, closure evidence #1812,
// CI gate #1426, path filters #1867): never merge a review-due candidate before its review. The script's header,
// kept as the frozen oracle under testdata/legacy until phase 8, is the reference for the contract:
//
//	merge-gate --cwd <repo|worktree> --base-ref <ref> [--head <sha>] [--pr <PR#> | --merge <PR#>]
//	           [--required-checks <a,b,...>] [--no-closure-evidence]
//
// One typed verdict line per run on stdout (`merged:` and `closure-evidence:` lines follow an allow under
// --merge). Exit 0 allow/merged, 1 refuse, 2 usage, 3 degraded. A broken instrument NEVER allows: a missing
// git/jq/gentle-ai, a failing assess, an unparseable or off-schema answer, an unknown not-due reason and an
// unreadable PR head are all degraded, never allow. Every degraded verdict is also written to stderr as one
// `DEGRADED: <why>` line, which the rsdd process contract (cli.Run) requires of an exit 3; the bash printed
// nothing there.
//
// Deliberate differences from the bash, each pinned by a test:
//   - a REQUIRED check must conclude `success`: one whose latest run concluded skipped or neutral is refused as
//     `ci_skipped (names)` where the bash allowed it (skipped and neutral stay green for non-required checks);
//     precedence ci_failed, ci_pending, ci_skipped, ci_missing (mergeciverdict.go, TestCISkippedRequiredDiverges);
//   - jq is still probed (a missing jq stays `degraded: jq not found on PATH`) but the JSON is read in-process;
//   - mktemp is not needed, so the `degraded: mktemp failed` verdict has no counterpart;
//   - the closure-evidence step needs no lib/gh-visibility.sh: `degraded: lib/gh-visibility.sh not found`, the
//     lib's watchdog note (` [DEGRADED: ...]`) and the CALLER_SIGNALLED state have no counterpart, and
//     MERGE_GATE_LIB is ignored; the bound itself (MERGE_GATE_GH_TIMEOUT, default 30 s) is unchanged;
//   - git is bounded (30 s), and the unbounded gh and gentle-ai calls get a one-hour ceiling;
//   - `gh pr merge` output is the stdout followed by the stderr, the bash interleaves the two as written;
//   - `--merge ""` (an empty PR number) never reads an unset base tree: a missing path-filter verdict stays
//     required without the bash's `unbound variable` stderr line;
//   - the sorted list of test files uses byte order, the bash sorts in the caller's locale (C.UTF-8 in the kit).
func RunMerge(args []string, s cli.Stdio) int {
	return runMerge(args, s, osMgRunner{s: s})
}

// mgCmd is one finished external command.
type mgCmd struct {
	Stdout, Stderr []byte
	RC             int  // the shell's exit code: 124 timed out, 127 not runnable
	Timeout        bool // the bound expired
}

// mgRunner is every process the gate starts.
type mgRunner interface {
	// Has is `command -v <name>`.
	Has(name string) bool
	// Git is `git -C <dir> <args>`.
	Git(dir string, args ...string) mgCmd
	// GentleAI is `gentle-ai <args>`, unbounded.
	GentleAI(args ...string) mgCmd
	// GH is `(cd <dir> && gh <args>)` with the caller's environment, unbounded (the bash ghr).
	GH(dir string, args ...string) mgCmd
	// GHBounded is gh_bounded_run in <dir>: GH_REPO unset, bound MERGE_GATE_GH_TIMEOUT (30 s default).
	GHBounded(dir string, args ...string) mgCmd
}

type mergeGate struct {
	s   cli.Stdio
	r   mgRunner
	out *bytes.Buffer

	cwd, base, wantHead, pr string
	doMerge, noEvidence     bool
	required                string

	head, mb, prBase, reason string
}

func runMerge(args []string, s cli.Stdio, r mgRunner) int {
	g := &mergeGate{s: s, r: r, out: &bytes.Buffer{}}
	code := g.run(args)
	_, _ = s.Out.Write(g.out.Bytes())
	return code
}

func (g *mergeGate) say(format string, a ...any) {
	fmt.Fprintf(g.out, "merge-gate: %s\n", fmt.Sprintf(format, a...))
}

func (g *mergeGate) usage(why string) int {
	g.say("usage: %s", why)
	fmt.Fprintln(g.s.Err, mergeUsageLine)
	return cli.ExitUsage
}

func (g *mergeGate) degraded(why string) int {
	g.say("degraded: %s", why)
	fmt.Fprintf(g.s.Err, "DEGRADED: %s\n", why)
	return cli.ExitDegraded
}

// git runs `git -C cwd args` and returns its stdout with a status of 0 only on success.
func (g *mergeGate) git(args ...string) (string, bool) {
	c := g.r.Git(g.cwd, args...)
	return cmdSub(string(c.Stdout)), c.RC == 0
}

func (g *mergeGate) run(args []string) int {
	if code, ok := g.parseArgs(args); !ok {
		return code
	}

	// Probes: every runtime dependency is checked up front (typed degraded, never a silent pass).
	for _, tool := range []string{"git", "jq", "gentle-ai"} {
		if !g.r.Has(tool) {
			return g.degraded(tool + " not found on PATH")
		}
	}
	if g.pr != "" && !g.r.Has("gh") {
		return g.degraded("gh not found on PATH (needed for --pr/--merge)")
	}

	if _, ok := g.git("rev-parse", "--git-dir"); !ok {
		return g.degraded("--cwd is not a git repo/worktree: " + g.cwd)
	}
	var ok bool
	if g.head, ok = g.git("rev-parse", "--verify", "HEAD"); !ok {
		return g.degraded("cannot resolve HEAD in " + g.cwd)
	}
	if _, ok = g.git("rev-parse", "--verify", "--quiet", g.base+"^{commit}"); !ok {
		return g.degraded("base-ref does not resolve to a commit: " + g.base)
	}

	if g.wantHead != "" {
		full, ok := g.git("rev-parse", "--verify", "--quiet", g.wantHead+"^{commit}")
		if !ok {
			return g.degraded("--head does not resolve to a commit: " + g.wantHead)
		}
		if full != g.head {
			g.say("refuse: head_mismatch (--head %s != worktree HEAD %s)", full, g.head)
			return cli.ExitOperational
		}
	}

	// Assess from the MERGE-BASE, never a moving ref: base-ref may have advanced past the branch point with
	// unrelated changes, which would make the assessed range include commits that are not ours.
	if g.mb, ok = g.git("merge-base", "HEAD", g.base); !ok || g.mb == "" {
		return g.degraded("no common ancestor between HEAD and base-ref: " + g.base)
	}
	ahead, ok := g.git("rev-list", "--count", g.mb+"..HEAD")
	if !ok || ahead == "" || !allDigits(ahead) {
		return g.degraded("cannot count commits in " + g.mb + "..HEAD")
	}
	if strings.Trim(ahead, "0") == "" {
		return g.degraded("empty range (nothing to merge): " + g.mb + "..HEAD has 0 commits")
	}

	// --pr/--merge: bind the assessed range to the PR. The caller-chosen base must start at or before the PR's
	// branch point, otherwise a narrow base would hide unreviewed commits of the same PR.
	if g.pr != "" {
		if code, done := g.bindPR(); done {
			return code
		}
	}

	if code, done := g.assess(); done {
		return code
	}
	return g.finish()
}
