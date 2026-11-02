package firmware

import (
	"flag"
	"fmt"
	"io"
	"strings"
)

const usageText = `usage: rsdd corroborate firmware --input FILE --output NEW_DIR [options]

Produce bounded, non-extracting Binwalk (major 2) evidence for one firmware image: signatures and entropy
edges, from an analyzer staged and run in a network-denied bubblewrap sandbox. Writes
NEW_DIR/firmware-static.v1.json, the engine/ evidence files and a verified analysis manifest.

The analyzer is the PATH-selected root-owned binwalk, or the absolute path in RSDD_BINWALK (it, and its
directory, may then be owned by the invoking user). RSDD_BINWALK_TEST_ONLY selects a test analyzer; the report
says so. RSDD_BWRAP overrides /usr/bin/bwrap (it must still be the one found on /usr/bin:/bin).

options (defaults in brackets):
  --timeout-seconds N       wall-clock bound of the analyzer [30]
  --max-diagnostic-bytes N  bound on its stdout plus stderr [2000000]
  --max-input-bytes N       refuse a larger input [1073741824]
  --max-findings N          findings kept in the report [10000]
  --max-processes N         bound on its process tree [32]
  --max-files N             bound on the evidence tree, at least 7 [7]
exit: 0 complete, 1 published but failed or partial, 2 refused or failed
`

// config is the parsed command line.
type config struct {
	input, output                                                     string
	timeout, maxDiagnostic, maxInput, maxFindings, maxProcs, maxFiles int64
}

type parseOutcome int

const (
	parsed parseOutcome = iota
	helpShown
	usageError
)

// parseArgs reads the command line; a usage problem or -h is already printed when the outcome is not parsed.
// --manifest-cli is accepted and ignored: the script needed the manifest tool's path, the port calls it in
// process.
func parseArgs(args []string, out, errw io.Writer) (config, parseOutcome) {
	var c config
	var manifestCLI string
	fs := flag.NewFlagSet("firmware", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	fs.StringVar(&c.input, "input", "", "")
	fs.StringVar(&c.output, "output", "", "")
	fs.Int64Var(&c.timeout, "timeout-seconds", 30, "")
	fs.Int64Var(&c.maxDiagnostic, "max-diagnostic-bytes", 2_000_000, "")
	fs.Int64Var(&c.maxInput, "max-input-bytes", 1_073_741_824, "")
	fs.Int64Var(&c.maxFindings, "max-findings", 10_000, "")
	fs.Int64Var(&c.maxProcs, "max-processes", 32, "")
	fs.Int64Var(&c.maxFiles, "max-files", 7, "")
	fs.StringVar(&manifestCLI, "manifest-cli", "", "")
	if err := fs.Parse(args); err != nil {
		if err == flag.ErrHelp {
			_, _ = io.WriteString(out, usageText)
			return c, helpShown
		}
		return c, usage(errw, err.Error())
	}
	if fs.NArg() > 0 {
		return c, usage(errw, "unrecognized arguments: "+strings.Join(fs.Args(), " "))
	}
	set := map[string]bool{}
	fs.Visit(func(f *flag.Flag) { set[f.Name] = true })
	var missing []string
	for _, name := range []string{"input", "output"} {
		if !set[name] {
			missing = append(missing, "--"+name)
		}
	}
	if len(missing) > 0 {
		return c, usage(errw, "the following arguments are required: "+strings.Join(missing, ", "))
	}
	return c, parsed
}

func usage(errw io.Writer, msg string) parseOutcome {
	fmt.Fprint(errw, usageText)
	fmt.Fprintf(errw, "rsdd corroborate firmware: error: %s\n", msg)
	return usageError
}
