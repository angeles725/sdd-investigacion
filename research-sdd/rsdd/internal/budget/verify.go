package budget

import (
	"fmt"
	"path/filepath"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/kit"
)

// Run is `rsdd budget verify [--harness claude|pi|both] <target-dir>` (port of toolbelt/verify-session-budget.sh, kit issue
// #2446): measure what a target's SessionStart hooks actually hand to Claude. Claude Code caps each hook's additionalContext /
// systemMessage / plain stdout at 10,000 characters; the excess is saved to a file and replaced by its path plus a 2,000-char
// preview Claude is not told to read. The kit budget for SessionStart is under 8,000 characters in total
// (openspec/specs/kit-session-cost/spec.md). A hook that "works" but is silently truncated is the section 7 false-confidence
// shape (kit issue #2128).
//
// Read-only toward the target (propose-never-apply): hooks run in a sandbox over a throwaway copy of <target>/.claude.
//
// Env: RSDD_BUDGET_HOOK_TIMEOUT per-hook cap in seconds (default 60). For --harness pi: RSDD_BUDGET_KIT (the kit whose sweeps
// feed the extension, default this kit) and RSDD_BUDGET_PI_HOOKS (the extension source, default <kit>/install/pi/research-sdd-hooks.ts).
// A leading `--toolbelt DIR` (passed by the shim) names the toolbelt that holds lib/session-budget-pi.mjs.
//
// Exit: 0 always for findings and degraded states (WARN-only) · 2 usage error (no/unknown target dir).
func Run(args []string, s cli.Stdio) int {
	o, ok := parseArgs(args)
	if !ok {
		fmt.Fprintln(s.Err, usageLine)
		return cli.ExitUsage
	}
	if o.target == "" || !isDir(absFrom(s.Cwd, o.target)) {
		fmt.Fprintln(s.Err, usageLine)
		return cli.ExitUsage
	}
	target, err := filepath.EvalSymlinks(absFrom(s.Cwd, o.target)) // `cd "$1" && pwd -P`
	if err != nil {
		fmt.Fprintln(s.Err, usageLine)
		return cli.ExitUsage
	}
	e := env{s}
	toCap := e.get("RSDD_BUDGET_HOOK_TIMEOUT")
	if !onlyDigits(toCap) || cmpDec(toCap, "0") == 0 {
		toCap = "60"
	}
	if o.harness != "pi" {
		claudeReport(e, target, toCap, s.Out)
	}
	if o.harness != "claude" {
		piReport(e, target, toCap, e.toolbelt(o.toolbelt), s.Out)
	}
	return cli.ExitOK
}

// absFrom resolves a path against the caller's working directory.
func absFrom(cwd, p string) string {
	if filepath.IsAbs(p) || cwd == "" {
		return p
	}
	return filepath.Join(cwd, p)
}

// toolbelt is the directory holding lib/session-budget-pi.mjs: the shim's own directory when it passed one, else the kit's
// (the same resolution the hooks use). It is "" when neither is known, which the pi path reports as a missing helper.
func (e env) toolbelt(given string) string {
	if given != "" {
		return strings.TrimRight(absFrom(e.s.Cwd, given), "/")
	}
	p, _, err := kit.ResolveKitScript("toolbelt/verify-session-budget.sh", e.s.Env)
	if err != nil {
		return ""
	}
	return filepath.Dir(p)
}
