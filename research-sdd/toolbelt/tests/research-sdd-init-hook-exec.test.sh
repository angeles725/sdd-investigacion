#!/usr/bin/env bash
# research-sdd-init-hook-exec.test.sh — kit issue #2141: research-sdd-init.sh must never wire a hook
# script that Claude Code cannot run as a bare command. Every hook it writes (SessionStart
# research-protocol.sh, Stop retro-gate-stop.sh, PreToolUse pkill-guard.sh) gets the execute bit on the
# scaffold path AND on the --wire repair path, independent of the mode the kit template happens to carry
# (a checkout that lost the +x bits — zip export, a Windows clone, a non-POSIX mount — must not produce
# mode-644 hooks that exit 126). A hook that already EXISTS without +x is never rewritten (hand-adapted
# hooks are not modified, kit issue #1496) but is REPORTED with a typed WARN naming the file.
#
# Every case runs a private COPY of the kit (toolbelt + templates) whose templates are forced to mode 644,
# so the SUT's own chmod is the only thing that can produce +x.
#
# Usage: research-sdd-init-hook-exec.test.sh [--prove-teeth]      Exit: 0 held · 1 regression · 2 harness error.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../research-sdd-init.sh"
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required for --wire cases" >&2; exit 2; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok() { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

# mkkit <name> [<sut>] : a private kit copy (toolbelt/ + templates/) with every template at mode 644.
mkkit() {
  local k="$TMP/$1" sut="${2:-$SUT}"
  mkdir -p "$k/toolbelt"
  cp -R "$HERE/../lib" "$k/toolbelt/lib"
  cp "$HERE/../return-token-gate.sh" "$HERE/../verify-skill-drift-hook.sh" "$k/toolbelt/" 2>/dev/null || :
  cp "$sut" "$k/toolbelt/research-sdd-init.sh"
  cp -R "$HERE/../../templates" "$k/templates"
  chmod 644 "$k/templates/"*
  printf '%s' "$k"
}
H_SS=".claude/hooks/research-protocol.sh"; H_STOP=".claude/hooks/retro-gate-stop.sh"; H_PK=".claude/hooks/pkill-guard.sh"

case_scaffold() {   # <kit> : fresh scaffold --wire -> all three hooks executable
  local d="$TMP/sc-$RANDOM"; mkdir -p "$d"
  bash "$1/toolbelt/research-sdd-init.sh" "$d" --corpus flat --prefix t --subject "hook exec" --scaffold --wire >"$d.out" 2>&1 || return 1
  [ -x "$d/$H_SS" ] && [ -x "$d/$H_STOP" ] && [ -x "$d/$H_PK" ]
}
case_wire_create() {  # <kit> : --wire on a corpus with NO hooks creates all three executable
  local d="$TMP/wc-$RANDOM"; mkdir -p "$d"; : > "$d/INDEX.md"
  bash "$1/toolbelt/research-sdd-init.sh" "$d" --wire --subject "hook exec" >"$d.out" 2>&1 || return 1
  [ -x "$d/$H_SS" ] && [ -x "$d/$H_STOP" ] && [ -x "$d/$H_PK" ]
}
case_rewire_warns() {  # <kit> : --wire over EXISTING non-executable hooks: each is named in a WARN, none rewritten
  local d="$TMP/rw-$RANDOM" h before
  mkdir -p "$d/.claude/hooks"; : > "$d/INDEX.md"
  for h in "$H_SS" "$H_STOP" "$H_PK"; do printf '#!/usr/bin/env bash\n# hand-adapted\nexit 0\n' > "$d/$h"; chmod 644 "$d/$h"; done
  before="$(cat "$d/$H_SS" "$d/$H_STOP" "$d/$H_PK" | cksum)"
  bash "$1/toolbelt/research-sdd-init.sh" "$d" --wire >"$d.out" 2>&1
  for h in "$H_SS" "$H_STOP" "$H_PK"; do
    grep -qF "WARN: $d/$h is not executable" "$d.out" || return 1
    [ ! -x "$d/$h" ] || return 1
  done
  [ "$before" = "$(cat "$d/$H_SS" "$d/$H_STOP" "$d/$H_PK" | cksum)" ]
}
case_scaffold_keep_warns() {  # <kit> : scaffold over an existing non-executable SessionStart hook (kept) is reported
  local d="$TMP/sk-$RANDOM"; mkdir -p "$d/.claude/hooks"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$d/$H_SS"; chmod 644 "$d/$H_SS"
  bash "$1/toolbelt/research-sdd-init.sh" "$d" --corpus flat --scaffold --wire >"$d.out" 2>&1
  grep -qF "WARN: $d/$H_SS is not executable" "$d.out" && [ ! -x "$d/$H_SS" ]
}
case_kit_script_warns() {  # <kit> : a kit script wired as a bare command (gate, drift hook) without +x is reported
  local d="$TMP/ks-$RANDOM"; mkdir -p "$d"
  chmod 644 "$1/toolbelt/return-token-gate.sh" "$1/toolbelt/verify-skill-drift-hook.sh"
  bash "$1/toolbelt/research-sdd-init.sh" "$d" --corpus flat --scaffold --wire >"$d.out" 2>&1
  chmod 755 "$1/toolbelt/return-token-gate.sh" "$1/toolbelt/verify-skill-drift-hook.sh"
  grep -qF "WARN: kit script $1/toolbelt/return-token-gate.sh is not executable" "$d.out" \
    && grep -qF "WARN: kit script $1/toolbelt/verify-skill-drift-hook.sh is not executable" "$d.out"
}
case_exec_kept_silent() {  # <kit> : EXECUTABLE existing hooks (and executable kit scripts) draw no not-executable WARN
  local d="$TMP/es-$RANDOM" h
  mkdir -p "$d/.claude/hooks"; : > "$d/INDEX.md"
  for h in "$H_SS" "$H_STOP" "$H_PK"; do printf '#!/usr/bin/env bash\nexit 0\n' > "$d/$h"; chmod 755 "$d/$h"; done
  chmod 755 "$1/toolbelt/return-token-gate.sh" "$1/toolbelt/verify-skill-drift-hook.sh"
  bash "$1/toolbelt/research-sdd-init.sh" "$d" --wire >"$d.out" 2>&1
  grep -qF 'kept: ' "$d.out" && ! grep -qF 'is not executable' "$d.out"
}

