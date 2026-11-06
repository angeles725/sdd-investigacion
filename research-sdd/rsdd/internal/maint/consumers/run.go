// Package consumers is `rsdd maint consumers` (issue #2758): it lists the live kit scripts and says what it cannot
// see; the references to them come with the next change. Read-only: it only runs git, and reads no file.
//
// Exit codes: 0 report printed, 1 operational (absent-input: no file under the script directories or a --repo
// that is not a directory; empty-input; a git that failed, timed out or hit its output cap), 2 usage error,
// 3 degraded (no git, not inside a work tree, or a file listing that git accompanied with stderr).
package consumers

import (
	_ "embed"
	"fmt"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

//go:embed help.txt
var help string

// Run is `rsdd maint consumers`.
func Run(args []string, s cli.Stdio) int {
	o, why := parse(args)
	if o.help {
		fmt.Fprint(s.Out, help)
		return cli.ExitOK
	}
	if why != "" {
		fmt.Fprintf(s.Err, usageProblem, why)
		fmt.Fprint(s.Err, usageLine)
		return cli.ExitUsage
	}
	l, bad := list(s, o.repo)
	if bad != nil {
		return bad.emit(s)
	}
	sc := findScripts(l.files)
	if sc.under == 0 {
		return outcome{err: fmt.Sprintf(stateAbsent, l.top), rc: cli.ExitOperational}.emit(s)
	}
	if len(sc.paths) == 0 {
		return outcome{err: fmt.Sprintf(stateEmpty, sc.under, sc.excludedSummary()), rc: cli.ExitOperational}.emit(s)
	}
	writeHeader(s.Out, l, sc)
	writeFooter(s.Out)
	return cli.ExitOK
}
