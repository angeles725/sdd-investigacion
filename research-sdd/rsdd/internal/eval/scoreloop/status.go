package scoreloop

import (
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/kit"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/proc"
)

const (
	statusTimeout   = 10 * time.Minute
	statusMaxBytes  = 64 << 20
	statusScriptRel = "research-sdd-status.sh"
	// stderrLineMax bounds the status script's own stderr line kept in the degraded evidence.
	stderrLineMax = 200
)

// statusOutcome is the two runs of research-sdd-status.sh C4 needs: the default report (the campaign queue lines)
// and `--next` (the verdict line). stdout and stderr are kept apart so a stderr WARN can never land before the
// ^STOP / ^STALE the verdict is matched on.
type statusOutcome struct {
	def, next       string // stdout with trailing newlines trimmed (the shell's $(...) did the same)
	rcDef, rcNext   int
	stderrFirstLine string // first line of both runs' stderr, bounded
	// problem is set when a run could not be made at all (bash missing, a timeout): the typed degraded reason.
	problem string
}

// statusRunner runs the status script against a corpus.
type statusRunner func(script, corpus string) statusOutcome

// newStatusRunner returns the runner that execs `bash <script> <corpus> [--next]` with env.
func newStatusRunner(env []string) statusRunner {
	return statusRunnerWith(env, statusTimeout, statusMaxBytes)
}

// statusRunnerWith is newStatusRunner with explicit bounds (a unit test shrinks them).
func statusRunnerWith(env []string, timeout time.Duration, maxBytes int) statusRunner {
	return func(script, corpus string) statusOutcome {
		var out statusOutcome
		var stderr []byte
		for _, extra := range [][]string{nil, {"--next"}} {
			res, err := proc.Run(proc.Spec{
				Argv: append([]string{"bash", script, corpus}, extra...), Env: env,
				Timeout: timeout, MaxBytes: maxBytes,
			})
			if problem := runProblem(res, err); problem != "" {
				out.problem = problem
				return out
			}
			stderr = append(stderr, res.Stderr...)
			text, rc := strings.TrimRight(string(res.Stdout), "\n"), exitCode(res.ReturnCode)
			if extra == nil {
				out.def, out.rcDef = text, rc
			} else {
				out.next, out.rcNext = text, rc
			}
		}
		out.stderrFirstLine = firstLine(string(stderr), stderrLineMax)
		return out
	}
}

// runProblem names why a run could not be made: bash missing, a timeout, the output cap, or a spawn failure.
func runProblem(res proc.Result, err error) string {
	switch {
	case errors.Is(err, exec.ErrNotFound):
		return "bash not found in PATH — cannot run " + statusScriptRel
	case err != nil:
		return "cannot run " + statusScriptRel + ": " + err.Error()
	case res.Reason != "":
		return statusScriptRel + " stopped (" + res.Reason + ")"
	}
	return ""
}

// exitCode is the shell's $?: the status, or 128+N for a run killed by signal N.
func exitCode(rc int) int {
	if rc < 0 {
		return 128 - rc
	}
	return rc
}

// firstLine is the first line of text cut to max bytes (cut -c1-N counted bytes).
func firstLine(text string, max int) string {
	line, _, _ := strings.Cut(text, "\n")
	return line[:min(len(line), max)]
}

// statusScriptPath is the script C4 runs: RSDD_STATUS_SCRIPT, else research-sdd-status.sh beside the shim
// (--toolbelt), else the one the kit resolution finds. unresolved is a path that names what was looked for.
func statusScriptPath(cfg *Config, opt options, getenv func(string) string) string {
	switch {
	case cfg.StatusEnv != "":
		return cfg.StatusEnv
	case opt.toolbelt != "":
		return filepath.Join(opt.toolbelt, statusScriptRel)
	}
	if p, _, err := kit.ResolveKitScript("toolbelt/"+statusScriptRel, getenv); err == nil {
		return p
	}
	return "<kit>/toolbelt/" + statusScriptRel
}

// readable is the shell's `[[ -r path ]]`.
func readable(path string) bool {
	f, err := os.Open(path)
	if err != nil {
		return false
	}
	_ = f.Close()
	return true
}
