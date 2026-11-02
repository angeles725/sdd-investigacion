package verify

import "github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"

// registryHooks is everything `verify registry` needs from lib/hook-wiring.sh and from verify-session-budget.sh.
// Each method reports ok=false when the check could not run; the command then skips that section, counts it
// and says so on stderr (anti-silent-zero: a skipped check is never a clean one).
//
// The production implementation (unportedHooks) runs none of them: lib/hook-wiring.sh is being ported to
// internal/hook (U2.3a #2356, U2.3b #2357) and verify-session-budget.sh is not ported. This package cannot
// import internal/hook (archtest: a domain imports only the core tier), so the real implementation has to
// arrive through newRegistryHooks, set by the registry tier or after the helper moves to internal/core.
// Production code never shells out to bash for them; the differential test supplies a bash-backed
// implementation of its own.
type registryHooks interface {
	// StopWiringState is hook_stop_wiring_state: wired | wired-off-root | unwired | absent-settings | unreadable.
	StopWiringState(target string) (string, bool)
	// StopScriptState is hook_stop_script_state: present | missing | unverifiable | no-entry | degraded.
	StopScriptState(target string) (string, bool)
	// StopLaunchState is hook_stop_launch_state: launched | no-sessions | unknown.
	StopLaunchState(target string) (string, bool)
	// WiredExecReport is hook_wired_exec_report, one entry per output line (kind, path, detail).
	WiredExecReport(target string) ([]wiredExec, bool)
	// SessionBudget is the combined stdout and stderr of `verify-session-budget.sh <target>`.
	SessionBudget(target string) (string, bool)
}

// wiredExec is one `kind<TAB>path<TAB>detail` line of hook_wired_exec_report.
type wiredExec struct{ Kind, Path, Detail string }

type unportedHooks struct{}

func (unportedHooks) StopWiringState(string) (string, bool)      { return "", false }
func (unportedHooks) StopScriptState(string) (string, bool)      { return "", false }
func (unportedHooks) StopLaunchState(string) (string, bool)      { return "", false }
func (unportedHooks) WiredExecReport(string) ([]wiredExec, bool) { return nil, false }
func (unportedHooks) SessionBudget(string) (string, bool)        { return "", false }

// newRegistryHooks builds the hook checks for one run. Swapping this one line is how internal/hook plugs in.
var newRegistryHooks = func(cli.Stdio) registryHooks { return unportedHooks{} }
