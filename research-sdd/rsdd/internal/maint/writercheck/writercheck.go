// Package writercheck is `rsdd maint writer-check`, the port of toolbelt/maint/kit-writer-check.sh (kit issue #2208,
// Go port of the maint batch): mechanical writer discipline for kit work, run BEFORE the full gate. It catches the
// incident shapes of the 2026-10-11 chain: a writer who ran only the plain suite of an edited script (the mutants
// broke), and a writer who killed processes by name. From a git range it lists the suites the change requires,
// demands a bound `--prove-teeth` log for each, scans the ADDED lines for name-based kills, and says which notes
// and findings result. It only runs git, bash (suite-impact.sh and the suites under --write-teeth-log) and reads
// files: the repository is never modified.
//
// Exit codes: 0 clean, 1 findings, 2 degraded or usage.
//
// Intended divergences from the bash, each pinned by a test and listed in tool-registry.d/kit-writer-check.md:
//   - grep, awk, sort, mktemp, timeout and sed are no longer dependencies (the scan, the sorting and the temporary
//     files are Go); bash is probed where it is used. A PATH without awk is not a degraded state;
//   - paths are read NUL-delimited and unquoted, and a diff hunk is read by its header counts, so a path with a
//     space or a quote, and an added line that itself starts with `++ b/`, are attributed to the right file;
//   - a waiver line is read after its leading blanks, a blank line is skipped, and a reason with a tab is kept whole;
//   - a suite that outlives KIT_WRITER_CHECK_TIMEOUT has its whole process group stopped (the bash stopped only the
//     direct child) and the exit is still 124;
//   - without KIT_WRITER_CHECK_IMPACT the suite-impact.sh of the kit is resolved like the portable hooks resolve
//     it (the bash shim exports it from its own directory first).
package writercheck

import (
	_ "embed"
	"fmt"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/kitmaint"
)

//go:embed help.txt
var help string

const tool = "kit-writer-check"

// Exit codes.
const (
	exitOK       = 0
	exitFindings = 1
	exitDegraded = 2
)

// ctx is one run: its options, its Stdio and environment, the git runner and the repository's top level.
type ctx struct {
	o    options
	s    cli.Stdio
	env  []string
	run  *kitmaint.Runner
	repo string
}

// git is `git -C <repo> args`.
func (c *ctx) git(args ...string) kitmaint.Res { return c.run.Git(c.repo, args...) }

// Run is `rsdd maint writer-check`.
func Run(args []string, s cli.Stdio) int {
	o, f := parse(args)
	if f != nil {
		return usage(s, f.msg)
	}
	if o.classify {
		if len(o.positional) == 0 {
			return usage(s, "")
		}
		classify(s.Out, o.positional)
		return exitOK
	}
	if o.format != "report" && o.format != "json" {
		return usage(s, "--format must be report or json")
	}
	env := s.Environment()
	if len(kitmaint.MissingDeps(env, s.Cwd, "git")) > 0 {
		return degrade(s, "git not found on PATH")
	}
	c := &ctx{o: o, s: s, env: env, run: &kitmaint.Runner{Env: env, Cwd: s.Cwd, Now: s.Clock, Getenv: s.Env}}
	top := c.run.Git(o.repo, "rev-parse", "--show-toplevel")
	if !top.OK() {
		return degrade(s, "not a git repository: "+o.repo)
	}
	c.repo = strings.TrimRight(top.Out, "\n")
	return c.execute()
}

// usage prints the optional message and the usage text to stderr and returns the usage exit code.
func usage(s cli.Stdio, msg string) int {
	if msg != "" {
		fmt.Fprintf(s.Err, "%s: %s\n", tool, msg)
	}
	fmt.Fprint(s.Err, help)
	return exitDegraded
}

// degrade is the typed degraded state: the check could not look, and says so instead of reporting a clean pass.
func degrade(s cli.Stdio, why string) int {
	fmt.Fprintf(s.Err, "degraded: %s: %s\n", tool, why)
	return exitDegraded
}
