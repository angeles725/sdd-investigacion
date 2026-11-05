package flakehunt

import (
	"fmt"
	"os"
	"strconv"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/kitmaint"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/probe"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/proc"
)

// requiredTools are probed before anything else: a missing tool is a typed degraded state, never a pass.
var requiredTools = []string{"bash", "timeout", "nproc"}

// nprocCount is the CPU count `nproc` reports.
func nprocCount(s cli.Stdio, env []string) (int, bool) {
	res, err := proc.Run(proc.Spec{Argv: []string{"nproc"}, Dir: s.Cwd, Env: env, Timeout: kitmaint.ChildCeiling, MaxBytes: 1 << 16, Now: s.Clock})
	if err != nil || res.ReturnCode != 0 {
		return 0, false
	}
	n, err := strconv.Atoi(strings.TrimSpace(string(res.Stdout)))
	return n, err == nil
}

// kitAround is the kit checkout the hunt defaults to: the nearest directory at or above cwd that holds
// research-sdd/toolbelt, else cwd itself. (The shim passes its own checkout with --repo.)
func kitAround(cwd string) string {
	for d := cwd; ; d = d[:strings.LastIndexByte(d, '/')] {
		if kitmaint.IsDir(d + "/research-sdd/toolbelt") {
			return d
		}
		if d == "" || !strings.Contains(d, "/") {
			return cwd
		}
	}
}

// resolveRepo is the physical path of the repository to hunt in.
func resolveRepo(cwd, given string) (string, *stop) {
	repo := given
	if repo == "" {
		repo = kitAround(cwd)
	}
	if !kitmaint.IsDir(kitmaint.Abs(cwd, repo)) {
		return "", die("repo directory not found: %s", repo)
	}
	phys, err := kitmaint.ResolveDir(cwd, repo)
	if err != nil {
		return "", die("repo directory not found: %s", repo)
	}
	return phys, nil
}

// prepare runs everything that must hold before the first suite starts, in the order of the bash tool: the tool
// probe, the option values, the repo, the suite list, node (only when a *.test.mjs suite is selected), the default
// load timeout and the output directory. Nothing is created before the output directory is judged.
func prepare(o options, s cli.Stdio) (*hunt, *stop) {
	env := s.Environment()
	if missing := kitmaint.MissingDeps(env, s.Cwd, requiredTools...); len(missing) > 0 {
		return nil, die("required tool '%s' not found on PATH; the hunt cannot run", missing[0])
	}
	c, fail := validate(o, func() (int, bool) { return nprocCount(s, env) })
	if fail != nil {
		return nil, fail
	}
	h := &hunt{s: s, c: c, env: env, intr: newInterrupter(nil)}
	if h.repo, fail = resolveRepo(s.Cwd, o.repo); fail != nil {
		return nil, fail
	}
	if h.suites, fail = selectSuites(c, s.Cwd, h.repo, h.lister(), func(m string) { fmt.Fprint(s.Out, m) }); fail != nil {
		return nil, fail
	}
	needNode, fail := checkSuites(h.repo, h.suites)
	if fail != nil {
		return nil, fail
	}
	pr := probe.New(env, s.Cwd)
	h.tools.timeout, _ = pr.LookPath("timeout")
	if needNode {
		var err error
		if h.tools.node, err = pr.LookPath("node"); err != nil {
			return nil, die("required tool 'node' not found on PATH; the selected *.test.mjs suites cannot run")
		}
	}
	if h.c.loadTimeout == 0 {
		h.c.loadTimeout = c.runs*len(h.suites)*c.suiteTimeout + 300
	}
	out := o.out
	if out == "" {
		out = defaultOut(s.Env, s.Clock(), os.Getpid())
	}
	if h.out, h.results, fail = prepareOut(s.Cwd, h.repo, out); fail != nil {
		return nil, fail
	}
	return h, nil
}
