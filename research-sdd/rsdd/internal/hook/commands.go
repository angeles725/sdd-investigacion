// Package hook owns the rsdd commands for session-start sweeps and the kit-run hook entry points. The
// hook-wiring predicates and their command handlers live in internal/core/hookwiring (kit issues #2356, #2357).
package hook

import (
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/hookwiring"
)

// Commands is this domain's contribution to the command table. A unit adds
// its entries here and never edits internal/commands.
var Commands = []cli.Command{
	{Name: "wiring-state", Group: "hook", Summary: "Stop-hook wiring of each <target-dir>..., one state per line: wired|wired-off-root|unwired|absent-settings|unreadable", Run: hookwiring.RunWiringState},
	{Name: "script-state", Group: "hook", Summary: "does a Stop retro-gate command of <target-dir> name an existing script: present|missing|unverifiable|no-entry|degraded", Run: hookwiring.RunScriptState},
	{Name: "launch-state", Group: "hook", Summary: "was a Claude Code session ever launched from each <target-dir>..., one state per line: launched|no-sessions|unknown", Run: hookwiring.RunLaunchState},
	{Name: "wired-exec", Group: "hook", Summary: "does each command wired in <target-dir>/.claude/settings.json name an existing, executable script: not-executable|missing|unverifiable lines", Run: hookwiring.RunWiredExec},
	{Name: "git-root", Group: "hook", Summary: "nearest git root above <dir> (helper of lib/hook-wiring.sh): line 1 target-is-root 0|1, line 2 the root", Run: hookwiring.RunGitRoot},
}
