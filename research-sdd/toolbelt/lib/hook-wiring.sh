#!/usr/bin/env bash
# hook-wiring.sh — shared helper: is a target's Stop hook registered to run retro-gate?
#
# WHY: this predicate originally lived only as an inline awk pipeline inside sweep-retros.sh's
# WIRING-STATUS fleet pass. Kit issue #1108 needs the SAME check inside verify-registry.sh (to
# reconcile a TARGETS.md row's 'hook yes' claim against reality), and kit issue #1109 needs it
# inside research-sdd-status.sh (to self-report wiring for the one target being reported on). All
# three source this file instead of carrying their own copy, so all three MUST agree — a row or
# a self-report claiming 'wired' while sweep-retros disagrees defeats the whole point of §18
# supervision.
#
#   hook_stop_wiring_state_var <target-dir>
#     Sets the GLOBAL $HOOK_WIRING_STATE to exactly one of: wired | wired-off-root | unwired |
#     absent-settings | unreadable. Never forks a subshell for the four original states (no command
#     substitution inside this function itself EXCEPT the one git call the wired-off-root check below
#     needs — see that section),
#     so a caller iterating many targets (sweep-retros.sh's WIRING-STATUS fleet pass) can call
#     this directly instead of paying a `$(...)` fork per target. Always returns 0 — callers
#     branch on $HOOK_WIRING_STATE, never on exit status.
#
#     NARROWER than the TARGETS.md legend's 'hook' flag definition (kit issue #1108 round 2):
#     the legend recognises a hook as registered via THREE paths — project-level
#     <target>/.claude/settings.json, project-level <target>/.claude/settings.local.json, or
#     user-level ~/.claude/settings.json referencing the hook by absolute path. This function
#     checks ONLY the first — <target-dir>/.claude/settings.json — because that is the ORIGINAL
#     sweep-retros.sh WIRING-STATUS behavior this file extracted verbatim, and sweep-retros.sh's
#     real-fleet output must stay byte-identical (kit issue #1108's own acceptance gate). A
#     target correctly wired ONLY via settings.local.json or the user-level file will be
#     misreported unwired/absent-settings here — this is a pre-existing gap this extraction
#     carries forward unchanged, not a new one. Measured incidence on the real fleet (kit issue
#     #1108 round 2): 0 of the 17 reachable targets; 5 of the 16 unreachable targets claim
#     'hook yes' and could not be checked either way. Widening this predicate to the legend's
#     full definition is a separate, scoped follow-up — not folded into this fix per the kit's
#     "a sampling-rule/calibration-constant change is its own work unit" doctrine.
#       - absent-settings : <target-dir>/.claude/settings.json does not exist
#       - unreadable      : it exists but cannot be read (permission error)
#       - wired           : it is readable and its top-level "Stop" hooks array registers a
#                            command containing "retro-gate" — scoped STRICTLY to the Stop event
#                            block. A "retro-gate" substring under SessionStart, under
#                            permissions.deny, or inside an unrelated comment/string field
#                            elsewhere in the file never counts.
#       - unwired         : it is readable but no such Stop-scoped entry is found
#       - wired-off-root  : kit issue #1135 — it IS Stop-scoped-wired (as above), but <target-dir>
#                            is NOT its own git root (`git -C <target-dir> rev-parse --show-toplevel`
#                            resolves to a DIFFERENT, higher directory). Claude Code loads project
#                            settings from the directory a session is LAUNCHED in; a real session for
#                            a nested target almost always launches from the git root (or above), so
#                            <target-dir>/.claude/settings.json never loads — the hook is
#                            syntactically wired but never fires in practice. This is the exact §7
#                            false-confidence shape: 'wired' alone would be a false PASS. Case that
#                            surfaced this: TARGETS.md row 13 (three.js), registered at
#                            `.../threejs-hvac-prototipos/research`, whose own git root is the
#                            PARENT `.../threejs-hvac-prototipos` — every real research session for
#                            that target launches from the git root, so the nested settings.json
#                            never loads. The downgrade applies ONLY to an otherwise-'wired' result:
#                            an unwired/absent-settings/unreadable target makes no active-firing
#                            claim in the first place, so there is nothing false to downgrade (no
#                            WARN class exists for e.g. a nested 'hook no' row). When
#                            `git -C <target-dir> rev-parse --show-toplevel` itself fails (the target
#                            is not inside any git repository at all — the ORIGINAL, pre-#1135
#                            behavior for every fixture that predates this check), there is no git
#                            root to compare against, so the result is left 'wired' rather than
#                            guessed — this is what keeps hook_stop_wiring_state_var's own byte-for-
#                            byte contract with sweep-retros.sh's fleet output unchanged for every
#                            target except the one (of 17 reachable, kit issue #1135) that is
#                            actually nested off its git root.
#     This mirrors the kit's §7 anti-silent-zero doctrine: absent-settings, unreadable, unwired, and
#     wired-off-root are all distinct non-fully-wired states, never collapsed into a single "not
#     wired" bucket that would hide which one actually happened. The `awk` call below still forks
#     its OWN subprocess (unavoidable — this is shell, not awk-native) but that is one fork per
#     target either way; what this function avoids for the four original states is the SECOND,
#     redundant fork a caller would otherwise pay via `$(hook_stop_wiring_state "$p")` to capture
#     the result. The wired-off-root check below pays ONE additional `git rev-parse` fork, but only
#     on the already-'wired' path — the minority case on the real fleet — never on every target.
#
#   hook_stop_wiring_state <target-dir>
#     Convenience wrapper: calls hook_stop_wiring_state_var, then prints $HOOK_WIRING_STATE to
#     stdout. For a caller that only needs the state ONCE (verify-registry.sh's per-row
#     reconciliation, research-sdd-status.sh's single self-report line), `$(hook_stop_wiring_state
#     "$dir")` is the simplest idiom and the one extra fork is immaterial. A caller iterating many
#     targets in a tight loop should call hook_stop_wiring_state_var directly instead.
#
# Idempotent: safe to source more than once.

