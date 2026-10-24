// Package proc runs a subprocess under bounds and is the one home of the
// kill-safety guard: no process group is ever signalled except through
// CheckGroup/SignalGroup, which refuse group ids <= 1, a group that is not
// the child's recorded one, the caller's own group, and a group with no
// member left.
//
// Run is the port of adapter_core.run_bounded (toolbelt/lib/adapter_core.py):
//
//   - The program leads a new process group (start_new_session). A name
//     without a slash is searched on the spec's own PATH, as Popen does with
//     an explicit env; a program that cannot be started is a *SpawnError
//     (Popen raises), never a Result.
//   - Wall clock >= Timeout stops the run with Reason "timeout"; stdout+stderr
//     reaching MaxBytes (>=, jointly) stops it with "output-cap", also when
//     only detected after the exit.
//   - Stopping is stop_group: TERM to the group, up to Grace for it to empty,
//     KILL, up to Grace again. It also runs after a normal exit, so a leftover
//     background job is stopped too.
//   - Output is cut jointly to MaxBytes: stdout keeps its first bytes, stderr
//     gets the rest. Errors() is run_bounded's list: [reason], else
//     ["analyzer-exit:<code>"] for a non-zero ReturnCode (negative = signal).
//   - Limits replace the RLIMIT_FSIZE preexec: Go has no preexec hook, so the
//     child re-execs through `rsdd __exec` (HelperMain), which lowers each
//     limit to min(value, hard) and then execs the program. A caller porting
//     run_bounded passes Limit{"fsize", MaxBytes}.
//
// Differences, by design: output is captured from pipes, not written to
// engine/stdout.txt (callers write the files); stdin is /dev/null, not
// inherited; a limit that cannot be set fails the helper (exit 125) instead
// of being skipped; max_processes / tree_size are not ported (no caller of
// run_bounded passes it; corroborate_firmware keeps its own copy).
package proc

import "errors"

// ErrGroupGone is what a refusal unwraps to when the group to signal no
// longer has any member: there is nothing left to stop.
var ErrGroupGone = errors.New("process group no longer exists")
