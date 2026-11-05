package reconcile

import (
	"context"
	"errors"
	"fmt"
	"path/filepath"
	"strings"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/gh"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/kit"
)

// ghDefaultBound is the bound in seconds of one gh call (RSDD_GH_TIMEOUT overrides it). The legacy script ran
// gh without a bound; a listing of a thousand issues needs far more than the launcher's default of 20 s.
const ghDefaultBound = 120

// Command is the registry entry of `rsdd retro reconcile`.
var Command = cli.Command{
	Name:    "reconcile",
	Group:   "retro",
	Summary: "audit GitHub issue coverage for the open deltas of one retro, or of every retro with --all",
	Run:     RunCommand,
}

// RunCommand is `rsdd retro reconcile [--toolbelt DIR] (<retro.md> | --all) [--issues-cache FILE] [--closed-cache FILE]`,
// the command behind the shim toolbelt/reconcile-issues.sh. The shim passes `--toolbelt <its own directory>`
// first: the script's directory fixed the kit root (two directories above it), and the Go command has no script
// directory of its own. Run directly, the toolbelt is found with the kit resolution. Everything after that pair
// is the legacy argument list.
//
// Exit codes (unchanged): 0 audited (findings never fail); 1 usage, absent-input, degraded (gh missing or not
// authenticated, an unreadable cache, a failed or capped gh listing, a retro that could not be read, git
// unusable for the closure evidence), or --all with a retro that could not be audited.
func RunCommand(args []string, s cli.Stdio) int { return runCommand(args, s, hooks{}) }

// hooks are the seams the tests use to keep a real wait out of the run.
type hooks struct {
	sleep func(context.Context, time.Duration)
}

func runCommand(args []string, s cli.Stdio, h hooks) int {
	errf := func(format string, a ...any) { fmt.Fprintf(s.Err, format+"\n", a...) }
	toolbelt := ""
	if len(args) >= 2 && args[0] == "--toolbelt" {
		toolbelt, args = args[1], args[2:]
	}
	var (
		all                    bool
		retro, issues, closedC string
	)
	for len(args) > 0 {
		switch a := args[0]; {
		case a == "--all":
			all, args = true, args[1:]
		case a == "--issues-cache" || a == "--closed-cache":
			if len(args) < 2 {
				errf("reconcile-issues: %s requires a value", a)
				return 1
			}
			if a == "--issues-cache" {
				issues = args[1]
			} else {
				closedC = args[1]
			}
			args = args[2:]
		case strings.HasPrefix(a, "--"):
			errf("reconcile-issues: unknown flag '%s'", a)
			return 1
		default:
			retro, args = a, args[1:]
		}
	}
	if !all && retro == "" {
		errf("usage: reconcile-issues.sh <retro.md> | --all")
		return 1
	}
	environ := s.Environment()
	ghOpts := gh.Options{Env: environ, Default: ghDefaultBound, Now: s.Clock}
	// §7 degraded probe: gh is only required when no --issues-cache is supplied.
	if issues == "" {
		line, err := ProbeGH(ghOpts)
		if err != nil {
			errf("reconcile-issues: %v", err)
			return 1
		}
		if line != "" {
			errf("%s", line)
			return 1
		}
	}
	kitRoot, ok := kitRootOf(s, toolbelt, errf)
	if !ok {
		return 1
	}
	o := Options{Retro: retro, All: all, GH: ghOpts, KitRoot: kitRoot, Cwd: s.Cwd, Env: s.Env, Now: s.Clock, Sleep: h.sleep}
	if issues != "" {
		o.IssuesCache = CacheFile(issues)
	}
	if closedC != "" {
		o.ClosedCache = ClosedFile(closedC)
	}
	rep, err := Run(context.Background(), o)
	if err != nil {
		if errors.Is(err, ErrUsage) {
			errf("usage: reconcile-issues.sh <retro.md> | --all")
		} else {
			errf("reconcile-issues: %v", err)
		}
		return 1
	}
	return rep.Render(s.Out, s.Err)
}

// kitRootOf is the legacy KIT_ROOT: two directories above the toolbelt, resolved physically (kit issue #993).
func kitRootOf(s cli.Stdio, toolbelt string, errf func(string, ...any)) (string, bool) {
	if toolbelt == "" {
		p, warns, err := kit.ResolveKitScript("toolbelt/reconcile-issues.sh", s.Env)
		for _, w := range warns {
			errf("%s", w)
		}
		if err != nil {
			errf("reconcile-issues: cannot find the kit toolbelt: %v", err)
			return "", false
		}
		toolbelt = filepath.Dir(p)
	}
	if !filepath.IsAbs(toolbelt) {
		toolbelt = filepath.Join(s.Cwd, toolbelt)
	}
	if r, err := filepath.EvalSymlinks(toolbelt); err == nil {
		toolbelt = r
	}
	return filepath.Dir(filepath.Dir(toolbelt)), true
}
