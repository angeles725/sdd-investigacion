package formats

import (
	"errors"
	"flag"
	"fmt"
	"io"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// parseQNX6Args parses `list|extract` and its flags. done is true when the command must stop with code (a
// usage error or -h); the flag package's own output is suppressed so every message goes through one path.
func parseQNX6Args(args []string, s cli.Stdio) (a qnx6Args, code int, done bool) {
	usageErr := func(format string, v ...any) (qnx6Args, int, bool) {
		fmt.Fprint(s.Err, qnx6Usage)
		fmt.Fprintf(s.Err, "qnx6-read: error: "+format+"\n", v...)
		return a, cli.ExitUsage, true
	}
	if len(args) == 0 {
		return usageErr("the following arguments are required: cmd")
	}
	switch args[0] {
	case "-h", "--help":
		fmt.Fprint(s.Out, qnx6Usage)
		return a, cli.ExitOK, true
	case "list", "extract":
	default:
		return usageErr("argument cmd: invalid choice: %s (choose from 'list', 'extract')", pyRepr(args[0]))
	}
	a.cmd = args[0]
	fs := flag.NewFlagSet("qnx6-read "+a.cmd, flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	fs.StringVar(&a.input, "input", "", "")
	fs.StringVar(&a.output, "output", "", "")
	fs.Int64Var(&a.poff, "partition-offset", 0, "")
	if a.cmd == "extract" {
		fs.StringVar(&a.fsPath, "fs-path", "", "")
	}
	if err := fs.Parse(args[1:]); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			fmt.Fprint(s.Out, qnx6Usage)
			return a, cli.ExitOK, true
		}
		return usageErr("%v", err)
	}
	if fs.NArg() > 0 {
		return usageErr("unrecognized arguments: %v", fs.Args())
	}
	given := map[string]bool{}
	fs.Visit(func(f *flag.Flag) { given[f.Name] = true })
	required := []string{"input", "output"}
	if a.cmd == "extract" {
		required = []string{"input", "fs-path", "output"}
	}
	for _, name := range required {
		if !given[name] {
			return usageErr("the following arguments are required: --%s", name)
		}
	}
	return a, 0, false
}
