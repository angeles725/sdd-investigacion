package verify

import (
	"regexp"
	"strings"
)

// The sections of `verify registry` that read lib/hook-wiring.sh and verify-session-budget.sh, through
// registryHooks. Each message is the script's, byte for byte.

const (
	settingsNote = "(checked path only — settings.local.json and user-level ~/.claude/settings.json are not inspected)"
)

// call counts a check the hooks could not run and returns its value ("" then).
func (r *registry) call(v string, ok bool) string {
	if !ok {
		r.skipped++
	}
	return v
}

// sessionBudget is the opt-in SESSIONSTART BUDGET check (kit issue #2129): RSDD_REGISTRY_SESSION_BUDGET=1 and a
// target settings.json.
func (r *registry) sessionBudget(p, name string) {
	if r.env("RSDD_REGISTRY_SESSION_BUDGET") != "1" || !isFileOS(p+"/.claude/settings.json") {
		return
	}
	if !isFileOS(r.toolbelt + "/verify-session-budget.sh") {
		r.finding("session-budget-degraded", "WARN", name, name+" — SessionStart budget check could not run: verify-session-budget.sh is missing beside verify-registry.sh (a degraded measurement, not a zero).")
		return
	}
	out, ok := r.hooks.SessionBudget(p)
	if !ok {
		r.skipped++
		return
	}
	lines := strings.Split(strings.TrimRight(out, "\n"), "\n")
	has := func(sub string) bool { return strings.Contains(out, sub) }
	linePrefix := func(pre string) bool {
		for _, l := range lines {
			if strings.HasPrefix(l, pre) {
				return true
			}
		}
		return false
	}
	if has("status=TRUNCATED") {
		r.finding("session-budget-truncated", "WARN", name, name+" — a SessionStart hook emits more than 10,000 characters, so Claude Code truncates it to a path plus a 2,000-char preview Claude is not told to read; shrink or split the hook (run verify-session-budget.sh "+p+" for per-hook numbers; propose-never-apply).")
	}
	if has("status=timed-out") {
		r.finding("session-budget-timed-out", "WARN", name, name+" — a SessionStart hook outlives its own configured timeout, so Claude Code kills it and it contributes nothing (the budget numbers do not show this); fix or raise the hook's timeout (run verify-session-budget.sh "+p+" for the hook; propose-never-apply).")
	}
	if has("OVER BUDGET") {
		var agg, worst []string
		for _, l := range lines {
			if m := reAggChars.FindStringSubmatch(l); m != nil {
				agg = append(agg, m[1])
			}
			if strings.HasPrefix(l, "aggregate: ") {
				if i := strings.LastIndex(l[len("aggregate: "):], " worst-source="); i >= 0 {
					worst = append(worst, l[len("aggregate: ")+i+len(" worst-source="):])
				}
			}
		}
		r.finding("session-budget-over", "WARN", name, name+" — SessionStart hooks total "+strings.Join(agg, "\n")+" characters, over the kit's 8,000-char budget (worst session source: "+strings.Join(worst, "\n")+"; run verify-session-budget.sh "+p+" for per-hook numbers; propose-never-apply).")
	}
	if !linePrefix("state:") {
		r.finding("session-budget-degraded", "WARN", name, name+" — the SessionStart budget check produced no 'state:' line (crashed, was killed or exited early), so nothing was measured; this is a degraded result, not a clean one (run verify-session-budget.sh "+p+").")
	} else if linePrefix("state: degraded") {
		r.finding("session-budget-degraded", "WARN", name, name+" — at least one SessionStart hook could not be measured (timeout, non-zero exit, unresolvable, no usable sandbox or locale); the figures are partial, not zero (run verify-session-budget.sh "+p+").")
	}
}

