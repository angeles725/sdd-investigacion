package verifyretro

import (
	"context"
	"fmt"
	"io"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// Command is the registry entry of `rsdd retro verify`.
var Command = cli.Command{
	Name:    "verify",
	Group:   "retro",
	Summary: "check one retro against the §18 conformance rules (marker, title, delta section)",
	Run:     RunCommand,
}

// RunCommand is the command: Run, then Render.
func RunCommand(args []string, s cli.Stdio) int {
	rep, err := Run(context.Background(), Options{Args: args, Cwd: s.Cwd})
	if err != nil { // only a cancelled context fails, and this one never is: cli.Run turns the panic into its internal-error exit
		panic(err)
	}
	return rep.Render(s.Out, s.Err)
}

// Render writes the script's exact stdout and stderr for the report and returns its exit code.
func (r Report) Render(stdout, stderr io.Writer) int {
	switch r.State {
	case StateUsage:
		fmt.Fprint(stderr, "Usage: verify-retro.sh <retro.md>\n  exit 0 = conforming, exit 1 = non-conforming, exit 2 = bad args\n")
		return 2
	case StateAbsent:
		fmt.Fprintf(stderr, "ERROR: file not found (absent-input): %s\n", r.Arg)
		return 2
	case StateNotMarkdown:
		fmt.Fprintf(stderr, "ERROR: argument must be a .md file: %s\n", r.Arg)
		return 2
	case StateUnreadable:
		fmt.Fprintf(stderr, "ERROR: file not readable (absent-input): %s\n", r.Arg)
		return 2
	case StateExcluded:
		fmt.Fprint(stdout, "OK: kit-retro: exclude — declared non-kit retro, conforming/skipped\n")
		return 0
	}
	fmt.Fprint(stderr, r.FenceWarning)
	for _, f := range r.Findings {
		fmt.Fprintf(stdout, "%s [%s]: %s\n", f.Level, f.Class, f.Text)
		for _, l := range f.Fix {
			fmt.Fprintf(stdout, "%s\n", l)
		}
	}
	if r.State == StateNonConforming {
		return 1
	}
	fmt.Fprint(stdout, "OK: conforming\n")
	return 0
}
