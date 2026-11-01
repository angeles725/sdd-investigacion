// `rsdd corpus archive` is the port of toolbelt/research-sdd-archive.sh (kit issue #2459): the gated close discipline
// of a Research-SDD corpus. It refuses to close an inconsistent corpus (exit 3), does the safe deterministic
// bookkeeping (regenerate CATALOG.md, touch INDEX.md) and prints the close checklist. It WRITES into the target, so it
// is only ever exercised on scratch copies (kit CLAUDE.md section 8).
//
// Files: archive_args.go (command line), archive_discover.go (target, state file, banner), archive_gates.go (verify-state,
// verify-sources, verify-corrections, undocumented_findings), archive_secrets.go (the secrets gate), archive_retro.go and
// archive_missingretro.go (retro helpers and the MISSING-RETRO gate), archive_refuse.go (the refusal block),
// archive_consolidate.go, archive_report.go (mirror facts, ONE-BLOCK-PER-COMMIT, retro lint, checklist), archive_exec.go
// (child processes), archive_quote.go (bash %q), archive_hooks.go (test seams).
package corpus

import (
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/kit"
)

// archiveEnv is one run of the command.
type archiveEnv struct {
	s     cli.Stdio
	env   []string // the environment of every child process
	hooks archiveHooks

	here    string // toolbelt directory (the sibling scripts and the kit templates)
	target  string // absolute, logical
	corpus  string // directory of the resolved state file
	state   string
	focus   string
	dry     bool
	allowVC bool

	gateRC         int
	consolidateErr string

	// secrets gate
	ssPhys       string
	ssUnreadable int
	ssWhy        string
	ssLeakWT     bool
	ssLeakHist   bool
	ssWTRC       int
	ssList       string

	// retro scan
	blocks         int
	retros         int
	newestBlock    int64
	newestRetro    int64
	priorRetro     int64
	priorRetroFile string
}

func (e *archiveEnv) say(format string, a ...any)  { fmt.Fprintf(e.s.Out, format+"\n", a...) }
func (e *archiveEnv) warn(format string, a ...any) { fmt.Fprintf(e.s.Err, format+"\n", a...) }

// init adds the command to the domain table from this file, so commands.go (shared with the other corpus ports) stays
// untouched.
func init() {
	Commands = append(Commands, cli.Command{Name: "archive", Group: "corpus",
		Summary: "gated close of a research corpus: refuse an inconsistent one, regenerate CATALOG, print the close checklist", Run: archiveRun})
}

func archiveRun(args []string, s cli.Stdio) int { return archiveRunWith(args, s, nil) }

func archiveDefaultHooks() archiveHooks {
	return archiveHooks{
		touch:     func(p string, t time.Time) error { return os.Chtimes(p, t, t) },
		walk:      archiveWalkFiles,
		phys:      archivePhys,
		listState: kit.ListStateFiles,
	}
}

// archivePhys is `cd -P p && pwd -P`.
func archivePhys(p string) (string, bool) {
	r, err := filepath.EvalSymlinks(p)
	if err != nil {
		return "", false
	}
	r, err = filepath.Abs(r)
	if err != nil {
		return "", false
	}
	return r, true
}

// archiveRunWith is the command with its seams; hook, when not nil, replaces the defaults.
func archiveRunWith(args []string, s cli.Stdio, hook func(*archiveHooks)) int {
	a := archiveParseArgs(args)
	if a.errLine != "" {
		fmt.Fprintln(s.Err, a.errLine)
		return cli.ExitUsage
	}
	if a.target == "" || !archiveIsDir(s.Cwd, a.target) {
		fmt.Fprintln(s.Err, archiveUsage)
		return cli.ExitUsage
	}
	e := &archiveEnv{s: s, dry: a.dry, allowVC: a.allowVC, focus: a.focus, hooks: archiveDefaultHooks()}
	if s.Environ != nil {
		e.env = s.Environ()
	}
	if hook != nil {
		hook(&e.hooks)
	}
	raw := a.target[:len(a.target)-boolInt(a.target[len(a.target)-1] == '/')]
	abs, ok := archiveAbsTarget(s.Cwd, raw)
	if !ok {
		fmt.Fprintf(s.Err, "research-sdd-archive: not a directory: %s\n", raw)
		return cli.ExitOperational
	}
	e.target = abs
	if e.here = a.toolbelt; e.here == "" {
		p, _, err := kit.ResolveKitScript("toolbelt/verify-state.sh", kit.Getenv(s.Env))
		if err != nil {
			fmt.Fprintf(s.Err, "research-sdd-archive: cannot find the toolbelt (pass --toolbelt DIR): %v\n", err)
			return cli.ExitOperational
		}
		e.here = filepath.Dir(p)
	}
	if code, done := e.archiveDiscover(); done {
		return code
	}
	defer e.archiveCleanup()
	e.archiveGates()
	if e.gateRC != 0 {
		return e.archiveRefusal()
	}
	e.archiveConsolidate()
	e.archiveReport()
	return 0
}

func boolInt(b bool) int {
	if b {
		return 1
	}
	return 0
}
