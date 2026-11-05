package scoreloop

import (
	"fmt"
	"io"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// options are the parsed command-line arguments.
type options struct {
	corpus, transcript, baseRef, since, until string
	// toolbelt is the directory holding research-sdd-status.sh (the shim passes its own); "" resolves the kit.
	toolbelt string
	// windowExplicit records that the caller set --base-ref, --since or --until: the transcript-span default
	// window then does not apply, and C4 respects the window as given.
	windowExplicit bool
}

const usageText = `usage: score-loop-transcript.sh --corpus <dir> [--transcript <jsonl-file>]
                                 [--base-ref <ref>] [--since <date>] [--until <date>]
`

func usage(w io.Writer) { fmt.Fprint(w, usageText) }

// valueFlags maps each value-taking flag to the field it fills.
func valueFlags(o *options) map[string]*string {
	return map[string]*string{
		"--corpus": &o.corpus, "--transcript": &o.transcript, "--base-ref": &o.baseRef,
		"--since": &o.since, "--until": &o.until, "--toolbelt": &o.toolbelt,
	}
}

// parseArgs reads args. ok is false when the run must stop with exit; the message and usage are already written.
func parseArgs(args []string, errw io.Writer) (o options, exit int, ok bool) {
	flags := valueFlags(&o)
	for i := 0; i < len(args); {
		a := args[i]
		if dst, known := flags[a]; known {
			if i+1 >= len(args) {
				fmt.Fprintf(errw, "%s: %s requires a value\n", scriptName, a)
				usage(errw)
				return o, cli.ExitUsage, false
			}
			*dst = args[i+1]
			i += 2
			continue
		}
		if a == "-h" || a == "--help" {
			usage(errw)
			return o, cli.ExitUsage, false
		}
		fmt.Fprintf(errw, "%s: unknown argument: %s\n", scriptName, a)
		usage(errw)
		return o, cli.ExitUsage, false
	}
	o.windowExplicit = o.baseRef != "" || o.since != "" || o.until != ""
	return o, 0, true
}