// hookClaims reconciles the row's `hook ...` claims against the target's Stop-hook wiring (kit issues #1108,
// #1128, #1135, #1157): `hook yes`, `hook file yes / unregistered | registered-no-sessions` and `hook no`.
// It reports whether hook-registered-never-loaded fired, which the wired-hook check must not double count.
func (r *registry) hookClaims(p, name, inner string) (nlEmitted bool) {
	toks := hookTokens(inner)
	if claim := firstMatch(toks, reHookYes); claim != "" {
		state, ok := r.hooks.StopWiringState(p)
		if !ok {
			r.skipped++
		} else {
			script := ""
			if state == "wired" || state == "wired-off-root" {
				script = r.call(r.hooks.StopScriptState(p))
			}
			if script == "degraded" {
				r.finding("hook-script-degraded", "WARN", name, name+" — row claims '"+claim+"' and the Stop hook is registered at "+p+"/.claude/settings.json, but the script-resolution check degraded (awk unavailable or failed); whether the hook can load is unknown, not confirmed (propose-never-apply).")
				r.attention++
			}
			switch {
			case script == "missing":
				nlEmitted = true
				r.finding("hook-registered-never-loaded", "WARN", name, name+" — row claims '"+claim+"' and the Stop hook is registered at "+p+"/.claude/settings.json but EVERY registered retro-gate command names a script that does not exist (one present entry would let it load), so the hook can never load (registered-never-loaded; checked path only — settings.local.json and user-level ~/.claude/settings.json are not inspected; executable bit and launch directory are not checked); restore the script or refresh the row (propose-never-apply).")
				r.attention++
			case state == "wired-off-root":
				r.finding("hook-off-root", "WARN", name, name+" — row claims '"+claim+"' but "+p+" is not its own git root; the hook is expected to fire only for a session launched in exactly that directory (observed Claude Code behavior, not a cited spec; kit issue #1134). Confirm which directory sessions actually launch from and register/wire that directory (checked path only — settings.local.json and user-level ~/.claude/settings.json are not inspected); refresh the row accordingly (propose-never-apply).")
				r.attention++
			case state != "wired":
				r.finding("hook-unwired", "WARN", name, name+" — row claims '"+claim+"' but the Stop hook is "+state+" at "+p+"/.claude/settings.json "+settingsNote+"; refresh the row or wire the hook (propose-never-apply).")
				r.attention++
			}
			if script != "" && script != "missing" {
				if r.call(r.hooks.StopLaunchState(p)) == "no-sessions" {
					r.finding("hook-registered-no-sessions", "WARN", name, name+" — row claims '"+claim+"' and the Stop hook is registered at "+p+"/.claude/settings.json, but there is no retained Claude Code transcript for a session launched from exactly "+p+" (Claude Code prunes old transcripts; the Stop hook in .claude/settings.json is Claude-Code-specific, so a target worked in another harness reads the same), so it is not known to have loaded (registered-no-sessions; launch directory is a maintainer decision, kit issue #1134); refresh the row to 'hook file yes / registered-no-sessions' or launch Claude Code sessions there (propose-never-apply).")
					r.attention++
				}
			}
		}
	}

	if anyMatch(toks, reHookFileYes) {
		isUnreg, isNosess := anyEqual(toks, "unregistered"), anyEqual(toks, "registered-no-sessions")
		if isUnreg || isNosess {
			state, ok := r.hooks.StopWiringState(p)
			if !ok {
				r.skipped++
			} else {
				script := ""
				if state == "wired" || state == "wired-off-root" {
					script = r.call(r.hooks.StopScriptState(p))
				}
				if script != "" && script != "missing" {
					launch := r.call(r.hooks.StopLaunchState(p))
					if isUnreg {
						var cure string
						switch launch {
						case "no-sessions":
							cure = "there is no retained Claude Code transcript for a session launched from exactly " + p + ", so the accurate token is 'registered-no-sessions'"
						case "launched":
							cure = "a retained Claude Code transcript exists for a session launched from exactly " + p + " (it may predate the registration, so verify the hook has fired) and the accurate claim is likely 'hook yes'"
						default:
							cure = "the launch history could not be read (launch unknown), so verify by hand whether the accurate token is 'registered-no-sessions' or 'hook yes'"
						}
						r.finding("hook-unregistered-stale", "WARN", name, name+" — row claims 'unregistered' but the Stop hook IS registered at "+p+"/.claude/settings.json "+settingsNote+"; "+cure+"; refresh the row (propose-never-apply).")
						r.attention++
					}
					if isNosess && launch == "launched" {
						r.finding("hook-no-sessions-stale", "WARN", name, name+" — row claims 'registered-no-sessions' but a retained Claude Code transcript now exists for a session launched from exactly "+p+" (it may predate the registration, so verify the hook has fired); the accurate claim is likely 'hook yes'; refresh the row (propose-never-apply).")
						r.attention++
					}
				} else if isNosess {
					sc := script
					if sc == "" {
						sc = "n/a"
					}
					r.finding("hook-no-sessions-stale", "WARN", name, name+" — row claims 'registered-no-sessions' but the Stop hook is not registered with a loadable script at "+p+"/.claude/settings.json (wiring "+state+", script "+sc+"); refresh the row (propose-never-apply).")
					r.attention++
				}
			}
		}
	}

	if noClaim := firstMatch(toks, reHookNo); noClaim != "" {
		state, ok := r.hooks.StopWiringState(p)
		if !ok {
			r.skipped++
		} else if state == "wired" {
			if r.call(r.hooks.StopScriptState(p)) != "missing" {
				r.finding("hook-wired-contradiction", "WARN", name, name+" — row claims '"+noClaim+"' but the Stop hook IS wired at "+p+"/.claude/settings.json "+settingsNote+"; at minimum this needs 'hook file yes ...' — whether it becomes 'hook yes' depends on where sessions actually launch from (kit issue #1134); refresh the row (propose-never-apply).")
				r.attention++
			}
		}
	}
	return nlEmitted
}

