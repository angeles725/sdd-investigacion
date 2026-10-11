#!/usr/bin/env bash
# verify-registry-wired-exec.test.sh — kit issue #2141: verify-registry.sh reports a hook wired in a
# target's .claude/settings.json whose script lacks the execute bit (Claude Code runs a bare command,
# so a mode-644 script exits 126 and never loads) or whose script is absent.
#
# Kinds pinned (json-envelope.v1.md): wired-hook-not-executable, wired-hook-missing. WARN-only,
# read-only toward targets. A command run through an interpreter (`bash <path>`) does not need +x.
# The fixture is tests/fixtures/wired-hook-exec/ (settings.json + hooks/), copied into a sandbox
# target as .claude/ so the suite never writes into the kit tree.
#
# Usage: verify-registry-wired-exec.test.sh [--prove-teeth]
# Exit: 0 = every assertion held · 1 = a regression · 2 = harness error.

set -uo pipefail
# HERMETICITY (kit issue #1157): never read the developer's real ~/.claude/projects launch history.
export RSDD_CLAUDE_PROJECTS_DIR="/nonexistent/rsdd-claude-history"
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../verify-registry.sh"
LIB="$HERE/../lib/hook-wiring.sh"
FIX="$HERE/fixtures/wired-hook-exec"
BASH_BIN="$(type -P bash)"; [ -n "$BASH_BIN" ] || { echo "FATAL: bash not on PATH" >&2; exit 2; }
[ -f "$SUT" ] && [ -f "$LIB" ] && [ -f "$FIX/settings.json" ] || { echo "FATAL: SUT, lib or fixture missing" >&2; exit 2; }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
RSDD_HOOK_WIRING_CEILING="$(dirname "$ROOT")"; export RSDD_HOOK_WIRING_CEILING
export RESEARCH_HOME="$ROOT/home"
unset RSDD_REGISTRY_TOL RSDD_ROW_MAXLEN _json_items
pass=0; fail=0
ok() { printf '  PASS  %-60s %s\n' "$1" "${2:-}"; pass=$((pass+1)); }
no() { printf '  FAIL  %-60s %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

# mkkit <name> [<sut> [<lib>]] : a runnable COPY of the SUT and its helpers (KIT = dirname/..).
mkkit() {
  local kit="$ROOT/$1" l sut="${2:-$SUT}" lib="${3:-$LIB}"
  mkdir -p "$kit/toolbelt/lib"
  cp "$sut" "$kit/toolbelt/verify-registry.sh"
  for l in retro-status target-paths block-files state-files corpus-markers; do cp "$HERE/../lib/$l.sh" "$kit/toolbelt/lib/$l.sh"; done
  cp "$lib" "$kit/toolbelt/lib/hook-wiring.sh"
  printf '%s' "$kit"
}
# mktarget <dir> : a corpus-bearing target carrying the fixture as .claude/. The execute bit is set
# ONLY on plain-exec; every other hook stays mode 644 (git does not track 644-vs-600, but it does the
# 755 bit, so the fixture files are committed non-executable and the bit is applied here).
mktarget() {
  local t="$1"
  mkdir -p "$t"
  printf '# state\n\n<!-- research-state.v1 -->\ncovered_blocks: 1\n<!-- /research-state.v1 -->\n' > "$t/RESEARCH-STATE.md"
  printf '# Block 1\n' > "$t/a-block1.md"
  mkdir -p "$t/.claude"
  cp -R "$FIX/hooks" "$t/.claude/hooks"; cp "$FIX/settings.json" "$t/.claude/settings.json"
  chmod 644 "$t/.claude/hooks/"*
  chmod +x "$t/.claude/hooks/plain-exec"
}
write_targets() {
  local kit="$1" t="$2"
  { printf '# targets\n\n| # | name | maturity | path |\n|---|---|---|---|\n'
    printf '| 0 | kit | active (0 md / nc / git yes) | `%s` |\n' "$kit"
    printf '| 1 | t1 | mature (1 md / git yes) | `%s` |\n' "$t"
  } > "$kit/TARGETS.md"
}
run() { OUT="$("$BASH_BIN" "$1/toolbelt/verify-registry.sh" 2>&1)"; RC=$?; }

echo "== verify-registry-wired-exec.test.sh =="

# --- case builders (reused by the teeth) ---
case_all() {  # <kit> : every expected finding present, no false one; rc 0
  local kit="$1" t="$ROOT/tgt-$$-$RANDOM"
  mktarget "$t"; write_targets "$kit" "$t"; run "$kit"
  [ "$RC" = 0 ] || return 1
  grep -qF "wired-hook-not-executable: $t/.claude/hooks/plain-noexec" <<<"$OUT" || return 1
  grep -qF "wired-hook-not-executable: $t/.claude/hooks/quoted-noexec" <<<"$OUT" || return 1
  grep -qF "wired-hook-missing: $t/.claude/hooks/absent-hook" <<<"$OUT" || return 1
  grep -qE '^WARN  ' <<<"$(grep -F 'wired-hook-' <<<"$OUT")" || return 1
  ! grep -qF "bashwrapped-noexec" <<<"$OUT" || return 1   # interpreter-run: fine
  ! grep -qF "plain-exec" <<<"$OUT" || return 1            # +x: fine
  return 0
}
case_interp() { # <kit> : only the interpreter-run and +x hooks are wired -> no wired-hook finding
  local kit="$1" t="$ROOT/tgt-$$-$RANDOM"
  mktarget "$t"
  printf '%s\n' '{"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"bash $CLAUDE_PROJECT_DIR/.claude/hooks/bashwrapped-noexec"},{"type":"command","command":"sh .claude/hooks/bashwrapped-noexec"},{"type":"command","command":"/bin/bash $CLAUDE_PROJECT_DIR/.claude/hooks/bashwrapped-noexec"},{"type":"command","command":"$CLAUDE_PROJECT_DIR/.claude/hooks/plain-exec"}]}]}}' > "$t/.claude/settings.json"
  write_targets "$kit" "$t"; run "$kit"
  [ "$RC" = 0 ] && ! grep -qF 'wired-hook-' <<<"$OUT"
}
case_chmod_clears() { # <kit> : after chmod +x the not-executable finding is gone (the check reads the live mode)
  local kit="$1" t="$ROOT/tgt-$$-$RANDOM"
  mktarget "$t"; chmod +x "$t/.claude/hooks/plain-noexec" "$t/.claude/hooks/quoted-noexec"
  write_targets "$kit" "$t"; run "$kit"
  [ "$RC" = 0 ] && ! grep -qF 'wired-hook-not-executable' <<<"$OUT" && grep -qF "wired-hook-missing: $t/.claude/hooks/absent-hook" <<<"$OUT"
}
case_readonly() { # <kit> : the check never changes the target (tree listing + modes + mtimes identical)
  local kit="$1" t="$ROOT/tgt-$$-$RANDOM" b a
  mktarget "$t"; write_targets "$kit" "$t"
  b="$(find "$t" -printf '%p %m %T@\n' | sort)"
  run "$kit"
  a="$(find "$t" -printf '%p %m %T@\n' | sort)"
  [ "$b" = "$a" ] && grep -qF 'wired-hook-' <<<"$OUT"
}
case_json() { # <kit> : the --json envelope carries both kinds as WARN items
  local kit="$1" t="$ROOT/tgt-$$-$RANDOM" j
  command -v jq >/dev/null 2>&1 || return 0
  mktarget "$t"; write_targets "$kit" "$t"
  j="$("$BASH_BIN" "$kit/toolbelt/verify-registry.sh" --json 2>/dev/null)"
  [ "$(jq -r '[.items[] | select(.kind=="wired-hook-not-executable" and .severity=="WARN")] | length' <<<"$j")" = 2 ] \
    && [ "$(jq -r '[.items[] | select(.kind=="wired-hook-missing" and .severity=="WARN")] | length' <<<"$j")" = 1 ]
}

K="$(mkkit k1)"
case_all "$K"          && ok "1 not-executable (plain + quoted \$CLAUDE_PROJECT_DIR) and missing hooks are reported" || no "1 wired-hook findings" "[$OUT]"
case_interp "$K"       && ok "2 'bash <path>' / 'sh <path>' / +x wired hooks are NOT reported"                       || no "2 interpreter/+x hooks must be silent" "[$OUT]"
case_chmod_clears "$K" && ok "3 chmod +x clears the finding (live mode read); missing stays"                          || no "3 chmod clears" "[$OUT]"
case_readonly "$K"     && ok "4 read-only toward the target (modes/mtimes/tree unchanged)"                            || no "4 read-only" "[$OUT]"
case_json "$K"         && ok "5 --json envelope carries both kinds as WARN items"                                     || no "5 json items"

# --- TEETH ---
if [ "${1:-}" = "--prove-teeth" ]; then
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  mutant_bootstrap mutant_chain mutant_or_count mutant_chain_or_count || exit 2
  # wteeth <label> <case-fn> <lib|sut> <sed-expr>... : the case passes on the real SUT; on the mutant it must fail.
  wteeth() {
    local label="$1" fn="$2" which="$3" mut="$ROOT/mut-$RANDOM" mk; shift 3
    "$fn" "$K" || { no "teeth $label: case FAILS on the unmutated SUT — tooth is vacuous"; return; }
    if [ "$which" = lib ]; then
      mutant_chain_or_count fail "teeth $label" "$LIB" "$mut" "$@" || return 0
      mk="$(mkkit "m-$RANDOM" "$SUT" "$mut")"
    else
      mutant_chain_or_count fail "teeth $label" "$SUT" "$mut" "$@" || return 0
      mk="$(mkkit "m-$RANDOM" "$mut" "$LIB")"
    fi
    if "$fn" "$mk"; then no "teeth $label: mutant survived — case is THEATER"; else ok "teeth $label: mutant breaks the case (has teeth)"; fi
  }
  wteeth NOEXEC-TEST-DROPPED case_all lib 's/if \[ ! -x "\$w" \]; then/if false; then/'
  wteeth MISSING-NOT-REPORTED case_all lib 's/printf .missing[^"]*"\$w"/:/'
  wteeth PROJECT-DIR-UNEXPANDED case_all lib 's/\${CLAUDE_PROJECT_DIR}/\${NOT_THE_VAR}/g'
  wteeth CALLSITE-REMOVED case_all sut 's/hook_wired_exec_report "\$p"/true/'
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
