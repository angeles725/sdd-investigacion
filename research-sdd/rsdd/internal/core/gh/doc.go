// Package gh is the port of toolbelt/lib/gh-visibility.sh (kit issues #1820, #1841): every gh call the kit makes
// is bounded, runs with GH_PROMPT_DISABLED=1 and without GH_REPO, and ends in a typed State, never a silent empty.
//
//   - ResolveBound is _ghv_resolve_bound: the bound in seconds comes from one knob (RSDD_GH_TIMEOUT unless the
//     caller names another, as GHV_BOUND_ENV does) and falls back to the caller's default (GHV_DEFAULT_BOUND /
//     GHV_BOUND_DEFAULT, 20 when unset). A knob that is set but not a positive integer of at most 9 digits takes
//     the default and is flagged Bad; an unset knob takes it silently.
//   - Probe is gh_visibility_probe: `gh repo view <repo> --json visibility --jq .visibility`. Only PUBLIC,
//     PRIVATE and INTERNAL are decided; every other State means "unknown" and must never be read as PRIVATE.
//   - Run is gh_bounded_run: any other gh call under the same bound. A TIMEOUT means the remote operation may
//     or may not have landed: the caller re-reads the state it cares about.
//
// Every run goes through core/proc, so the bound is a process-group kill (TERM, then KILL after a 2 s grace)
// on every platform. That replaces the bash bounder ladder (timeout, gtimeout, watchdog) and with it the
// GHV_BOUNDED_BY, GHV_GROUP and GHV_NOTE globals: there is no degraded child-only mode to report.
//
// Differences, by design:
//   - Output is captured, not passed through: Run returns gh's stdout and stderr and the caller writes them.
//     Stdin is /dev/null (gh never prompts here anyway), and the joint output is capped at MaxBytes; reaching
//     the cap is the typed OUTPUT_CAP, which the bash (uncapped) has no counterpart for.
//   - The Go side has no signal traps, so there is no CALLER_SIGNALLED state, and no temp files, so
//     PROBE_FAILED only means that core/proc refused or could not finish the run (the error says why).
//   - Bound is zero for GH_MISSING (nothing was bounded); the bash leaves its unvalidated default there.
//   - A non-positive default falls back to 20; the bash would pass 0 to timeout(1), which means no bound.
//   - The probe kills a TERM-ignoring gh after the grace, where `timeout` without -k would wait forever.
package gh
