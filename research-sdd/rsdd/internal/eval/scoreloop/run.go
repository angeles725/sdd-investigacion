package scoreloop

import (
	"errors"
	"fmt"
	"io"
	"os"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	gitrun "github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/git"
)

// Run is `rsdd eval score-loop --corpus <dir> [--transcript <jsonl>] [--base-ref <ref>] [--since <date>]
// [--until <date>]`: one `C<n> pass|fail|n/a|degraded <evidence>` line per criterion, then a SUMMARY line.
// Exit: 0 scored (criteria may be fail, n/a or degraded: this is an information instrument); 1 operational failure
// (corpus missing or not a git repository, `git log` failed); 2 bad arguments or environment; 3 degraded (git is
// unavailable, so no criterion can be measured at all).
func Run(args []string, s cli.Stdio) int {
	opt, exit, ok := parseArgs(args, s.Err)
	if !ok {
		return exit
	}
	if exit, ok = checkArgs(opt, s.Err); !ok {
		return exit
	}
	cfg, problem := loadConfig(s.Env)
	if problem != "" {
		fmt.Fprintln(s.Err, problem)
		return cli.ExitUsage
	}
	env := environ(s)
	git := gitrun.Runner{Env: env, Timeout: gitLogTimeout, Now: s.Clock}
	if _, err := git.Run("", "--version"); errors.Is(err, gitrun.ErrMissing) {
		return degradedNoGit(s)
	}
	if exit, ok = checkCorpus(git, opt.corpus, s.Err); !ok {
		return exit
	}
	facts := &Facts{}
	if opt.transcript != "" {
		facts = loadTranscript(opt.transcript, &cfg, newJQRunner(env))
	}
	win := &window{cfg: &cfg, git: git, corpus: opt.corpus, baseRef: opt.baseRef, errw: s.Err}
	since, until := opt.since, opt.until
	if !opt.windowExplicit && facts.HasSpan {
		since, until = facts.FirstISO, facts.LastISO // the default window is the transcript's own span
	}
	scan, err := win.scan(since, until)
	if err != nil {
		fmt.Fprintln(s.Err, err)
		return cli.ExitOperational
	}
	sc := &scorer{cfg: &cfg, opt: opt, facts: facts, win: win, rep: &report{}, blocks: scan.entries,
		nBlocks: totalWeight(scan.entries), examined: scan.examined, tsErrors: scan.tsErrors,
		status: newStatusRunner(env), statusScript: statusScriptPath(&cfg, opt, s.Env), corpus: opt.corpus}
	sc.c1()
	sc.c2()
	sc.c3()
	sc.c4()
	if sc.abort != nil {
		sc.rep.write(s.Out, false)
		fmt.Fprintln(s.Err, sc.abort)
		return cli.ExitOperational
	}
	sc.rep.write(s.Out, true)
	return cli.ExitOK
}

// environ is the whole environment the children (git, bash, jq) run in.
func environ(s cli.Stdio) []string {
	if s.Environ == nil {
		return nil
	}
	return s.Environ()
}

// checkArgs applies the legacy input checks: --corpus is required, and --transcript must be a regular file.
func checkArgs(opt options, errw io.Writer) (int, bool) {
	if opt.corpus == "" {
		fmt.Fprintf(errw, "%s: --corpus is required\n", scriptName)
		usage(errw)
		return cli.ExitUsage, false
	}
	if opt.transcript != "" {
		if fi, err := os.Stat(opt.transcript); err != nil || !fi.Mode().IsRegular() {
			fmt.Fprintf(errw, "%s: --transcript file not found: %s\n", scriptName, opt.transcript)
			return cli.ExitUsage, false
		}
	}
	return 0, true
}

// checkCorpus requires the corpus to be an existing directory inside a git work tree.
func checkCorpus(git gitrun.Runner, corpus string, errw io.Writer) (int, bool) {
	if fi, err := os.Stat(corpus); err != nil || !fi.IsDir() {
		fmt.Fprintf(errw, "%s: corpus not found or not a directory: %s\n", scriptName, corpus)
		return cli.ExitOperational, false
	}
	if _, err := git.Run(corpus, "rev-parse", "--is-inside-work-tree"); err != nil {
		fmt.Fprintf(errw, "%s: corpus is not a git repository: %s\n", scriptName, corpus)
		return cli.ExitOperational, false
	}
	return 0, true
}

// degradedNoGit is the whole-instrument degraded result: with git absent no criterion can be measured.
func degradedNoGit(s cli.Stdio) int {
	fmt.Fprintf(s.Err, "%s: degraded: git not found in PATH\n", scriptName)
	rep := &report{}
	for _, id := range []string{"C1", "C2", "C3", "C4"} {
		rep.emit(id, statusDegraded, "git-not-found")
	}
	rep.write(s.Out, true)
	return cli.ExitDegraded
}
