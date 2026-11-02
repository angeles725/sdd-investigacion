package gate

import (
	"bytes"
	"encoding/json"
	"fmt"
	"strconv"
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

const mergeUsageLine = "usage: merge-gate.sh --cwd <dir> --base-ref <ref> [--head <sha>] [--pr <PR#> | --merge <PR#>] [--required-checks <a,b,...>] [--no-closure-evidence]"

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

// environLookup is `${KEY+x}` / `$KEY` over environ: the last entry wins.
func environLookup(environ []string, key string) (string, bool) {
	for i := len(environ) - 1; i >= 0; i-- {
		if v, ok := strings.CutPrefix(environ[i], key+"="); ok {
			return v, true
		}
	}
	return "", false
}

// allDigits is the negation of `*[!0-9]*` for a non-empty string.
func allDigits(s string) bool { return strings.Trim(s, "0123456789") == "" }

// parseArgs reads the flags as the bash loop does: a flag that needs a value takes the next word whatever it
// looks like, the last occurrence wins, and --merge sets the PR number and the merge flag together.
func (g *mergeGate) parseArgs(args []string) (code int, ok bool) {
	g.required = "shellcheck,toolbelt-tests"
	if v, set := environLookup(g.s.Environ(), "MERGE_GATE_REQUIRED_CHECKS"); set { // set-but-empty = opt-out
		g.required = v
	}
	value := func(i int) (string, bool) {
		if i+1 >= len(args) {
			return "", false
		}
		return args[i+1], true
	}
	for i := 0; i < len(args); {
		switch args[i] {
		case "--pr", "--cwd", "--base-ref", "--head", "--merge", "--required-checks":
			why := map[string]string{
				"--pr":              "--pr needs a PR number",
				"--cwd":             "--cwd needs a value",
				"--base-ref":        "--base-ref needs a value",
				"--head":            "--head needs a value",
				"--merge":           "--merge needs a PR number",
				"--required-checks": `--required-checks needs a value (use "" to opt out)`,
			}[args[i]]
			v, has := value(i)
			if !has {
				return g.usage(why), false
			}
			switch args[i] {
			case "--pr":
				g.pr = v
			case "--cwd":
				g.cwd = v
			case "--base-ref":
				g.base = v
			case "--head":
				g.wantHead = v
			case "--merge":
				g.pr, g.doMerge = v, true
			case "--required-checks":
				g.required = v
			}
			i += 2
		case "--no-closure-evidence":
			g.noEvidence = true
			i++
		default:
			return g.usage("unknown argument: " + args[i]), false
		}
	}
	if g.cwd == "" {
		return g.usage("--cwd is required"), false
	}
	if g.base == "" {
		return g.usage("--base-ref is required"), false
	}
	if g.pr != "" && !allDigits(g.pr) {
		return g.usage("--pr/--merge needs a numeric PR number, got: " + g.pr), false
	}
	return 0, true
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

// bindPR reads the PR head and base over REST (`gh pr view --json` has no baseRefOid in gh 2.45, kit issue
// #1272 F1) and refuses a head or range that is not the PR's.
func (g *mergeGate) bindPR() (code int, done bool) {
	c := g.r.GH(g.cwd, "api", "repos/{owner}/{repo}/pulls/"+g.pr, "--jq", "{headRefOid:.head.sha, baseRefOid:.base.sha, baseRefName:.base.ref}")
	prJSON := ""
	if c.RC == 0 {
		prJSON = cmdSub(string(c.Stdout))
	}
	if prJSON == "" {
		return g.degraded("cannot read PR #" + g.pr + " (gh api failed)"), true
	}
	vals, _ := jqStream(prJSON)
	prHead := jqEach(vals, jqOptKey("headRefOid"))
	if prHead == "" {
		return g.degraded("cannot read PR #" + g.pr + " head (no headRefOid)"), true
	}
	if prHead != g.head {
		g.say("refuse: head_mismatch (PR #%s head %s != checked HEAD %s)", g.pr, prHead, g.head)
		return cli.ExitOperational, true
	}
	g.prBase = jqEach(vals, jqOptKey("baseRefOid"))
	if g.prBase == "" {
		return g.degraded("cannot read PR #" + g.pr + " base (no baseRefOid)"), true
	}
	if _, ok := g.git("cat-file", "-e", g.prBase+"^{commit}"); !ok {
		return g.degraded("PR #" + g.pr + " base " + g.prBase + " is not present locally (git fetch first)"), true
	}
	prMB, ok := g.git("merge-base", "HEAD", g.prBase)
	if !ok {
		return g.degraded("no common ancestor between HEAD and PR #" + g.pr + " base"), true
	}
	if _, isAncestor := g.git("merge-base", "--is-ancestor", g.mb, prMB); !isAncestor {
		g.say("refuse: base_excludes_pr_commits (assessed range starts at %s, after the PR branch point %s) — use the PR base as --base-ref", g.mb, prMB)
		return cli.ExitOperational, true
	}
	return 0, false
}

// firstLine is `head -n 1 | cut -c1-200` over captured stderr: the first line, cut to 200 bytes.
func firstLine(b []byte, max int) string {
	l, _, _ := strings.Cut(stripNUL(string(b)), "\n")
	if len(l) > max {
		l = l[:max]
	}
	return l
}

// containsFold is `grep -qi`, ASCII case folding only.
func containsFold(s, sub string) bool {
	return strings.Contains(asciiLower(s), asciiLower(sub))
}

func asciiLower(s string) string {
	b := []byte(s)
	for i, c := range b {
		if c >= 'A' && c <= 'Z' {
			b[i] = c + 'a' - 'A'
		}
	}
	return string(b)
}

// assess asks gentle-ai and refuses on review_due. Its own answer is trusted: this gate re-implements none of
// the "this exact range was acknowledged" logic, and a non-zero assess is degraded even when its stdout happens
// to look like an allow.
func (g *mergeGate) assess() (code int, done bool) {
	c := g.r.GentleAI("review", "assess", "--cwd", g.cwd, "--base-ref", g.mb, "--committed-only", "--json")
	if c.RC != 0 {
		// Surface gentle-ai's own first error line, plus our own hint for the common untracked-files cause.
		errLine := cmdSub(firstLine(c.Stderr, 200))
		hint := ""
		if containsFold(string(c.Stderr), "untracked") {
			hint = " — clean or ignore untracked files in " + g.cwd + " and retry"
		}
		why := "gentle-ai review assess failed (exit " + strconv.Itoa(c.RC) + ")"
		if errLine != "" {
			why += ": " + errLine
		}
		return g.degraded(why + hint), true
	}
	headAfter, _ := g.git("rev-parse", "--verify", "HEAD")
	if headAfter != g.head {
		after := headAfter
		if after == "" {
			after = "unknown"
		}
		return g.degraded("HEAD moved during assess (" + g.head + " -> " + after + "); rerun"), true
	}

	vals, ok := jqStream(string(c.Stdout))
	if !hookReadable(vals, ok) { // `jq -e .`
		return g.degraded("assess output is unparseable JSON"), true
	}
	schema := jqEach(vals, jqOptKey("schema"))
	if schema != "gentle-ai.review-assessment/v1" {
		if schema == "" {
			schema = "<none>"
		}
		return g.degraded("unexpected assess schema: " + schema), true
	}
	due := jqEach(vals, func(v json.RawMessage) (string, bool) {
		f, ok := jqIndex(v, "review_due")
		if !ok {
			return "", false
		}
		if jqType(f) == "boolean" {
			return jqRaw(f), true
		}
		return "invalid", true
	})
	if due != "true" && due != "false" {
		return g.degraded("assess review_due is missing or not a boolean"), true
	}
	reason := jqEach(vals, jqOptKey("review_due_reason"))
	if reason == "" {
		return g.degraded("assess review_due_reason is missing"), true
	}
	if due == "true" {
		g.say("refuse: review_due (%s) (head=%s base=%s merge_base=%s) — review this exact head before merging", reason, g.head, g.base, g.mb)
		return cli.ExitOperational, true
	}
	switch reason {
	case "passive", "already_reviewed", "under_budget":
	default:
		return g.degraded("unknown not-due reason from gentle-ai: " + reason + " (refusing to guess)"), true
	}
	g.reason = reason
	return 0, false
}
