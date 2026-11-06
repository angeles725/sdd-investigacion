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
	names := sc.names
	if o.script != "" {
		names = map[string]bool{o.script: true}
	}
	sn := scan(l.top, l.files, sc.paths, names)
	if len(sn.errs) > 0 {
		for _, e := range sn.errs {
			fmt.Fprint(s.Err, e)
		}
		return cli.ExitOperational
	}
	if o.refs {
		return refsOutput(s, o, sc, sn)
	}
	writeHeader(s.Out, l, sc)
	if o.script != "" {
		fmt.Fprintf(s.Out, scriptState(o.script, sc), o.script)
	}
	writeTable(s.Out, sn)
	writeUnclassified(s.Out, sn)
	writeNotRead(s.Out, sn, len(l.files))
	writeFooter(s.Out)
	return cli.ExitOK
}

func scriptState(name string, sc scriptSet) string {
	if sc.names[name] {
		return scriptLive
	}
	return scriptNotLive
}

// refsOutput is --refs: one line per pair, and a typed line on stderr when there is nothing to print or the
// name asked for is not a live script.
func refsOutput(s cli.Stdio, o options, sc scriptSet, sn scanned) int {
	if o.script != "" && !sc.names[o.script] {
		fmt.Fprintf(s.Err, refsNotLive, o.script)
	}
	if !writeRefs(s.Out, sn) {
		if o.script != "" {
			fmt.Fprintf(s.Err, refsNoMatchOne, o.script)
		} else {
			fmt.Fprint(s.Err, refsNoMatch)
		}
	}
	return cli.ExitOK
}