echo "== research-sdd-init-hook-exec.test.sh =="
K="$(mkkit k1)"
case_scaffold "$K"          && ok "1 scaffold --wire makes all three hooks executable (templates at 644)" || no "1 scaffold hooks not all +x"
case_wire_create "$K"       && ok "2 --wire repair creates all three hooks executable (templates at 644)" || no "2 wire-created hooks not all +x"
case_rewire_warns "$K"      && ok "3 --wire over existing non-executable hooks WARNs on each, rewrites none" || no "3 re-wire must report non-executable hooks"
case_scaffold_keep_warns "$K" && ok "4 kept non-executable SessionStart hook is reported on the scaffold path" || no "4 kept hook must be reported"
case_kit_script_warns "$K"  && ok "5 non-executable kit scripts wired as bare commands (gate, drift hook) are reported" || no "5 kit script noexec must be reported"
case_exec_kept_silent "$K" && ok "6 executable kept hooks and kit scripts draw no not-executable WARN" || no "6 executable hooks must not warn"

if [ "${1:-}" = "--prove-teeth" ]; then
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  mutant_bootstrap mutant_chain mutant_or_count mutant_chain_or_count || exit 2
  # steeth <label> <case-fn> <sed-expr>... : the case passes on the real SUT; on the mutant it must fail.
  steeth() {
    local label="$1" fn="$2" mut="$TMP/mut-$RANDOM" mk; shift 2
    "$fn" "$K" || { no "teeth $label: case FAILS on the unmutated SUT — tooth is vacuous"; return; }
    mutant_chain_or_count fail "teeth $label" "$SUT" "$mut" "$@" || return 0
    mk="$(mkkit "m-$RANDOM" "$mut")"
    if "$fn" "$mk"; then no "teeth $label: mutant survived — case is THEATER"; else ok "teeth $label: mutant breaks the case (has teeth)"; fi
  }
  steeth SCAFFOLD-SS-CHMOD case_scaffold '/# WIRED-SS-CHMOD-SCAFFOLD/d'
  steeth WIRE-SS-CHMOD case_wire_create '/# WIRED-SS-CHMOD-WIRE/d'
  steeth WIRE-STOP-CHMOD case_wire_create 's/^      chmod +x "\$_wo_stop"$/      :/'
  steeth KEPT-WARN-DROPPED case_rewire_warns 's/is not executable — the hook cannot run/is fine — the hook cannot run/'
  steeth WARN-ALWAYS case_exec_kept_silent 's/\[ -x "\$1" \] ||/false ||/'
  steeth KIT-GATE-WARN-DROPPED case_kit_script_warns 's/^  _rsdd_warn_kit_script_noexec "\$_RSDD_GATE_PATH"$/  :/'
  steeth KIT-DRIFT-WARN-DROPPED case_kit_script_warns 's/^  _rsdd_warn_kit_script_noexec "\$_RSDD_DRIFT_PATH"$/  :/'
  steeth SCAFFOLD-KEPT-WARN-DROPPED case_scaffold_keep_warns 's/is not executable — the hook cannot run/is fine — the hook cannot run/'
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
