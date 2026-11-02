package carve

import (
	"flag"
	"fmt"
	"io"
	"strings"
)

const usageText = `usage: rsdd corroborate carve --input FILE --output NEW_DIR [options]

Carve only validated uImage and SquashFS v4 little-endian byte ranges out of FILE into the new directory
NEW_DIR, inside a bubblewrap sandbox with no network. Writes NEW_DIR/firmware-carve.v1.json and NEW_DIR/carves/.

options (defaults in brackets):
  --max-input-bytes N     refuse a larger input [1073741824]
  --max-output-bytes N    refuse to carve more bytes in total [1073741824]
  --max-carves N          refuse more candidate ranges [16]
  --max-files N           refuse a tree of more files [17]
  --timeout-seconds N     wall-clock bound of the sandboxed worker [30]
  --max-processes N       bound on the worker's process tree [4]
  --max-memory-bytes N    address-space limit of the worker [1342177280]
exit: 0 carved, 2 refused or failed, 3 published but the directory sync failed
`

// config is the parsed command line. The last five fields are the hidden worker interface: the command
// re-runs itself inside the sandbox with --worker.
type config struct {
	input, output                            string
	maxInput, maxOutput, maxCarves, maxFiles int64
	timeout, maxProcs, maxMemory             int64
	worker                                   bool
	stage, inputRecord, bwrapPath, bwrapSHA  string
}

type parseOutcome int

const (
	parsed parseOutcome = iota
	helpShown
	usageError
)

// parseArgs reads the command line; a usage problem or -h is already printed when the outcome is not parsed.
func parseArgs(args []string, out, errw io.Writer) (config, parseOutcome) {
	var c config
	fs := flag.NewFlagSet("carve", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	fs.StringVar(&c.input, "input", "", "")
	fs.StringVar(&c.output, "output", "", "")
	fs.Int64Var(&c.maxInput, "max-input-bytes", 1073741824, "")
	fs.Int64Var(&c.maxOutput, "max-output-bytes", 1073741824, "")
	fs.Int64Var(&c.maxCarves, "max-carves", 16, "")
	fs.Int64Var(&c.maxFiles, "max-files", 17, "")
	fs.Int64Var(&c.timeout, "timeout-seconds", 30, "")
	fs.Int64Var(&c.maxProcs, "max-processes", 4, "")
	fs.Int64Var(&c.maxMemory, "max-memory-bytes", 1342177280, "")
	fs.BoolVar(&c.worker, "worker", false, "")
	fs.StringVar(&c.stage, "stage", "", "")
	fs.StringVar(&c.inputRecord, "input-record", "", "")
	fs.StringVar(&c.bwrapPath, "bwrap-path", "", "")
	fs.StringVar(&c.bwrapSHA, "bwrap-sha256", "", "")
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
	var missing []string
	set := map[string]bool{}
	fs.Visit(func(f *flag.Flag) { set[f.Name] = true })
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
	fmt.Fprintf(errw, "rsdd corroborate carve: error: %s\n", msg)
	return usageError
}
