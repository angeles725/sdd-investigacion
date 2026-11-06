// Package consumers is `rsdd maint consumers` (issue #2758): it lists the live kit scripts and reports which
// files of the repository name them, and says what it cannot see. Read-only: it only runs git and reads files.
//
// Exit codes: 0 report printed, 1 operational (absent-input, empty-input, a listed file that cannot be read),
// 2 usage error, 3 degraded (no git, or not inside a work tree).
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
