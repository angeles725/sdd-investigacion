package ghidra

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"strconv"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

const minFiles = 12

const usageText = `usage: rsdd corroborate ghidra --input FILE --output DIR [--timeout-seconds N] [--analysis-timeout N]
                               [--max-diagnostic-bytes N] [--max-output-bytes N] [--max-files N]
                               [--max-functions N] [--max-strings N] [--max-references N]
                               [--max-string-chars N] [--heap-mb N] [--cpus N]
                               [--toolbelt DIR] [--exporter FILE]

Hardened headless Ghidra adapter (ghidra-corroboration.v1) for one regular native binary.

  --input FILE              regular, non-symlink binary to analyse
  --output DIR              new evidence directory; its parent must be canonical and on a Linux-private filesystem
  --timeout-seconds N       wall-clock bound for the whole Ghidra run (default 120)
  --analysis-timeout N      Ghidra's per-file analysis timeout (default 90)
  --max-diagnostic-bytes N  joint cap on stdout, stderr and the two Ghidra logs (default 2000000)
  --max-output-bytes N      cap on the curated JSON the exporter writes (default 8000000)
  --max-files N             evidence file cap, at least 12 (default 64)
  --max-functions N         functions/symbols/imports/exports emitted per kind (default 10000)
  --max-strings N           strings emitted (default 5000)
  --max-references N        references emitted (default 20000)
  --max-string-chars N      characters kept per string (default 1024)
  --heap-mb N               Ghidra heap in MiB (default 2048)
  --cpus N                  analysis threads (default 2)
  --toolbelt DIR            kit toolbelt directory holding ghidra/CuratedEvidenceExporter.java (default: the resolved kit)
  --exporter FILE           the exporter script itself (overrides --toolbelt)

Ghidra, the JDK and Bubblewrap are resolved from the environment (ANALYZE_HEADLESS, GHIDRA_HOME, JAVA_HOME,
RSDD_BWRAP, PATH). Exit: 0 complete or partial evidence; 1 failed evidence was published; 2 refused before publishing.
`

// config is the parsed command line.
type config struct {
	input, output   string
	timeout         int
	analysisTimeout int
	maxDiagnostic   int
	maxOutput       int
	maxFiles        int
	maxFunctions    int
	maxStrings      int
	maxReferences   int
	maxStringChars  int
	heapMB          int
	cpus            int
	testOnlyBwrap   bool
	toolbelt        string
	exporter        string
}

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

// legacyFlags are the path options the old shim passed to the Python driver; the command resolves those itself.
var legacyFlags = []string{"ghidra-home", "analyze-headless", "java", "bwrap", "manifest-cli"}

// parseArgs returns the configuration and true, or the exit code to return at once.
func parseArgs(args []string, s cli.Stdio) (config, int, bool) {
	c := config{timeout: 120, analysisTimeout: 90, maxDiagnostic: 2_000_000, maxOutput: 8_000_000, maxFiles: 64,
		maxFunctions: 10_000, maxStrings: 5_000, maxReferences: 20_000, maxStringChars: 1024, heapMB: 2048, cpus: 2}
	set := flag.NewFlagSet("ghidra", flag.ContinueOnError)
	set.SetOutput(io.Discard)
	set.StringVar(&c.input, "input", "", "")
	set.StringVar(&c.output, "output", "", "")
	for name, p := range map[string]*int{
		"timeout-seconds": &c.timeout, "analysis-timeout": &c.analysisTimeout, "max-diagnostic-bytes": &c.maxDiagnostic,
		"max-output-bytes": &c.maxOutput, "max-files": &c.maxFiles, "max-functions": &c.maxFunctions,
		"max-strings": &c.maxStrings, "max-references": &c.maxReferences, "max-string-chars": &c.maxStringChars,
		"heap-mb": &c.heapMB, "cpus": &c.cpus,
	} {
		set.Var(intFlag{p}, name, "")
	}
	set.BoolVar(&c.testOnlyBwrap, "test-only-untrusted-bwrap", false, "")
	set.StringVar(&c.toolbelt, "toolbelt", "", "")
	set.StringVar(&c.exporter, "exporter", "", "")
	ignored := make([]string, len(legacyFlags))
	for i, name := range legacyFlags {
		set.StringVar(&ignored[i], name, "", "") // accepted and ignored: resolved by the command
	}
	if err := set.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			_, _ = io.WriteString(s.Out, usageText)
			return c, cli.ExitOK, false
		}
		fmt.Fprintf(s.Err, "%scorroborate-ghidra: error: %v\n", usageText, err)
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
		fmt.Fprintf(s.Err, "%scorroborate-ghidra: error: %s\n", usageText, why)
		return c, cli.ExitUsage, false
	}
	if s.Env("RSDD_TEST_ONLY_UNTRUSTED_BWRAP") == "1" {
		c.testOnlyBwrap = true
	}
	return c, 0, true
}

// capsValid is the numeric guard: every cap positive and the file cap at least minFiles.
func (c config) capsValid() bool {
	for _, n := range []int{c.timeout, c.analysisTimeout, c.maxDiagnostic, c.maxOutput, c.maxFiles, c.maxFunctions,
		c.maxStrings, c.maxReferences, c.maxStringChars, c.heapMB, c.cpus} {
		if n < 1 {
			return false
		}
	}
	return c.maxFiles >= minFiles
}
