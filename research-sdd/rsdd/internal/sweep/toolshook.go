package sweep

import (
	"bytes"
	"fmt"
	"regexp"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// Port of research-sdd/toolbelt/sweep-tools-hook.sh (kit issue #2361), `rsdd sweep tools --hook`: the
// SessionStart hook that runs the census and surfaces its headline when tools are unrecorded or registered
// targets could not be traversed. It is silent only when every tool is ledgered AND every target was reached;
// the per-target detail stays behind `rsdd sweep tools`. Like the script it always exits 0: a hook never fails
// the session.
//
// The census runs in process (the script ran sweep-tools.sh with `2>&1`), so its stdout and stderr share one
// buffer and keep the order they were written in. The seam is the pure function toolsHookContext. The envelope
// is the one of the retro hook (writeSessionStart).

const (
	toolsHookFailedFmt  = "Research-SDD tools sweep could not run (exit %d — check TARGETS.md and lib/ helper):"
	toolsHookNoSummary  = "Research-SDD tools sweep: missing Summary line — unexpected output from sweep-tools.sh:"
	toolsHookAbsentHdr  = "Research-SDD tool ledger (targets not traversed):"
	toolsHookUnrecorded = "Research-SDD tool ledger (unrecorded tools found):"
	toolsHookBreakdown  = "Run toolbelt/sweep-tools.sh for per-target breakdown."
)

var reUnrecorded = regexp.MustCompile(`([0-9]+) unrecorded`)

// TODO(#2610): wrap in the core panic guard once it lands
func runToolsHook(o options, s cli.Stdio, read readFunc) int {
	var buf bytes.Buffer // one writer for both streams: the script's `2>&1`
	rc := sweepTools(o, s, &buf, &buf, read)
	if ctx, emit := toolsHookContext(strings.TrimRight(buf.String(), "\n"), rc); emit {
		writeSessionStart(s.Out, ctx)
	}
	return cli.ExitOK
}

// linesWith is the lines of out that satisfy keep, joined by newlines (what `grep` printed).
func linesWith(out string, keep func(string) bool) string {
	var got []string
	for _, l := range strings.Split(out, "\n") {
		if keep(l) {
			got = append(got, l)
		}
	}
	return strings.Join(got, "\n")
}

// toolsHookContext is the additionalContext for the output of one census run (trailing newlines stripped) and
// its exit code, and whether anything is to be said at all.
func toolsHookContext(out string, rc int) (ctx string, emit bool) {
	if rc != 0 {
		return fmt.Sprintf(toolsHookFailedFmt, rc) + "\n" + out, true
	}
	summary := linesWith(out, func(l string) bool { return strings.HasPrefix(l, "Summary:") })
	// ANTI-SILENT-ZERO: a census that ran but printed no Summary line is a broken instrument, not a clean fleet.
	if summary == "" {
		return toolsHookNoSummary + "\n" + out, true
	}
	unrecorded := "0"
	if m := reUnrecorded.FindStringSubmatch(summary); m != nil {
		unrecorded = m[1]
	}
	absent := linesWith(out, func(l string) bool { return strings.HasPrefix(l, "INFO:") && strings.Contains(l, "not traversed") })
	if unrecorded == "0" && absent == "" {
		return "", false
	}
	warn := linesWith(out, func(l string) bool { return strings.HasPrefix(l, "WARN:") })
	if unrecorded == "0" {
		detail := summary + "\n" + absent
		if warn != "" {
			detail += "\n" + warn
		}
		return toolsHookAbsentHdr + "\n" + detail + "\n" + toolsHookBreakdown, true
	}
	detail := summary
	if warn != "" {
		detail += "\n" + warn
	}
	if absent != "" {
		detail += "\n" + absent
	}
	return toolsHookUnrecorded + "\n" + detail + "\n" + toolsHookBreakdown, true
}
