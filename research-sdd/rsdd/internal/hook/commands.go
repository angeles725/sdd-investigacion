// Package hook owns the rsdd commands for session-start sweeps and the kit-run hook entry points,
// and the Stop-hook wiring predicates behind lib/hook-wiring.sh (kit issues #2356, #2357).
// See docs/adding-a-command.md.
package hook

import "github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"

// Commands is this domain's contribution to the command table. A unit adds
// its entries here and never edits internal/commands.
var Commands = []cli.Command{
	{Name: "wiring-state", Group: "hook", Summary: "Stop-hook wiring of <target-dir>: wired|wired-off-root|unwired|absent-settings|unreadable", Run: runWiringState},
	{Name: "script-state", Group: "hook", Summary: "does a Stop retro-gate command of <target-dir> name an existing script: present|missing|unverifiable|no-entry|degraded", Run: runScriptState},
	{Name: "git-root", Group: "hook", Summary: "nearest git root above <dir> (helper of lib/hook-wiring.sh): line 1 target-is-root 0|1, line 2 the root", Run: runGitRoot},
	{Name: "abspath", Group: "hook", Summary: "absolute, ./..-collapsed form of <path> (helper of lib/hook-wiring.sh)", Run: runAbsPath},
}