if ! declare -F hook_stop_wiring_state_var >/dev/null 2>&1; then
  hook_stop_wiring_state_var() {
    local target="$1" settings
    settings="$target/.claude/settings.json"
    if [ ! -e "$settings" ]; then
      HOOK_WIRING_STATE="absent-settings"; return 0
    fi
    if [ ! -r "$settings" ]; then
      HOOK_WIRING_STATE="unreadable"; return 0
    fi
    if awk '
      BEGIN { in_stop=0; stop_depth=0; depth=0; found=0 }
      {
        n=length($0); i=1
        while (i<=n) {
          c=substr($0,i,1)
          if (c=="{" || c=="[") {
            depth++
          } else if (c=="}" || c=="]") {
            depth--
            if (in_stop && depth<=stop_depth) { in_stop=0 }
          } else if (!in_stop && substr($0,i,6)=="\"Stop\"") {
            j=i+6
            while (j<=n && (substr($0,j,1)==" " || substr($0,j,1)=="\t")) j++
            if (j<=n && substr($0,j,1)==":") { in_stop=1; stop_depth=depth }
            i=j
          } else if (in_stop && substr($0,i,10)=="retro-gate") {
            found=1
          }
          i++
        }
      }
      END { exit !found }
    ' "$settings" 2>/dev/null; then
      HOOK_WIRING_STATE="wired"
    else
      HOOK_WIRING_STATE="unwired"
    fi
    # SESSION-ROOT CHECK (kit issue #1135): only ever runs on an already-'wired' result — see this
    # file's header for the full rationale. `git -C "$target" rev-parse --show-toplevel` failing
    # (target is not inside any git repository) leaves the result 'wired': there is no git root to
    # compare against, so nothing is guessed. WIRED-OFF-ROOT-CHECK (mutation-teeth anchor).
    if [ "$HOOK_WIRING_STATE" = "wired" ]; then
      local _hw_top _hw_real
      _hw_top="$(git -C "$target" rev-parse --show-toplevel 2>/dev/null)"
      if [ -n "$_hw_top" ]; then
        _hw_real="$(cd -P "$target" 2>/dev/null && pwd -P)"
        if [ -n "$_hw_real" ] && [ "$_hw_top" != "$_hw_real" ]; then
          HOOK_WIRING_STATE="wired-off-root"
        fi
      fi
    fi
    return 0
  }
fi

if ! declare -F hook_stop_wiring_state >/dev/null 2>&1; then
  hook_stop_wiring_state() {
    hook_stop_wiring_state_var "$1"
    printf '%s' "$HOOK_WIRING_STATE"
    return 0
  }
fi
