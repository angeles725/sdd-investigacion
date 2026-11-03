package verify

import (
	"bytes"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/hookwiring"
)

// registryHooks is everything `verify registry` needs from lib/hook-wiring.sh and from verify-session-budget.sh.
// Each method reports ok=false when the check could not run; the command then skips that section, counts it
// and says so on stderr (anti-silent-zero: a skipped check is never a clean one).
//
// The production implementation is productionHooks: the hook-wiring predicates run in process through
// internal/core/hookwiring (a domain may import the core tier), and the session-budget meter through
// SessionBudgetRunner, which the composition tier (internal/commands) sets because this package cannot import
// internal/budget (archtest: a domain imports only the core tier). Production code never shells out to bash
// for them; the differential test supplies a bash-backed implementation of its own.
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

// SessionBudgetRunner is `budget session`: it takes the command's arguments and Stdio and returns its exit code.
// internal/commands sets it. While it is nil the session-budget check cannot run, and says so (counted skip).
var SessionBudgetRunner func(args []string, s cli.Stdio) int

// toolbeltSetter is implemented by hooks that need the toolbelt directory, known only once the kit is resolved.
type toolbeltSetter interface{ setToolbelt(dir string) }

// productionHooks is the registryHooks of a real run.
type productionHooks struct {
	s        cli.Stdio
	env      hookwiring.Env
	toolbelt string
}

func newProductionHooks(s cli.Stdio) *productionHooks {
	return &productionHooks{s: s, env: hookwiring.EnvFrom(s)}
}

func (h *productionHooks) setToolbelt(dir string) { h.toolbelt = dir }

func (h *productionHooks) StopWiringState(t string) (string, bool) {
	return hookwiring.WiringState(h.env, t), true
}
func (h *productionHooks) StopScriptState(t string) (string, bool) {
	return hookwiring.ScriptState(h.env, t), true
}
func (h *productionHooks) StopLaunchState(t string) (string, bool) {
	return hookwiring.LaunchState(h.env, t), true
}

func (h *productionHooks) WiredExecReport(t string) ([]wiredExec, bool) {
	var rows []wiredExec
	for _, f := range hookwiring.WiredExecReport(h.env, t) {
		rows = append(rows, wiredExec{f.Kind, f.Subject, f.Detail})
	}
	return rows, true
}

// SessionBudget runs the meter as the script did: toolbelt beside verify-registry.sh, stdout and stderr in one
// stream, the exit code ignored (a run that printed no `state:` line reads as degraded, never as clean).
func (h *productionHooks) SessionBudget(t string) (string, bool) {
	if SessionBudgetRunner == nil {
		return "", false
	}
	var buf bytes.Buffer
	sc := h.s
	sc.Out, sc.Err = &buf, &buf
	SessionBudgetRunner([]string{"--toolbelt", h.toolbelt, t}, sc)
	return strings.TrimRight(buf.String(), "\n"), true
}

// newRegistryHooks builds the hook checks for one run; tests swap it for fakes.
var newRegistryHooks = func(s cli.Stdio) registryHooks { return newProductionHooks(s) }
