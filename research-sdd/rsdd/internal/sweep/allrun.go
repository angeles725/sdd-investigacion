package sweep

import (
	"errors"
	"fmt"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/proc"
)

// scriptRunner runs one bounded subprocess; proc.Run in production, a recorder or a fake in the tests.
type scriptRunner func(proc.Spec) (proc.Result, error)

// allMaxBytes bounds the output of one script. The script had no bound: a script that looped on its output filled
// the caller's terminal or memory. 4 MiB is far above what the eight sweeps print (a few KiB) and reaching it
// stops the script, as a typed failure.
const allMaxBytes = 4 << 20

// scriptArgv is `bash script` with stderr merged into stdout at the file-descriptor level, so the two streams
// keep the order the script wrote them in (proc keeps the streams apart). The script is the wrapper's $1, never
// spliced into the command text.
func scriptArgv(script string) []string {
	return []string{"bash", "-c", `exec 2>&1; exec bash "$1"`, "sweep-all", script}
}

// scriptOutcome is what one script's run is reported as.
type scriptOutcome struct {
	output []byte
	ok     bool
	detail string // the parenthesis of the FAIL banner, "" when ok
	short  string // the parenthesis of the summary line, "" when ok
}

// runScript runs one script under the bound and classifies the result. Everything that is not a clean exit 0 is a
// failure with its own reason, so no failure reads as another (the script's rc 124 meant both "timed out" and "the
// script itself exited 124").
func runScript(run scriptRunner, spec proc.Spec, timeoutShown string) scriptOutcome {
	res, err := run(spec)
	var spawn *proc.SpawnError
	switch {
	case errors.As(err, &spawn):
		return scriptOutcome{detail: fmt.Sprintf("(cannot start: %v)", spawn.Err), short: "(cannot start)"}
	case errors.Is(err, proc.ErrInvalidSpec):
		// A rejected spec ran nothing: a failure, never a pass.
		return scriptOutcome{detail: fmt.Sprintf("(cannot run: %v)", err), short: "(cannot run)"}
	}
	o := scriptOutcome{output: res.Stdout}
	switch {
	case err != nil:
		o.detail, o.short = fmt.Sprintf("(its process group could not be stopped: %v)", err), "(not stopped)"
	case res.Reason == proc.ReasonTimeout:
		o.detail, o.short = fmt.Sprintf("(timed out after %ss)", timeoutShown), "(timed out)"
	case res.Reason == proc.ReasonOutputCap:
		o.detail, o.short = fmt.Sprintf("(output exceeded %d bytes)", spec.MaxBytes), "(output cap)"
	case res.ReturnCode > 0:
		o.detail = fmt.Sprintf("(exit %d)", res.ReturnCode)
		o.short = o.detail
	case res.ReturnCode < 0:
		o.detail = fmt.Sprintf("(killed by signal %d)", -res.ReturnCode)
		o.short = fmt.Sprintf("(signal %d)", -res.ReturnCode)
	default:
		o.ok = true
	}
	return o
}
