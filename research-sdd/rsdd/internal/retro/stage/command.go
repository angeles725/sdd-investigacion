package stage

import (
	"fmt"
	"path/filepath"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/kit"
)

// Command is the registry entry of `rsdd retro stage`.
var Command = cli.Command{
	Name:    "stage",
	Group:   "retro",
	Summary: "stage one pending §18 retro as a review branch in the kit repo and print its deltas and next steps",
	Run:     RunCommand,
}

// RunCommand is `rsdd retro stage [--toolbelt DIR] <retro.md> [--force]`, the command behind the shim
// toolbelt/stage-retro.sh. The shim passes `--toolbelt <its own directory>` first: the script's directory fixed
// the kit repo (two directories above it, resolved physically, kit issue #1024), and the Go command has no script
// directory of its own. Run directly, the toolbelt is found with the kit resolution. Everything after that pair is
// the legacy argument list.
func RunCommand(args []string, s cli.Stdio) int {
	toolbelt := ""
	if len(args) >= 2 && args[0] == "--toolbelt" {
		toolbelt, args = args[1], args[2:]
	}
	kitRoot, ok := kitRootOf(s, toolbelt)
	if !ok {
		return 1
	}
	environ := s.Environment()
	return Run(Options{Args: args, KitRoot: kitRoot, Cwd: s.Cwd, Getenv: s.Env, Environ: environ, Out: s.Out, Err: s.Err})
}

// kitRootOf is the script's KIT_REPO: two directories above the toolbelt, resolved physically, so a toolbelt
// reached through a symlink (the profile installer's, kit issue #1024) still finds the real kit repo.
func kitRootOf(s cli.Stdio, toolbelt string) (string, bool) {
	if toolbelt == "" {
		p, warns, err := kit.ResolveKitScript("toolbelt/stage-retro.sh", s.Env)
		for _, w := range warns {
			fmt.Fprintln(s.Err, w)
		}
		if err != nil {
			fmt.Fprintf(s.Err, "stage-retro: cannot find the kit toolbelt: %v\n", err)
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
