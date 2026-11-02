package verify

import (
	"errors"
	"fmt"
	"io"
	"os"
	"path"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/git"
)

// Port of research-sdd/toolbelt/verify-kit-clean.sh: is the kit repo clean, committed and pushed?
//
//	rsdd verify kit-clean [<kit-repo>]
//
// Exit: 0 clean (or no upstream to push to) - 1 dirty, unpushed commits or `git status` failed - 2 not a git
// repo or bad arguments. The report text is byte-identical to the script's. Differences, by design:
//
//   - The script's default repository is its own directory; a binary cannot see that, so the shim passes it
//     explicitly. With no argument (or an empty one, as `${1:-$here}` treats it) the default here is the
//     working directory.
//   - The script hands git the caller's whole environment; cli.Stdio only offers key reads, so git gets the
//     keys in gitEnvKeys (plus GIT_OPTIONAL_LOCKS=0), and nothing else.
//   - Every git run is bounded (core/git). A run that cannot finish is reported like a failed one, with the
//     shell's code: 127 git not found, 124 timeout.
//   - git not found is, in the script, "not a git repo" (command substitution rc 127). Here the same exit 2
//     and message follow a typed `degraded: git unavailable` line on stderr, so a missing git never reads as
//     a mere non-repository.
//   - The "count FAILED" WARNs of the script report a `grep -c` that exited >= 2. Counting lines cannot fail
//     here, so those branches do not exist.

// gitEnvKeys are the environment keys handed to git: what it needs to find itself, its configuration and its
// identity. GIT_OPTIONAL_LOCKS is not listed: it is always set to 0 (kit issue #1820), never inherited.
// TODO(#2387): replace the fixed key list with the cli.Stdio Environ accessor.
var gitEnvKeys = []string{
	"PATH", "HOME", "USER", "LOGNAME", "LANG", "LC_ALL", "LC_CTYPE", "TZ", "TMPDIR",
	"XDG_CONFIG_HOME", "GIT_EXEC_PATH", "GIT_DIR", "GIT_WORK_TREE", "GIT_CEILING_DIRECTORIES",
	"GIT_CONFIG_GLOBAL", "GIT_CONFIG_SYSTEM", "GIT_CONFIG_NOSYSTEM", "GIT_CONFIG_PARAMETERS",
	"GIT_AUTHOR_NAME", "GIT_AUTHOR_EMAIL", "GIT_COMMITTER_NAME", "GIT_COMMITTER_EMAIL",
}

// gitTimeout bounds each git run; the script has no bound at all.
const gitTimeout = 60 * time.Second

func gitRunner(s cli.Stdio) git.Runner {
	env := []string{"GIT_OPTIONAL_LOCKS=0"}
	for _, k := range gitEnvKeys {
		if v := s.Env(k); v != "" {
			env = append(env, k+"="+v)
		}
	}
	return git.Runner{Env: append(env, gitConfigCountEnv(s)...), Timeout: gitTimeout, Now: s.Clock}
}

// maxGitConfigCount bounds how many GIT_CONFIG_KEY_<n>/GIT_CONFIG_VALUE_<n> pairs are read.
const maxGitConfigCount = 1000

// gitConfigCountEnv hands git GIT_CONFIG_COUNT together with every pair it counts: a count without its pairs
// makes git die ("missing config key"), which would read as "not a git repo". A count that is not a
// non-negative integer within the bound is passed alone, so git reports it exactly as it did for the script.
// Limit: cli.Stdio.Env cannot tell an empty value from an unset one (TODO(#2387)), so an empty
// GIT_CONFIG_VALUE_<n> is not passed and git reports that pair as missing.
func gitConfigCountEnv(s cli.Stdio) []string {
	raw := s.Env("GIT_CONFIG_COUNT")
	if raw == "" {
		return nil
	}
	env := []string{"GIT_CONFIG_COUNT=" + raw}
	n, err := strconv.Atoi(raw)
	if err != nil || n > maxGitConfigCount { // a negative n reads no pair: the loop below does not run
		return env
	}
	for i := 0; i < n; i++ {
		for _, k := range []string{"GIT_CONFIG_KEY_", "GIT_CONFIG_VALUE_"} {
			k += strconv.Itoa(i)
			if v := s.Env(k); v != "" {
				env = append(env, k+"="+v)
			}
		}
	}
	return env
}

// RunKitClean is the `verify kit-clean` command.
func RunKitClean(args []string, s cli.Stdio) int {
	return kitClean(repoArg(args), s.Cwd, s.Out, s.Err, gitRunner(s))
}

// repoArg is `${1:-default}`: the first argument unless it is missing or empty.
func repoArg(args []string) string {
	if len(args) > 0 {
		return args[0]
	}
	return ""
}

// sh is what `$(...)` leaves of git's stdout: trailing newlines cut. The stdout of a failed run counts, as in
// the script, which keeps whatever git printed before it failed.
func sh(out []byte) string { return strings.TrimRight(string(out), "\n") }

