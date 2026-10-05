#!/usr/bin/env bash
# verify-registry-json.test.sh — opt-in --json envelope of verify-registry.sh (kit issue #1711 slice 2,
# json-envelope.v1.md). Pins: (1) the DEFAULT report stays byte-identical (golden recorded from the
# pre-change script); (2) the envelope carries the CLAUDE.md §7 state enum, the documented counts and
# item kinds, and agrees with the human Summary line; (3) a missing / too-old jq is a typed degraded
# result (rc 3), a failing jq is rc 1 with empty stdout, and a large accumulator reaches jq without argv.
#
# Env: VRJ_SUT=<path>        run against another copy of the script (used to execute RED against the
#                            pre-change SUT); default is ../verify-registry.sh.
#      VRJ_REGEN_GOLDEN=1    rewrite the golden from the SUT under test — regenerate only from a build
#                            whose default output is known good (it is not a frozen oracle then).
#
# Usage: verify-registry-json.test.sh [--prove-teeth]
# Exit: 0 = every assertion held · 1 = a regression · 2 = harness error.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="${VRJ_SUT:-$HERE/../verify-registry.sh}"
[ -f "$SUT" ] || { echo "FATAL: script under test not found: $SUT" >&2; exit 2; }
BASH_BIN="$(type -P bash)"; [ -n "$BASH_BIN" ] || { echo "FATAL: bash not on PATH" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required for the --json cases" >&2; exit 2; }
for _l in retro-status target-paths block-files corpus-markers hook-wiring; do
  [ -f "$HERE/../lib/$_l.sh" ] || { echo "FATAL: helper not found: $HERE/../lib/$_l.sh" >&2; exit 2; }
done
GOLD="$HERE/fixtures/verify-registry/json-envelope/default-output.golden"

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
# HERMETICITY: keep lib/hook-wiring.sh's git-root walk-up inside the sandbox (see verify-registry.test.sh).
RSDD_HOOK_WIRING_CEILING="$(dirname "$ROOT")"; export RSDD_HOOK_WIRING_CEILING
export RESEARCH_HOME="$ROOT/home"   # the INFO absent line prints it; keep the golden machine-independent
unset RSDD_REGISTRY_TOL RSDD_ROW_MAXLEN _json_items
pass=0; fail=0
ok() { printf '  PASS  %-58s %s\n' "$1" "${2:-}"; pass=$((pass+1)); }
no() { printf '  FAIL  %-58s %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

# mkkit <name> : a runnable COPY of the SUT and its helpers at <ROOT>/<name>/toolbelt/ (KIT=dirname/..).
mkkit() {
  local kit="$ROOT/$1" l
  mkdir -p "$kit/toolbelt/lib"
  cp "$SUT" "$kit/toolbelt/verify-registry.sh"
  for l in retro-status target-paths block-files corpus-markers hook-wiring; do cp "$HERE/../lib/$l.sh" "$kit/toolbelt/lib/$l.sh"; done
  printf '%s' "$kit"
}
# mkcorpus <dir> <n> <prefix> : RESEARCH-STATE.md plus <n> canonical block files.
mkcorpus() {
  local dir="$1" n="$2" prefix="$3" i=0
  mkdir -p "$dir"
  printf '# state\n\n<!-- research-state.v1 -->\ncovered_blocks: %d\n<!-- /research-state.v1 -->\n' "$n" > "$dir/RESEARCH-STATE.md"
  while [ "$i" -lt "$n" ]; do i=$((i+1)); printf '# Block %d\n' "$i" > "$dir/${prefix}-block${i}.md"; done
}
# write_targets <kit> <path::claim>... : minimal TARGETS.md with the kit self-registration row 0.
write_targets() {
  local kit="$1"; shift
  { printf '# targets\n\n| # | name | maturity | path |\n|---|---|---|---|\n'
    printf '| 0 | kit | active (0 md / nc / git yes) | `%s` |\n' "$kit"
    local i=0 spec p claim
    for spec in "$@"; do
      i=$((i+1)); p="${spec%%::*}"; claim="${spec#*::}"
      printf '| %d | t%d | mature (%s / git yes) | `%s` |\n' "$i" "$i" "$claim" "$p"
    done
  } > "$kit/TARGETS.md"
}

# rich_kit <name> : one kit exercising many finding kinds. Targets live OUTSIDE the kit dir.
#   tA drift (40 vs 5) + retro drift (2 vs 0) + nonconforming field + INFO no-retros;
#   tB no RESEARCH-STATE (unresolvable + no corpus marker); tC absent; tD 'hook yes' unwired;
#   one truncated '...' path (skipped); one oversized TARGETS row.
rich_kit() {
  local kit ext; kit="$(mkkit "$1")"; ext="$ROOT/$1-ext"
  mkcorpus "$ext/tA" 5 a; mkdir -p "$ext/tB"; mkcorpus "$ext/tD" 3 d
  write_targets "$kit" "$ext/tA::40 md / 2 retros / bogus thing" "$ext/tB::3 md" "$ext/tC-gone::4 md" \
    "$ext/tD::3 md / hook yes" "$ext/trunc...ated::1 md"
  printf '| 9 | long | %s |\n' "$(printf 'x%.0s' $(seq 1 260))" >> "$kit/TARGETS.md"
  printf '%s' "$kit"
}
# clean_kit <name> : a registry that reconciles with no finding at all.
clean_kit() {
  local kit ext; kit="$(mkkit "$1")"; ext="$ROOT/$1-ext"
  mkcorpus "$ext/tA" 5 a; mkdir -p "$ext/tA/retros"; printf '# r\n' > "$ext/tA/retros/r1.md"
  write_targets "$kit" "$ext/tA::5 md"
  printf '%s' "$kit"
}

run() { OUT="$("$BASH_BIN" "$1/toolbelt/verify-registry.sh" 2>&1)"; RC=$?; }
# jrun <kit> [PATH] : run with --json; JOUT = stdout only, JERR = stderr, RC.
jrun() {
  local _ef; _ef="$(mktemp "$ROOT/jerr.XXXXXX")"
  if [ -n "${2:-}" ]; then JOUT="$(PATH="$2" "$BASH_BIN" "$1/toolbelt/verify-registry.sh" --json 2>"$_ef")"; RC=$?
  else JOUT="$("$BASH_BIN" "$1/toolbelt/verify-registry.sh" --json 2>"$_ef")"; RC=$?; fi
  JERR="$(cat "$_ef")"; rm -f "$_ef"
}
jq_f() { printf '%s' "$JOUT" | jq -r "$1" 2>/dev/null; }
gold_norm() { sed -e "s#$ROOT/[^/]*#@ROOT@#g"; }

echo "== verify-registry-json.test.sh (SUT: $SUT) =="

# 1 — GOLDEN: the default (no flag) report of a rich fixture is byte-identical to the recorded pre-change one.
kit="$(rich_kit g-rich)"; run "$kit"
if [ -n "${VRJ_REGEN_GOLDEN:-}" ]; then mkdir -p "$(dirname "$GOLD")"; printf '%s\n' "$OUT" | gold_norm > "$GOLD"; fi
if [ -f "$GOLD" ] && [ "$(printf '%s\n' "$OUT" | gold_norm)" = "$(cat "$GOLD")" ] && [ "$RC" = 0 ]; then
  ok "golden: default (no flag) output byte-identical to the recorded pre-change report" "(rc $RC)"
else
  no "golden: default output drifted from $GOLD" "rc=$RC $(diff <(printf '%s\n' "$OUT" | gold_norm) "$GOLD" 2>&1 | head -5)"
fi
kit="$(clean_kit g-clean)"; run "$kit"
if [ "$RC" = 0 ] && grep -q '^Registry consistent with reality' <<<"$OUT" && ! grep -q 'schema' <<<"$OUT"; then
  ok "default: clean registry still prints the human verdict, no envelope" "()"
else no "default: clean registry" "rc=$RC $OUT"; fi

# 2 — ok envelope: shape, counts that agree with the human Summary line, every item kind with its fields.
kit="$(rich_kit j-rich)"; run "$kit"; HUMAN="$OUT"; jrun "$kit"
if [ "$RC" = 0 ] && [ "$(printf '%s' "$JOUT" | jq -s length 2>/dev/null)" = 1 ] \
   && [ "$(jq_f .schema)" = "research-sdd.verify-registry/v1" ] && [ "$(jq_f .state)" = ok ] && [ "$(jq_f .reason)" = null ]; then
  ok "JSON ok: exactly one envelope, schema constant, state ok, reason null, rc 0" "()"
else no "JSON ok: envelope shape" "rc=$RC err=[$JERR] out=[$(printf '%s' "$JOUT" | head -c 300)]"; fi
OUT="$HUMAN"
if [ "$(jq_f '[.counts.reconciled,.counts.targets_absent,.counts.count_drift,.counts.retro_drift,.counts.unresolved,.counts.oversized_rows,.counts.attention]|join(",")')" = "$(printf '%s\n' "$HUMAN" | sed -n 's/^Summary: reconciled \([0-9]*\) target(s) · \([0-9]*\) absent target(s) · \([0-9]*\) count drift(s) · \([0-9]*\) retro drift(s) · \([0-9]*\) unresolvable · \([0-9]*\) oversized row(s) · \([0-9]*\) attention\./\1,\2,\3,\4,\5,\6,\7/p')" ] \
   && [ "$(jq_f '[.counts.reconciled,.counts.targets_absent,.counts.count_drift,.counts.retro_drift,.counts.unresolved,.counts.oversized_rows,.counts.attention]|join(",")')" = "3,1,1,1,2,1,2" ]; then
  ok "JSON counts: every Summary-line counter matches the human report (pinned 3,1,1,1,2,1,2)" "()"
else no "JSON counts vs human Summary" "json=$(jq_f '.counts|tostring') human=$(grep '^Summary' <<<"$HUMAN")"; fi
if [ "$(jq_f '[.counts.targets,.counts.targets_skipped]|join(",")')" = "5,1" ]; then
  ok "JSON counts: targets (usable paths incl. absent) and targets_skipped (truncated path)" "()"
else no "JSON counts: targets/targets_skipped" "$(jq_f '.counts|tostring')"; fi
if [ "$(jq_f '[.items[].kind]|unique|join(",")')" = "absent-target,corpus-unresolvable,count-drift,hook-unwired,no-corpus-marker,no-retros-wired,nonconform-field,oversized-row,retro-drift" ]; then
  ok "JSON items: every finding kind of the fixture is present, each exactly named" "()"
else no "JSON items: kinds" "$(jq_f '[.items[].kind]|unique|join(",")')"; fi
if [ "$(jq_f '.items|map(select(.kind=="count-drift"))|.[0]|[.severity,.target,(.message|test("claims 40 md but the corpus has 5 real block"))]|join(",")')" = "WARN,tA,true" ] \
   && [ "$(jq_f '.items|map(select(.kind=="no-retros-wired"))|.[0]|[.severity,.target]|join(",")')" = "INFO,tA" ] \
   && [ "$(jq_f '.items|map(select(.kind=="absent-target"))|.[0]|[.severity,(.target|endswith("/tC-gone"))]|join(",")')" = "INFO,true" ] \
   && [ "$(jq_f '.items|map(select(.kind=="oversized-row"))|.[0].target')" = "long" ]; then
  ok "JSON items: severity, target and message carry values (WARN drift tA, INFO no-retros, INFO absent)" "()"
else no "JSON items: fields" "$(jq_f '.items|tostring' | head -c 600)"; fi
if ! grep -q 'Summary:\|Registry consistent' <<<"$JOUT"; then ok "JSON ok: human report text is absent from stdout" "()"; else no "JSON ok: human text leaked into stdout" "$JOUT"; fi
if [ "$(printf '%s' "$JOUT" | jq -r '.items|map(select(.kind != "absent-target"))|length')" = "$(printf '%s\n' "$HUMAN" | grep -cE '^(WARN|INFO)  ')" ]; then
  ok "JSON items: one item per human WARN/INFO finding line (absent targets are counted apart)" "()"
else no "JSON items: parity with human findings" "json=$(jq_f '.items|length') human=$(grep -cE '^(WARN|INFO)  ' <<<"$HUMAN")"; fi

# 3 — no-match: examined, nothing to report.
kit="$(clean_kit j-clean)"; jrun "$kit"
if [ "$RC" = 0 ] && [ "$(jq_f '[.state,(.items|length),.counts.reconciled,.counts.attention]|join(",")')" = "no-match,0,2,0" ] && [ "$(jq_f .reason)" != null ]; then
  ok "JSON no-match: reconciled targets, no findings → no-match with a reason, empty items" "()"
else no "JSON no-match" "rc=$RC $JOUT"; fi

# 4 — absent-input: every registered directory missing. (TARGETS.md hand-written: write_targets always adds the kit row.)
kit="$(mkkit j-absent)"
printf '# t\n\n| # | name | maturity | path |\n|---|---|---|---|\n| 1 | a | mature (5 md) | `%s` |\n| 2 | b | mature (5 md) | `%s` |\n' "$ROOT/gone1" "$ROOT/gone2" > "$kit/TARGETS.md"
jrun "$kit"
if [ "$RC" = 0 ] && [ "$(jq_f '[.state,(.items|length),.counts.targets,.counts.targets_absent]|join(",")')" = "absent-input,0,2,2" ] && [ "$(jq_f .reason)" != null ]; then
  ok "JSON absent-input: every directory missing → absent-input, rc 0, empty items" "()"
else no "JSON absent-input" "rc=$RC $JOUT"; fi
run "$kit"
if [ "$RC" = 1 ]; then ok "default: the same all-absent registry still exits 1 (unchanged)" "()"; else no "default all-absent exit" "rc=$RC $OUT"; fi

# 5 — partial absence beside real findings is ok, with the absence visible in counts.
kit="$(mkkit j-partial)"; ext="$ROOT/j-partial-ext"; mkcorpus "$ext/tA" 5 a
write_targets "$kit" "$ext/tA::5 md" "$ext/gone::4 md"; jrun "$kit"
if [ "$(jq_f '[.state,.counts.targets_absent,(.items|map(.kind)|sort|join("+"))]|join(",")')" = "ok,1,absent-target+no-retros-wired" ]; then
  ok "JSON precedence: one absent target beside findings → ok, absence in counts and as an item" "()"
else no "JSON precedence: partial absence" "$JOUT"; fi

# 6 — operational failures keep rc 1 with empty stdout (contract table).
kit="$(mkkit j-nomd)"; jrun "$kit"
if [ "$RC" = 1 ] && [ -z "$JOUT" ]; then ok "JSON op-failure: TARGETS.md absent → rc 1, empty stdout" "()"; else no "JSON op-failure: no TARGETS.md" "rc=$RC out=[$JOUT]"; fi
kit="$(mkkit j-nopaths)"; printf '# t\n\n| # | name |\n|---|---|\n| 1 | nothing |\n' > "$kit/TARGETS.md"; jrun "$kit"; _jrc=$RC; _jo="$JOUT"; run "$kit"
if [ "$_jrc" = 1 ] && [ -z "$_jo" ] && [ "$RC" = 0 ]; then
  ok "JSON op-failure: no usable target path → rc 1, empty stdout (default mode keeps rc 0)" "()"
else no "JSON op-failure: no usable path" "json rc=$_jrc out=[$_jo] default rc=$RC"; fi

# 7 — degraded: jq absent, jq without --rawfile, jq failing.
kit="$(rich_kit j-degr)"; _np="$ROOT/j-nopath"; mkdir -p "$_np"; jrun "$kit" "$_np"
if [ "$RC" = 3 ] && grep -q '^DEGRADED: jq not found' <<<"$JERR" \
   && [ "$(jq_f '[.schema,.state]|join(",")')" = "research-sdd.verify-registry/v1,degraded" ] && [ "$(jq_f .reason)" != null ]; then
  ok "JSON degraded: jq absent → typed degraded envelope, DEGRADED on stderr, rc 3" "()"
else no "JSON degraded" "rc=$RC err=[$JERR] out=[$JOUT]"; fi
_oj="$ROOT/j-oldjq-bin"; mkdir -p "$_oj"; _realjq="$(command -v jq)"
printf '#!/bin/sh\nfor a in "$@"; do [ "$a" = "--rawfile" ] && { echo "jq: Unknown option --rawfile" >&2; exit 2; }; done\nexec "%s" "$@"\n' "$_realjq" > "$_oj/jq"; chmod +x "$_oj/jq"
jrun "$kit" "$_oj:$PATH"
if [ "$RC" = 3 ] && grep -q '^DEGRADED: jq lacks --rawfile' <<<"$JERR" \
   && [ "$(jq_f '[.schema,.state]|join(",")')" = "research-sdd.verify-registry/v1,degraded" ] && [ "$(printf '%s' "$JOUT" | jq -s length 2>/dev/null)" = 1 ]; then
  ok "JSON old-jq: jq without --rawfile → typed degraded envelope, DEGRADED on stderr, rc 3" "()"
else no "JSON old-jq" "rc=$RC err=[$JERR] out=[$JOUT]"; fi
_stub="$ROOT/j-stub"; mkdir -p "$_stub"
printf '#!/bin/sh\ncase "$*" in *_vr_probe*) exit 0;; esac\nexit 1\n' > "$_stub/jq"; chmod +x "$_stub/jq"
jrun "$kit" "$_stub:$PATH"
if [ "$RC" = 1 ] && [ -z "$JOUT" ] && grep -q 'envelope build failed' <<<"$JERR"; then
  ok "JSON jq-failure: envelope build failure → rc 1, stderr message, empty stdout" "()"
else no "JSON jq-failure" "rc=$RC out=[$JOUT] err=[$JERR]"; fi

# 8 — an inherited accumulator must not inject items; a >128 KiB accumulator must reach jq without argv.
kit="$(clean_kit j-env)"; export _json_items="kind=fake"$'\037'"severity=WARN"$'\037'"target=x"$'\037'"message=fabricated"$'\n'; jrun "$kit"; unset _json_items
if [ "$(jq_f '[.state,(.items|length)]|join(",")')" = "no-match,0" ]; then
  ok "JSON env: inherited _json_items does not inject items (state stays no-match)" "()"
else no "JSON env: inherited accumulator leaked" "$JOUT"; fi
kit="$(mkkit j-big)"; ext="$ROOT/j-big-ext"; mkcorpus "$ext/tA" 5 a; mkdir -p "$ext/tA/retros"
write_targets "$kit" "$ext/tA::5 md / $(printf 'q%.0s' $(seq 1 200000))"; jrun "$kit"
if [ "$RC" = 0 ] && [ "$(jq_f '[.state,(.items|map(select(.kind=="nonconform-field"))|length)]|join(",")')" = "ok,1" ] \
   && [ "$(jq_f '.items|map(select(.kind=="nonconform-field"))|.[0].message|length')" -gt 190000 ]; then
  ok "JSON argv: a ~200 KB finding (> MAX_ARG_STRLEN) → full envelope, no E2BIG" "()"
else no "JSON argv: large accumulator" "rc=$RC err=[$(printf '%s' "$JERR" | head -c 200)] out=[$(printf '%s' "$JOUT" | head -c 100)]"; fi

# --- TEETH (--prove-teeth): each mutant of the SUT must break the case that pins it.
if [ "${1:-}" = "--prove-teeth" ]; then
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  declare -F mutant_chain >/dev/null || { echo "FATAL: lib/mutant.sh did not define mutant_chain" >&2; exit 2; }
  # jteeth <label> <case-fn> <sed-expr>... : build a mutant kit; the case-fn must report a break (rc != 0).
  jteeth() {
    local label="$1" fn="$2" mk mut; shift 2
    mk="$(mkkit "jt-$label")"; mut="$ROOT/jt-$label.sh"
    mutant_chain "teeth JSON-$label" "$SUT" "$mut" "$@" || { fail=$((fail+1)); return; }
    cp "$mut" "$mk/toolbelt/verify-registry.sh"
    if "$fn" "$mk"; then no "teeth JSON-$label: mutant survived — case is THEATER" ""; else ok "teeth JSON-$label: mutant breaks the case (has teeth)" "()"; fi
  }
  # Each case-fn rebuilds its own scenario around the mutated script (rc 0 = the case still holds).
  with_sut() { cp "$1/toolbelt/verify-registry.sh" "$2/toolbelt/verify-registry.sh"; }
  jt_rich()   { local k; k="$(rich_kit "$(basename "$1")-r")"; with_sut "$1" "$k"; jrun "$k"; [ "$RC" = 0 ] && [ "$(printf '%s' "$JOUT" | jq -s length 2>/dev/null)" = 1 ] && [ "$(jq_f .state)" = ok ]; }
  jt_items()  { local k; k="$(rich_kit "$(basename "$1")-i")"; with_sut "$1" "$k"; jrun "$k"; [ "$(jq_f '.items|map(select(.kind=="count-drift"))|length')" = 1 ]; }
  jt_counts() { local k; k="$(rich_kit "$(basename "$1")-c")"; with_sut "$1" "$k"; jrun "$k"; [ "$(jq_f '[.counts.reconciled,.counts.count_drift,.counts.targets_skipped]|join(",")')" = "2,1,1" ]; }
  jt_nomatch(){ local k; k="$(clean_kit "$(basename "$1")-n")"; with_sut "$1" "$k"; jrun "$k"; [ "$(jq_f .state)" = no-match ]; }
  jt_absent() { local k; k="$(mkkit "$(basename "$1")-a")"; printf '# t\n\n| # | n | m | p |\n|---|---|---|---|\n| 1 | a | mature (5 md) | `%s` |\n' "$ROOT/gone" > "$k/TARGETS.md"; with_sut "$1" "$k"; jrun "$k"; [ "$RC" = 0 ] && [ "$(jq_f '[.state,(.items|length)]|join(",")')" = "absent-input,0" ]; }
  jt_degr()   { jrun "$1" "$ROOT/j-nopath"; [ "$RC" = 3 ] && [ "$(jq_f .state)" = degraded ]; }
  jt_oldjq()  { jrun "$1" "$ROOT/j-oldjq-bin:$PATH"; [ "$RC" = 3 ] && [ "$(jq_f .state)" = degraded ]; }
  jt_exit1()  { local k; k="$(rich_kit "$(basename "$1")-x")"; with_sut "$1" "$k"; jrun "$k" "$ROOT/j-stub:$PATH"; [ "$RC" = 1 ] && [ -z "$JOUT" ]; }
  jt_big()    { local k; k="$(mkkit "$(basename "$1")-b")"; local e; e="$ROOT/$(basename "$1")-b-ext"; mkcorpus "$e/tA" 5 a; write_targets "$k" "$e/tA::5 md / $(printf 'q%.0s' $(seq 1 200000))"; with_sut "$1" "$k"; jrun "$k"; [ "$RC" = 0 ] && [ "$(jq_f .state)" = ok ]; }
  jt_envinit(){ local k; k="$(clean_kit "$(basename "$1")-e")"; with_sut "$1" "$k"; _json_items="kind=fake"$'\037'"severity=WARN"$'\037'"target=x"$'\037'"message=f"$'\n' jrun "$k"; [ "$(jq_f .state)" = no-match ]; }
  jt_nopaths(){ local k; k="$(mkkit "$(basename "$1")-p")"; printf '# t\n\n| # | name |\n|---|---|\n| 1 | nothing |\n' > "$k/TARGETS.md"; with_sut "$1" "$k"; jrun "$k"; [ "$RC" = 1 ] && [ -z "$JOUT" ]; }
  jt_human()  { local k; k="$(rich_kit "$(basename "$1")-h")"; with_sut "$1" "$k"; run "$k"; [ "$(printf '%s\n' "$OUT" | gold_norm)" = "$(cat "$GOLD")" ]; }
  jt_absitem(){ local k; k="$(rich_kit "$(basename "$1")-ai")"; with_sut "$1" "$k"; jrun "$k"; [ "$(jq_f '.items|map(select(.kind=="absent-target"))|length')" = 1 ]; }
  jteeth mute      jt_rich    's/^  exec 3>&1 >\/dev\/null$/  exec 3>\&1/'
  jteeth probe     jt_degr    's/command -v jq >\/dev\/null/command -v true >\/dev\/null/' 's/if ! jq -n --rawfile _vr_probe \/dev\/null 1 >\/dev\/null 2>&1; then/if false; then/'
  jteeth oldjq     jt_oldjq   's/if ! jq -n --rawfile _vr_probe \/dev\/null 1/if ! jq -n 1/'
  jteeth record    jt_items   's/^  \[ "\$VR_JSON" = 1 \] || return 0$/  return 0/'
  jteeth counts    jt_counts  's/reconciled: \$checked/reconciled: 0/' 's/targets_skipped: \$tskipped/targets_skipped: 0/'
  jteeth nomatch   jt_nomatch 's/else "no-match" end),/else "ok" end),/'
  jteeth absentst  jt_absent  's/if \$allabsent then "absent-input"/if false then "absent-input"/'
  jteeth absentempty jt_absent 's/| \. + {items: (if \.state == "absent-input" then \[\] else \$it end)}/| . + {items: $it}/'
  jteeth argv      jt_big     's/--rawfile items <(printf .%s. "\$_json_items")/--arg items "$_json_items"/'
  jteeth exit1     jt_exit1   's/--json envelope build failed" >&2; exit 1; }/--json envelope build failed" >\&2; exit 2; }/'
  jteeth envinit   jt_envinit 's/^_json_items=""   # --json accumulator.*$/: # no init/'
  jteeth nopaths   jt_nopaths 's/^  \[ "\$VR_JSON" = 1 \] && exit 1  # --json: a machine caller.*$/  : # mutated/'
  jteeth absitem   jt_absitem '/"absent-target"/s/_json_items="\${_json_items}\$(printf/: "\${_json_items}$(printf/'
  jteeth finding   jt_human   's/^  printf .%s\\n. "\$2  \$4"$/  printf "%s\\n" "\$2 \$4"/'
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
