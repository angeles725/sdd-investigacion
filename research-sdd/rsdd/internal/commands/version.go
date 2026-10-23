package commands

import (
	"errors"
	"flag"
	"fmt"
	"runtime/debug"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// readBuildInfo is a seam so tests can pin the build metadata.
var readBuildInfo = debug.ReadBuildInfo

var versionCommand = cli.Command{
	Name:    "version",
	Summary: "print the module version and VCS revision",
	Run:     runVersion,
}

// runVersion prints what the binary honestly knows; absent data is the
// literal "unknown", never a fabricated value.
func runVersion(args []string, s cli.Stdio) int {
	fs := flag.NewFlagSet("rsdd version", flag.ContinueOnError)
	fs.SetOutput(s.Err)
	if err := fs.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return cli.ExitOK
		}
		return cli.ExitUsage
	}
	if fs.NArg() != 0 {
		fmt.Fprintf(s.Err, "rsdd version: unexpected argument %q\n", fs.Arg(0))
		return cli.ExitUsage
	}
	version, revision := "unknown", "unknown"
	if bi, ok := readBuildInfo(); ok {
		if bi.Main.Version != "" {
			version = bi.Main.Version
		}
		for _, kv := range bi.Settings {
			if kv.Key == "vcs.revision" && kv.Value != "" {
				revision = kv.Value
			}
		}
	}
	fmt.Fprintf(s.Out, "rsdd version %s revision %s\n", version, revision)
	return cli.ExitOK
}
