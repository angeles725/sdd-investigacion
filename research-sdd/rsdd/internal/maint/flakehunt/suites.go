package flakehunt

import (
	"os"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/kitmaint"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/proc"
)

// runAllRel is where a kit checkout keeps the runner that knows which suites exist.
const runAllRel = "research-sdd/toolbelt/tests/run-all.sh"

// parseList is the --suites file: one path per line, `#` starts a comment, blank lines are skipped and the last line
// needs no newline. Whitespace around a path is dropped.
func parseList(text string) []string {
	var out []string
	for _, l := range strings.Split(text, "\n") {
		if i := strings.IndexByte(l, '#'); i >= 0 {
			l = l[:i]
		}
		if l = strings.TrimFunc(l, isSpace); l != "" {
			out = append(out, l)
		}
	}
	return out
}

// listed is the output of run-all.sh --list-suites: one suite per line, blank lines skipped, nothing trimmed.
func listed(text string) []string {
	var out []string
	for _, l := range strings.Split(text, "\n") {
		if l != "" {
			out = append(out, l)
		}
	}
	return out
}

// lister runs `bash run-all.sh <args>` in the repo and reports its stdout and whether it exited 0. Its stderr is
// discarded, as the bash did.
type lister func(args ...string) (string, bool)

func (h *hunt) lister() lister {
	return func(args ...string) (string, bool) {
		res, err := proc.Run(proc.Spec{
			Argv: append([]string{"bash", h.repo + "/" + runAllRel}, args...), Dir: h.repo, Env: h.env,
			Timeout: kitmaint.ChildCeiling, MaxBytes: 64 << 20, Now: h.s.Clock,
		})
		return string(res.Stdout), err == nil && res.ReturnCode == 0 && res.Reason == ""
	}
}

// selectSuites resolves the suite list: the --suites file, the --suite flags, or what run-all.sh would run (with
// --tier core tried first; a runner that rejects it gets the full list and a `note:` line on stdout).
func selectSuites(c config, cwd, repo string, list lister, note func(string)) ([]string, *stop) {
	switch {
	case c.o.suitesFile != "":
		b, err := os.ReadFile(kitmaint.Abs(cwd, c.o.suitesFile))
		if err != nil {
			return nil, die("suite list not readable: %s", c.o.suitesFile)
		}
		return parseList(string(b)), nil
	case len(c.o.suiteArgs) > 0:
		var out []string
		for _, s := range c.o.suiteArgs {
			if s != "" {
				out = append(out, s)
			}
		}
		return out, nil
	}
	runAll := repo + "/" + runAllRel
	if fi, err := os.Stat(runAll); err != nil || fi.IsDir() {
		return nil, die("run-all.sh not found at %s; pass --suite/--suites or a valid --repo", runAll)
	}
	if c.o.tier == "core" {
		if text, ok := list("--list-suites", "--tier", "core"); ok {
			return listed(text), nil
		}
		note("note: run-all.sh rejected --tier core; hunting the full suite list\n")
	}
	text, ok := list("--list-suites")
	if !ok {
		return nil, die("run-all.sh --list-suites failed")
	}
	return listed(text), nil
}

// suitePath is where a suite lives: absolute as given, otherwise below the repo.
func suitePath(repo, s string) string { return kitmaint.Abs(repo, s) }

// checkSuites refuses an empty selection and a suite that is not a file, and reports whether a *.test.mjs suite
// needs node (run-all.sh runs those under node; without it they could only fail as "broken").
func checkSuites(repo string, suites []string) (needNode bool, fail *stop) {
	if len(suites) == 0 {
		return false, die("no suites selected (an empty list is not a clean hunt)")
	}
	for _, s := range suites {
		if fi, err := os.Stat(suitePath(repo, s)); err != nil || fi.IsDir() {
			return false, die("suite not found: %s", s)
		}
		needNode = needNode || strings.HasSuffix(s, ".test.mjs")
	}
	return needNode, nil
}
