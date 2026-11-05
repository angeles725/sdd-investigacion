package sweep

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/kit"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/proc"
)

// Port of research-sdd/toolbelt/sweep-all.sh (kit issue #2664):
//
//	rsdd sweep all [--kit <dir>]
//
// The aggregator for the harnesses without a SessionStart hook (Pi, gentle-shell): it runs the eight canonical
// session-start scripts (allscripts.go) in sequence, each INDEPENDENTLY, so a failure or a timeout is reported and
// never stops the rest. Every script runs as `bash <toolbelt>/<name>` with its stderr merged into its stdout and
// under RSDD_SWEEP_TIMEOUT seconds (default 30); a PASS or FAIL banner follows each script's output, a summary
// closes the run, and the exit code is 0 only when all eight passed. The toolbelt is <kit>/toolbelt: the shim
// passes the kit it lives in as --kit, run directly the kit is resolved like the other sweeps do.
//
// The scripts span the sweep and verify domains, so the command execs the toolbelt shims instead of importing
// either domain: each child gets the caller's environment through kit.ShimEnv, which hands it this binary as
// RSDD_BIN (the shims then skip their source-fingerprint check), and runs under core/proc, which owns the
// timeout, the process-group kill and the output bound. The scripts are read-only audits; so is this command.
//
// Declared differences from the script, each pinned by a test (the table is tool-registry.d/sweep-all.md):
//
//   - A script that exits 124 itself is reported as "exit 124"; the script read every 124 as a timeout.
//   - A script that ignores SIGTERM is killed after a grace period; `timeout` sent TERM only and waited forever.
//   - A script killed by a signal is "killed by signal N" (the script said "exit 128+N").
//   - RSDD_SWEEP_TIMEOUT must be a positive number of seconds (at most a year); anything else falls back to 30 s
//     with a warning line on stderr. The script passed it to `timeout`: "abc" failed all eight scripts
//     with exit 125, "0" ran them unbounded and "2m" printed "timed out after 2ms".
//   - Each script's output is bounded (allMaxBytes); reaching the bound stops the script as a typed failure.
//   - A script that cannot be started is a typed FAIL banner (the script reported exit 127 from `timeout`).
//   - The header of the script promised that a non-executable script is a FAIL; it never was (bash reads it). Kept:
//     the script runs, and the real toolbelt's modes are checked by tests/sweep-all.test.sh.

// allConfig holds the seams of a run: tests inject the runner and the output bound.
type allConfig struct {
	run      scriptRunner
	maxBytes int
}

// defaultAllConfig is the real run: core/proc and the documented output bound.
func defaultAllConfig() allConfig { return allConfig{run: proc.Run, maxBytes: allMaxBytes} }

// parseAllOptions reads the one option of `sweep all`, --kit DIR. Unlike the script, which ignored every other
// argument and still exited 0, any other argument (--json, --hook, a stray word) is a usage error: the aggregator
// has no machine output, so a caller that asks for one must learn it did not get it.
func parseAllOptions(args []string) (options, error) {
	var o options
	for i := 0; i < len(args); i++ {
		if args[i] != "--kit" {
			return o, fmt.Errorf("unsupported argument %q (usage: sweep all [--kit DIR])", args[i])
		}
		if i+1 == len(args) {
			return o, fmt.Errorf("--kit needs a directory")
		}
		i++
		o.kit = args[i]
	}
	return o, nil
}

// RunAll is the `sweep all` command.
func RunAll(args []string, s cli.Stdio) int {
	o, err := parseAllOptions(args)
	if err != nil {
		fmt.Fprintf(s.Err, "sweep-all: %v\n", err)
		return cli.ExitUsage
	}
	if o.kit == "" {
		script, _, err := kit.ResolveKitScript("toolbelt/sweep-all.sh", s.Env)
		if err != nil {
			fmt.Fprintf(s.Err, "sweep-all: %v\n", err)
			return cli.ExitOperational
		}
		o.kit = filepath.Dir(filepath.Dir(script))
	}
	kitDir, err := resolveKit(o, s)
	if err != nil {
		fmt.Fprintf(s.Err, "sweep-all: %v\n", err)
		return cli.ExitOperational
	}
	return sweepAll(kitDir+"/toolbelt", s, defaultAllConfig())
}

// sweepAll runs the eight scripts of toolbelt and prints the banners and the summary.
func sweepAll(toolbelt string, s cli.Stdio, cfg allConfig) int {
	timeout, warn := parseSweepTimeout(s.Env("RSDD_SWEEP_TIMEOUT"))
	if warn != "" {
		fmt.Fprintln(s.Err, warn)
	}
	environ := s.Environ()
	if environ == nil {
		environ = []string{} // a nil Env would mean "no environment" to proc and "inherit" to exec: be explicit
	}
	env := kit.ShimEnv(environ, os.Executable)
	bar := strings.Repeat("=", 40)

	var results []string
	overall := 0
	for _, name := range allScripts {
		script := toolbelt + "/" + name
		fmt.Fprintf(s.Out, "\n%s\n== %s\n%s\n", bar, name, bar)
		if !isRegularFile(script) {
			fmt.Fprintf(s.Err, "FAIL  %s (script not found: %s)\n", name, script)
			results = append(results, "FAIL  "+name+" (not found)")
			overall = 1
			continue
		}
		out := runScript(cfg.run, proc.Spec{Argv: scriptArgv(script), Dir: s.Cwd, Env: env,
			Timeout: timeout.d, MaxBytes: cfg.maxBytes}, timeout.shown)
		s.Out.Write(out.output)
		if out.ok {
			fmt.Fprintf(s.Out, "\nPASS  %s\n", name)
			results = append(results, "PASS  "+name)
			continue
		}
		fmt.Fprintf(s.Out, "\nFAIL  %s %s\n", name, out.detail)
		results = append(results, "FAIL  "+name+" "+out.short)
		overall = 1
	}

	fmt.Fprintf(s.Out, "\n%s\n== sweep-all summary\n%s\n", bar, bar)
	for _, r := range results {
		fmt.Fprintf(s.Out, "  %s\n", r)
	}
	return overall
}
