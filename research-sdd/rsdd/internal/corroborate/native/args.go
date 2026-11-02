package native

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"strconv"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// Defaults of the legacy argparse parser.
const (
	defaultTimeout   = 30
	defaultMaxBytes  = 2_000_000
	defaultFunctions = 10_000
	defaultFiles     = 8
	minFiles         = 6
)

const usageText = `usage: rsdd corroborate native --input FILE --output DIR [--timeout-seconds N] [--max-bytes N]
                               [--max-functions N] [--max-files N]

Produce bounded, non-executing radare2 evidence (native-static.v1) for one regular native binary.

  --input FILE          regular, non-symlink native binary to analyse
  --output DIR          new evidence directory (must not exist; its parent must be on a Linux-private filesystem)
  --timeout-seconds N   wall-clock bound for radare2 (default 30)
  --max-bytes N         joint stdout+stderr cap for radare2 (default 2000000)
  --max-functions N     functions emitted before the evidence is partial (default 10000)
  --max-files N         evidence file cap, at least 6 (default 8)

Exit: 0 complete; 1 partial or failed evidence was published; 2 refused before publishing.
`

// config is the parsed command line.
type config struct {
	input, output string
	timeout       int
	maxBytes      int
	maxFunctions  int
	maxFiles      int
}

// intFlag parses a decimal integer like Python's int() for the plain forms (optional sign, surrounding space).
type intFlag struct{ v *int }

func (f intFlag) String() string {
	if f.v == nil {
		return ""
	}
	return strconv.Itoa(*f.v)
}

func (f intFlag) Set(s string) error {
	n, err := strconv.Atoi(strings.TrimSpace(s))
	if err != nil {
		return errors.New("invalid int value: " + strconv.Quote(s))
	}
	*f.v = n
	return nil
}

// parseArgs returns the configuration and true, or the exit code to return at once (help is 0, a usage error 2).
func parseArgs(args []string, s cli.Stdio) (config, int, bool) {
	c := config{timeout: defaultTimeout, maxBytes: defaultMaxBytes, maxFunctions: defaultFunctions, maxFiles: defaultFiles}
	set := flag.NewFlagSet("native", flag.ContinueOnError)
	set.SetOutput(io.Discard)
	set.StringVar(&c.input, "input", "", "")
	set.StringVar(&c.output, "output", "", "")
	set.Var(intFlag{&c.timeout}, "timeout-seconds", "")
	set.Var(intFlag{&c.maxBytes}, "max-bytes", "")
	set.Var(intFlag{&c.maxFunctions}, "max-functions", "")
	set.Var(intFlag{&c.maxFiles}, "max-files", "")
	var legacyManifestCLI string
	set.StringVar(&legacyManifestCLI, "manifest-cli", "", "") // accepted and ignored: the manifest is built in-process
	if err := set.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			_, _ = io.WriteString(s.Out, usageText)
			return c, cli.ExitOK, false
		}
		fmt.Fprintf(s.Err, "%scorroborate-native: error: %v\n", usageText, err)
		return c, cli.ExitUsage, false
	}
	seen := map[string]bool{}
	set.Visit(func(f *flag.Flag) { seen[f.Name] = true })
	var missing []string
	for _, name := range []string{"input", "output"} {
		if !seen[name] {
			missing = append(missing, "--"+name)
		}
	}
	if len(missing) > 0 || set.NArg() > 0 {
		why := "the following arguments are required: " + strings.Join(missing, ", ")
		if len(missing) == 0 {
			why = "unrecognized arguments: " + strings.Join(set.Args(), " ")
		}
		fmt.Fprintf(s.Err, "%scorroborate-native: error: %s\n", usageText, why)
		return c, cli.ExitUsage, false
	}
	return c, 0, true
}