// shellRC is the code the shell would have seen for a failed run.
func shellRC(err error) int {
	var ee *git.ExitError
	switch {
	case errors.As(err, &ee):
		return ee.Code
	case errors.Is(err, git.ErrMissing):
		return 127
	case errors.Is(err, git.ErrTimeout):
		return 124
	}
	return 1
}

// countLines is `printf '%s\n' "$s" | grep -c .`: the lines holding at least one character.
func countLines(s string) int {
	n := 0
	for _, l := range strings.Split(s, "\n") {
		if l != "" {
			n++
		}
	}
	return n
}

func kitClean(repo, cwd string, out, errw io.Writer, g git.Runner) int {
	pr := func(format string, a ...any) { fmt.Fprintf(out, format+"\n", a...) }
	if repo == "" {
		repo = cwd
	}
	abs := repo
	if !filepath.IsAbs(abs) {
		abs = filepath.Join(cwd, abs)
	}
	if st, err := os.Stat(abs); err != nil || !st.IsDir() {
		fmt.Fprintln(errw, "usage: verify-kit-clean.sh [<kit-repo>]")
		return cli.ExitUsage
	}
	rootOut, err := g.Run(abs, "rev-parse", "--show-toplevel")
	if err != nil {
		if errors.Is(err, git.ErrMissing) {
			fmt.Fprintf(errw, "verify-kit-clean: degraded: git unavailable: %v\n", err)
		}
		fmt.Fprintf(errw, "verify-kit-clean: not a git repo: %s\n", repo)
		return cli.ExitUsage
	}
	root := sh(rootOut)
	branchOut, _ := g.Run(root, "rev-parse", "--abbrev-ref", "HEAD")
	branch := sh(branchOut)
	shown := branch
	if shown == "" {
		shown = "?"
	}
	pr("== verify-kit-clean: %s (branch: %s) ==", path.Base(root), shown)
	rc := 0

	// 1. Working tree: any staged / unstaged / untracked change makes it DIRTY.
	porcelain, err := g.Run(root, "status", "--porcelain")
	if err != nil {
		fmt.Fprintf(errw, "   git status failed (rc=%d) — cannot determine cleanliness\n", shellRC(err))
		return cli.ExitOperational
	}
	if sh(porcelain) != "" {
		stagedOut, _ := g.Run(root, "diff", "--cached", "--name-only")
		unstagedOut, _ := g.Run(root, "diff", "--name-only")
		untrackedOut, _ := g.Run(root, "ls-files", "--others", "--exclude-standard")
		staged, unstaged, untracked := countLines(sh(stagedOut)), countLines(sh(unstagedOut)), countLines(sh(untrackedOut))
		if staged == 0 && unstaged == 0 && untracked == 0 {
			pr("   WARN: DIRTY but all three counters read 0 — porcelain has %d line(s); counters disagree", countLines(sh(porcelain)))
		}
		pr("   working tree : DIRTY — uncommitted: %d staged · %d unstaged · %d untracked", staged, unstaged, untracked)
		rc = 1
	} else {
		pr("   working tree : CLEAN")
	}

	// 2. Sync: local commits not on the upstream would fold into a retro PR's squash (mixed history).
	// Prefer the configured tracking ref; with none, fall back to origin/<branch> when that remote branch exists.
	upOut, _ := g.Run(root, "rev-parse", "--abbrev-ref", "@{upstream}")
	upstream := sh(upOut)
	if upstream == "" && branch != "" && branch != "HEAD" {
		if _, err := g.Run(root, "rev-parse", "--verify", "-q", "origin/"+branch); err == nil {
			upstream = "origin/" + branch
		}
	}
	if upstream != "" {
		// `rev-list --count ... || echo 0`: a failed run leaves its stdout, then the 0 is appended.
		aheadOut, err := g.Run(root, "rev-list", "--count", upstream+"..HEAD")
		ahead := sh(aheadOut)
		if err != nil {
			ahead = sh([]byte(ahead + "\n0"))
		}
		if n, perr := strconv.Atoi(ahead); perr == nil && n > 0 {
			pr("   sync         : %s local commit(s) NOT pushed to %s", ahead, upstream)
			rc = 1
		} else {
			pr("   sync         : up to date with %s", upstream)
		}
	} else {
		head := branch
		if head == "" {
			head = "HEAD"
		}
		pr("   sync         : (no upstream configured for %s — nothing to be un-pushed against)", head)
	}

	// 3. Audits location (ADVISORY, §13 / PROMPT-AUDIT): audits are TARGET-scoped, so one at the repo root is
	// almost always mis-committed target evidence. It never changes the verdict or the exit code.
	if st, err := os.Stat(filepath.Join(root, "audits")); err == nil && st.IsDir() {
		pr("   WARN: audits/ exists at the kit/supervisor root — audits are TARGET-scoped only (§13 / PROMPT-AUDIT); this is likely mis-committed target evidence — relocate to <target>/audits/ or remove.")
	}

	if rc == 0 {
		pr("   verdict      : clean — safe to stage a retro / start clean kit work")
	} else {
		pr("   verdict      : NOT clean — commit/stash + push before staging a retro (else mixed history)")
	}
	pr("== exit %d ==", rc)
	return rc
}