func anyMatch(toks []string, re *regexp.Regexp) bool { return firstMatch(toks, re) != "" }

func anyEqual(toks []string, want string) bool {
	for _, t := range toks {
		if t == want {
			return true
		}
	}
	return false
}

// wiredExec is the WIRED-HOOK EXECUTE BIT check (kit issue #2141): every hook command wired in the target's
// settings.json must be runnable as a bare command.
func (r *registry) wiredExec(p, name string, nlEmitted bool) {
	if !isDirOS(p + "/.claude") {
		return
	}
	rows, ok := r.hooks.WiredExecReport(p)
	if !ok {
		r.skipped++
		return
	}
	for _, e := range rows {
		if e.Kind == "" {
			continue
		}
		switch {
		case e.Kind == "unverifiable":
			r.finding("wired-hook-unverifiable", "WARN", name, name+" — wired-hook-unverifiable: "+e.Path+" ("+e.Detail+"); whether this wired hook can run was NOT determined (checked path only: "+p+"/.claude/settings.json; propose-never-apply).")
		case e.Kind == "missing" && nlEmitted && e.Detail == "Stop" && strings.Contains(e.Path, "retro-gate"):
			continue // already reported as hook-registered-never-loaded for this target
		case e.Kind == "not-executable":
			r.finding("wired-hook-not-executable", "WARN", name, name+" — wired-hook-not-executable: "+e.Path+" is registered in "+p+"/.claude/settings.json as a bare command but has no execute bit, so Claude Code exits 126 and the hook never loads; chmod +x it or wire it as 'bash <path>' (propose-never-apply).")
		case e.Kind == "missing":
			r.finding("wired-hook-missing", "WARN", name, name+" — wired-hook-missing: "+e.Path+" is registered in "+p+"/.claude/settings.json but no such file exists, so the hook can never run; restore it or remove the registration (propose-never-apply).")
		default:
			continue
		}
		r.attention++
	}
}
