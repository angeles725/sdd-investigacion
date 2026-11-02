// Package hookwiring holds the predicates behind lib/hook-wiring.sh (kit issues #2356, #2357) and the handlers of
// the `rsdd hook` commands that expose them; internal/hook registers those commands. It sits in the core tier so
// any domain (verify registry, sweep-retros) can call it.
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
// rsdd hook script-state|wired-exec|git-root <arg>; the handlers are the Run* functions.
package hookwiring
