// Package cleancheck is the command line of `rsdd hygiene clean-check`, the port of toolbelt/clean-check.sh (contract
// clean-check.v1.md). It parses the flags, calls the engine (internal/core/cleancheck.Check) and writes the lines the
// engine returns, so the output is the engine's by construction. See docs/adding-a-command.md.
package cleancheck

import (
	"fmt"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/cleancheck"
)

// Run is `rsdd hygiene clean-check`. Exit codes are the script's: 0 clean, 1 findings, 2 a refused command line or
// input or a failed scan, 3 degraded (the command is registered PlainExit3: its exit 3 prints its own typed lines).
func Run(args []string, s cli.Stdio) int {
	p, bad := parse(args)
	if p.help && bad == "" {
		fmt.Fprintln(s.Err, usageLine) // the script printed its usage on stderr, also for -h
		return cli.ExitOK
	}
	if bad != "" {
		fmt.Fprintln(s.Err, usageLine)
		fmt.Fprintf(s.Err, "clean-check: ERROR: %s\n", bad)
		return cli.ExitUsage
	}
	p.opts.Env, p.opts.Cwd, p.opts.Now = s.Environment(), s.Cwd, s.Clock
	p.opts.UID = s.Env("CLEAN_CHECK_UID")
	if p.opts.Scratchpad == "" { // --scratchpad wins over the environment
		p.opts.Scratchpad = s.Env("CLEAN_CHECK_SCRATCHPAD")
	}
	res := cleancheck.Check(p.opts)
	for _, l := range res.Lines {
		w := s.Out
		if l.Stream == cleancheck.Err {
			w = s.Err
		}
		fmt.Fprintln(w, l.Text)
	}
	return res.Exit
}
