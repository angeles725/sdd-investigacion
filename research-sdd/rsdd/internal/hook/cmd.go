package hook

import (
	"fmt"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// oneArg enforces `rsdd hook <name> <arg>`; a wrong argument count is a usage error (exit 2).
func oneArg(name, arg string, args []string, s cli.Stdio) (string, bool) {
	if len(args) != 1 {
		fmt.Fprintf(s.Err, "usage: rsdd hook %s %s\n", name, arg)
		return "", false
	}
	return args[0], true
}

// The state commands print the state and a newline and always exit 0, like the bash predicates
// ("callers branch on the state, never on exit status"). The bash shim captures them with $(...).

func runWiringState(args []string, s cli.Stdio) int {
	target, ok := oneArg("wiring-state", "<target-dir>", args, s)
	if !ok {
		return cli.ExitUsage
	}
	fmt.Fprintln(s.Out, WiringState(EnvFrom(s), target))
	return cli.ExitOK
}

func runScriptState(args []string, s cli.Stdio) int {
	target, ok := oneArg("script-state", "<target-dir>", args, s)
	if !ok {
		return cli.ExitUsage
	}
	fmt.Fprintln(s.Out, ScriptState(EnvFrom(s), target))
	return cli.ExitOK
}

// git-root prints "1" or "0" (the target is its own root, from the raw-target check) on line 1 and
// the root, or an empty line, on line 2. The root is the last line and is newline-terminated; a
// consumer that must keep an embedded or trailing newline of the path appends a sentinel before
// stripping the terminator.
func runGitRoot(args []string, s cli.Stdio) int {
	dir, ok := oneArg("git-root", "<dir>", args, s)
	if !ok {
		return cli.ExitUsage
	}
	root, isRoot := FindGitRoot(EnvFrom(s), dir)
	flag := 0
	if isRoot {
		flag = 1
	}
	fmt.Fprintf(s.Out, "%d\n%s\n", flag, root)
	return cli.ExitOK
}

// abspath prints the collapsed absolute path and a newline (same terminator convention as git-root).
func runAbsPath(args []string, s cli.Stdio) int {
	p, ok := oneArg("abspath", "<path>", args, s)
	if !ok {
		return cli.ExitUsage
	}
	fmt.Fprintln(s.Out, AbsPath(s.Cwd, p))
	return cli.ExitOK
}
