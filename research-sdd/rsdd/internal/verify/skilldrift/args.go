package skilldrift

import (
	_ "embed"
	"fmt"
	"io"
)

//go:embed help.txt
var helpText string // lines 3-32 of verify-skill-drift.sh, comment markers removed: what `--help` printed

// driftArgs are the parsed arguments of `verify skill-drift`.
type driftArgs struct {
	all        bool
	harness    string
	harnessSet bool
	home       string
	profile    string
}

// parseArgs is the script's argument loop. done is true when parsing ended the run (help, or a usage error) with exit code rc.
// Like the loop, it acts on each argument as it reads it: `--help` ends the run before later arguments are looked at, and a
// bad argument is reported before a later `--help`.
func parseArgs(args []string, out, errw io.Writer) (a driftArgs, rc int, done bool) {
	a.harness = "claude"
	need := func(i int, flag string) bool {
		if i+1 >= len(args) || args[i+1] == "" {
			fmt.Fprintf(errw, "verify-skill-drift: %s requires a non-empty value\n", flag)
			return false
		}
		return true
	}
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "--all":
			a.all = true
		case "--harness":
			if !need(i, "--harness") {
				return a, 2, true
			}
			a.harness, a.harnessSet = args[i+1], true
			i++
		case "--home":
			if !need(i, "--home") {
				return a, 2, true
			}
			a.home = args[i+1]
			i++
		case "--profile":
			if !need(i, "--profile") {
				return a, 2, true
			}
			a.profile = args[i+1]
			i++
		case "-h", "--help":
			io.WriteString(out, helpText) //nolint:errcheck // the command layer reports a failed stdout write
			return a, 0, true
		default:
			fmt.Fprintf(errw, "verify-skill-drift: unknown argument: %s\n", args[i])
			return a, 2, true
		}
	}
	if a.all && a.harnessSet {
		fmt.Fprint(errw, "verify-skill-drift: --all and --harness are mutually exclusive\n")
		return a, 2, true
	}
	return a, 0, false
}
