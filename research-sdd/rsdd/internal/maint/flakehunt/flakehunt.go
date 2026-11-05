// Package flakehunt is `rsdd maint flake-hunt`, the port of toolbelt/maint/kit-flake-hunt.sh (kit issue #2209, Go
// port): it runs the selected test suites K times under bounded synthetic CPU load and reports every suite that
// failed at least once (a load flake), so timing flakes are found before they fail a gate. With --file-issues it
// files, or comments on, one issue per flaky or broken suite. The nightly workflow .github/workflows/flake-hunt.yml
// calls it through the shim, so every flag, exit code and output file is pinned (workflow_test.go).
//
// Exit codes: 0 clean, 1 at least one flaky or broken suite, 2 degraded or bad usage (a missing tool, no suites,
// an unreadable list, a refused --out, expired load, a failed issue search, nothing measured), 143/130 after TERM/INT.
//
// Intended divergences from the bash, each pinned by a test and listed in tool-registry.d/kit-flake-hunt.md:
//   - --help prints the full help on stdout (the bash printed one usage line on stderr);
//   - numbers are decimal and any length (the bash read 010 as octal in its arithmetic and overflowed past 63 bits);
//   - a trailing slash on --out is dropped;
//   - without --repo the hunt takes the kit checkout around the working directory (the shim passes its own);
//   - an interrupted hunt removes the TMPDIR of the suite it stopped.
package flakehunt

import (
	_ "embed"
	"fmt"
	"os"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

//go:embed help.txt
var help string

// deps is what the command takes from outside; tests replace the signal source.
type deps struct {
	notify func() (<-chan os.Signal, func())
}

// Run is `rsdd maint flake-hunt`.
func Run(args []string, s cli.Stdio) int { return run(args, s, deps{notify: realNotify}) }

// ends writes a refused run's text on stderr and returns its exit code.
func ends(s cli.Stdio, f *stop) int {
	fmt.Fprint(s.Err, f.msg)
	return f.code
}

func run(args []string, s cli.Stdio, d deps) int {
	o, fail := parse(args)
	if fail != nil {
		return ends(s, fail)
	}
	if o.help {
		fmt.Fprint(s.Out, help)
		return cli.ExitOK
	}
	h, fail := prepare(o, s)
	if fail != nil {
		return ends(s, fail)
	}
	h.intr = newInterrupter(d.notify)
	defer h.intr.stop()
	return h.execute()
}

// execute starts the load, measures, and reports. Every exit path stops the load workers by process group.
func (h *hunt) execute() int {
	var err error
	if h.loads, err = startLoad(h.c.load, h.c.loadTimeout, h.out, h.tools.timeout, h.env); err != nil {
		return ends(h.s, die("cannot start the load workers: %v", err))
	}
	defer h.loads.stop()
	res, err := h.measure()
	_ = os.Remove(h.out + "/tmp") // rmdir: only if empty
	switch {
	case err != nil:
		return ends(h.s, die("cannot write %s: %v", h.results, err))
	case res.interrupted != 0:
		return res.interrupted
	case res.expired != 0:
		fmt.Fprintf(h.s.Err, "degraded: kit-flake-hunt: load expired at run %d (a worker is gone: --load-timeout %d s was too short); the partial results are not a load measurement\n", res.expired, h.c.loadTimeout)
		fmt.Fprintf(h.s.Out, "Results: %s\n", h.results)
		return 2
	}
	return h.finish()
}

// finish reports the hunt and files the issues.
func (h *hunt) finish() int {
	found, t := h.classify(h.s.Out)
	h.printTotals(h.s.Out, t)
	if t.measured() == 0 {
		return ends(h.s, die("nothing measured: all %d suite(s) skipped in every run", len(h.suites)))
	}
	rc := 0
	if t.flaky+t.broken > 0 {
		rc = 1
	}
	rc, sig := h.fileIssues(found, rc)
	if sig != 0 {
		return sig
	}
	return rc
}
