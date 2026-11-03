package java

import (
	"errors"
	"flag"
	"io"
	"strconv"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

const usage = `usage: corroborate-java --decompile-wrapper WRAPPER [--manifest-module MODULE] --input JAR --output DIR
                        [--overwrite] [--timeout-seconds N] [--max-heap SIZE]
                        [--max-files N] [--max-bytes N] [--max-classes N]

Produce bounded, reproducible evidence from five non-executing JVM adapters (java-corroboration.v1).
Exit codes: 0 complete, 1 an adapter failed (evidence published), 2 fatal (no evidence).
`

// options are the parsed command line.
type options struct {
	decompileWrapper, manifestModule string
	input, output                    string
	overwrite                        bool
	timeoutSeconds                   int
	maxHeap                          string
	maxFiles, maxBytes, maxClasses   int64
}

// positive is argparse's `type=positive`: a base-10 integer above zero. A value past 64 bits saturates, which no
// cap can exceed either way.
func positive(raw string) (int64, error) {
	v, err := strconv.ParseInt(strings.TrimSpace(raw), 10, 64)
	if errors.Is(err, strconv.ErrRange) && !strings.HasPrefix(strings.TrimSpace(raw), "-") {
		return 1<<63 - 1, nil
	}
	if err != nil {
		return 0, errors.New("invalid positive value: " + pyQuote(raw))
	}
	if v <= 0 {
		return 0, errors.New("must be positive")
	}
	return v, nil
}

func pyQuote(s string) string { return "'" + s + "'" }

// validHeap is `[1-9][0-9]{0,5}[mMgG]`, fully matched.
func validHeap(s string) bool {
	if len(s) < 2 || len(s) > 7 || s[0] < '1' || s[0] > '9' {
		return false
	}
	for _, c := range s[1 : len(s)-1] {
		if c < '0' || c > '9' {
			return false
		}
	}
	return strings.ContainsRune("mMgG", rune(s[len(s)-1]))
}

// parse is the argparse of corroborate_java.py; the second result is -1 when parsing succeeded, else the exit code.
func (e *env) parse(args []string) (options, int) {
	o := options{}
	fs := flag.NewFlagSet("corroborate-java", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	fs.StringVar(&o.decompileWrapper, "decompile-wrapper", "", "")
	fs.StringVar(&o.manifestModule, "manifest-module", "", "")
	fs.StringVar(&o.input, "input", "", "")
	fs.StringVar(&o.output, "output", "", "")
	fs.BoolVar(&o.overwrite, "overwrite", false, "")
	numbers := map[string]*string{}
	for _, n := range []string{"timeout-seconds", "max-files", "max-bytes", "max-classes"} {
		numbers[n] = fs.String(n, "", "")
	}
	fs.StringVar(&o.maxHeap, "max-heap", "1024m", "")
	usageError := func(msg string) (options, int) {
		_, _ = io.WriteString(e.s.Err, usage+"corroborate-java: error: "+msg+"\n")
		return o, cli.ExitUsage
	}
	if err := fs.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			_, _ = io.WriteString(e.s.Out, usage)
			return o, cli.ExitOK
		}
		return usageError(err.Error())
	}
	var missing []string
	for _, r := range [][2]string{{"--decompile-wrapper", o.decompileWrapper}, {"--input", o.input}, {"--output", o.output}} {
		if r[1] == "" {
			missing = append(missing, r[0])
		}
	}
	if len(missing) > 0 {
		return usageError("the following arguments are required: " + strings.Join(missing, ", "))
	}
	if fs.NArg() > 0 {
		return usageError("unrecognized arguments: " + strings.Join(fs.Args(), " "))
	}
	defaults := map[string]int64{"timeout-seconds": 120, "max-files": 20_000, "max-bytes": 1_073_741_824, "max-classes": 10_000}
	values := map[string]int64{}
	for _, n := range []string{"timeout-seconds", "max-files", "max-bytes", "max-classes"} {
		if *numbers[n] == "" {
			values[n] = defaults[n]
			continue
		}
		v, err := positive(*numbers[n])
		if err != nil {
			return usageError("argument --" + n + ": " + err.Error())
		}
		values[n] = v
	}
	if !validHeap(o.maxHeap) {
		return usageError("--max-heap must look like 1024m or 2g")
	}
	o.timeoutSeconds = int(min(values["timeout-seconds"], 1<<31-1))
	o.maxFiles, o.maxBytes, o.maxClasses = values["max-files"], values["max-bytes"], values["max-classes"]
	return o, -1
}
