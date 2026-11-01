// Package hook owns the rsdd commands for session-start sweeps and the kit-run hook entry points,
// and the predicates behind lib/hook-wiring.sh (kit issues #2356, #2357).
//
// Go API (every function takes an Env; EnvFrom builds it from cli.Stdio, and cwd, HOME, RSDD_CLAUDE_PROJECTS_DIR,
// CLAUDE_CONFIG_DIR and RSDD_HOOK_WIRING_CEILING are read only through it):
//
//	WiringState(e, target) string           wired|wired-off-root|unwired|absent-settings|unreadable (Wiring* consts)
//	ScriptState(e, target) string           present|missing|unverifiable|no-entry|degraded (Script* consts)
//	LaunchState(e, target) string           launched|no-sessions|unknown (Launch* consts): was a Claude Code
//	                                        session ever launched from exactly this directory
//	WiredExecReport(e, target) []Finding    not-executable|missing|unverifiable findings for every command wired in
//	                                        settings.json (Finding.String is the tab-separated line;
//	                                        FormatFindings is the whole report)
//	FindGitRoot(e, target), AbsPath(cwd, p) the helpers they share
//
// CLI: rsdd hook wiring-state|launch-state <target-dir>... (one state per line, one fork for a whole fleet),
// rsdd hook script-state|wired-exec|git-root <arg>. See docs/adding-a-command.md.
package hook

import "github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"

// Commands is this domain's contribution to the command table. A unit adds
// its entries here and never edits internal/commands.
var Commands = []cli.Command{
	{Name: "wiring-state", Group: "hook", Summary: "Stop-hook wiring of each <target-dir>..., one state per line: wired|wired-off-root|unwired|absent-settings|unreadable", Run: runWiringState},
	{Name: "script-state", Group: "hook", Summary: "does a Stop retro-gate command of <target-dir> name an existing script: present|missing|unverifiable|no-entry|degraded", Run: runScriptState},
	{Name: "launch-state", Group: "hook", Summary: "was a Claude Code session ever launched from each <target-dir>..., one state per line: launched|no-sessions|unknown", Run: runLaunchState},
	{Name: "wired-exec", Group: "hook", Summary: "does each command wired in <target-dir>/.claude/settings.json name an existing, executable script: not-executable|missing|unverifiable lines", Run: runWiredExec},
	{Name: "git-root", Group: "hook", Summary: "nearest git root above <dir> (helper of lib/hook-wiring.sh): line 1 target-is-root 0|1, line 2 the root", Run: runGitRoot},
}
