#!/usr/bin/env bash
# verify-registry-json.test.sh — opt-in --json envelope of verify-registry.sh (kit issue #1711 slice 2,
# json-envelope.v1.md). Pins: (1) the DEFAULT report stays byte-identical (golden recorded from the
# pre-change script); (2) the envelope carries the CLAUDE.md §7 state enum, the documented counts and
# item kinds, and agrees with the human Summary line; (3) a missing / too-old jq is a typed degraded
# result (rc 3), a failing jq is rc 1 with empty stdout, and a large accumulator reaches jq without argv.
#
# Env: VRJ_SUT=<path>        run against another copy of the script (used to execute RED against the
#                            pre-change SUT); default is ../verify-registry.sh.
#      The golden is FROZEN from the pre-change script, never from the SUT under test. Re-record with:
#        git show origin/main:research-sdd/toolbelt/verify-registry.sh > /tmp/vr-main.sh   (a build WITHOUT --json)
#        VRJ_SUT=/tmp/vr-main.sh VRJ_REGEN_GOLDEN=1 bash verify-registry-json.test.sh
#      VRJ_REGEN_GOLDEN=1    rewrite the golden from the SUT under test — regenerate only from a build
#                            whose default output is known good (it is not a frozen oracle then).
#
# Usage: verify-registry-json.test.sh [--prove-teeth]
# Exit: 0 = every assertion held · 1 = a regression · 2 = harness error.

set -uo pipefail
# HERMETICITY (kit issue #1157): never read the developer's real ~/.claude/projects launch history.
export RSDD_CLAUDE_PROJECTS_DIR="/nonexistent/rsdd-claude-history"
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="${VRJ_SUT:-$HERE/../verify-registry.sh}"
# shellcheck source=lib/stage-libs.sh
. "$HERE/lib/stage-libs.sh"   # rsdd_stage_libs: stage every toolbelt/lib file into a sandbox toolbelt
[ -f "$SUT" ] || { echo "FATAL: script under test not found: $SUT" >&2; exit 2; }
BASH_BIN="$(type -P bash)"; [ -n "$BASH_BIN" ] || { echo "FATAL: bash not on PATH" >&2; exit 2; }
# verify-registry.sh is a shim to `rsdd verify registry` (kit issues #2362/#2364): the cases run it end to end against the
# real Go binary (RSDD_BIN, else one build into the temp dir). The jq-degraded states (cases 3/7 of the old script) do not
# exist in Go (no jq is run); the kind sets are checked against the Go source (case 9); the old script-internals
# structural checks and teeth are gone with the script.
if [ -z "${RSDD_BIN:-}" ]; then
  command -v go >/dev/null 2>&1 || { echo "FATAL: no rsdd binary: RSDD_BIN unset and go not found (degraded, not a pass)" >&2; exit 2; }
  _vrj_bin_dir="$(mktemp -d)"
  ( cd "$HERE/../../rsdd" && go build -o "$_vrj_bin_dir/rsdd" ./cmd/rsdd ) || { echo "FATAL: go build ./cmd/rsdd failed" >&2; exit 2; }
  export RSDD_BIN="$_vrj_bin_dir/rsdd"
fi
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required for the --json cases" >&2; exit 2; }
for _l in retro-status target-paths block-files state-files corpus-markers hook-wiring; do
  [ -f "$HERE/../lib/$_l.sh" ] || { echo "FATAL: helper not found: $HERE/../lib/$_l.sh" >&2; exit 2; }
done
GOLD="$HERE/fixtures/verify-registry/json-envelope/default-output.golden"

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT" "${_vrj_bin_dir:-}"' EXIT
# HERMETICITY: keep lib/hook-wiring.sh's git-root walk-up inside the sandbox (see verify-registry.test.sh).
RSDD_HOOK_WIRING_CEILING="$(dirname "$ROOT")"; export RSDD_HOOK_WIRING_CEILING
export RESEARCH_HOME="$ROOT/home"   # the INFO absent line prints it; keep the golden machine-independent
unset RSDD_REGISTRY_TOL RSDD_ROW_MAXLEN _json_items
pass=0; fail=0
ok() { printf '  PASS  %-58s %s\n' "$1" "${2:-}"; pass=$((pass+1)); }
no() { printf '  FAIL  %-58s %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

# mkkit <name> : a runnable COPY of the SUT and its helpers at <ROOT>/<name>/toolbelt/ (KIT=dirname/..).
mkkit() {
  local kit="$ROOT/$1"
  rsdd_stage_libs "$kit/toolbelt"
  cp "$SUT" "$kit/toolbelt/verify-registry.sh"
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
# Normalise only path PREFIXES (sandbox root, fixture-dir name); the rest of every line stays compared.
gold_norm() { sed -e "s#$ROOT/home#@ROOT@/home#g" -e "s#$ROOT/[^/ ]*-ext/#@ROOT@/EXT/#g" -e "s#$ROOT#@ROOT@#g"; }

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

# 9 — STRUCTURAL: the kinds the Go command can emit == the kinds json-envelope.v1.md documents (both directions), and
#     every finding/record call passes a kind and a SEV of WARN|INFO. kinds_check <go-src-dir> <doc> : rc 0 = holds.
#     The kinds live in research-sdd/rsdd/internal/verify (registry*.go, tests excluded): `r.finding("kind", "SEV", ...)`
#     and `r.record("kind", "SEV", ...)`.
DOC="$HERE/../json-envelope.v1.md"
[ -f "$DOC" ] || { echo "FATAL: contract doc not found: $DOC" >&2; exit 2; }
GOSRC="$HERE/../../rsdd/internal/verify"
[ -d "$GOSRC" ] || { echo "FATAL: Go source not found: $GOSRC" >&2; exit 2; }
kinds_check() {
  local dir="$1" doc="$2" calls wellformed code docd
  # calls = every `r.finding(` / `r.record(` invocation (method definitions excluded); wellformed = those of the exact shape ("kind", "SEV",
  calls="$(cat "$dir"/registry*.go 2>/dev/null | grep -E '\br\.(finding|record)\(' | grep -vc '^func ')"
  wellformed="$(cat "$dir"/registry*.go 2>/dev/null | grep -E '\br\.(finding|record)\(' | grep -cE 'r\.(finding|record)\("[a-z][a-z-]*", "(WARN|INFO)",')"
  [ "$calls" -gt 0 ] && [ "$calls" = "$wellformed" ] || return 1
  code="$(cat "$dir"/registry*.go | grep -oE '\br\.(finding|record)\("[a-z][a-z-]*"' | sed -E 's/^r\.(finding|record)\("([a-z-]+)"/\2/' | sort -u)"
  docd="$(awk '/^### `research-sdd.verify-registry\/v1`/{f=1;next} f&&/^### /{f=0} f' "$doc" \
            | sed -nE 's/^\| `([a-z][a-z-]*)` \| .*/\1/p' | grep -vx 'kind' | sort -u)"
  [ -n "$code" ] && [ -n "$docd" ] && [ "$code" = "$docd" ]
}
# a copy of the non-test Go sources, for the teeth to mutate
if kinds_check "$GOSRC" "$DOC"; then
  ok "kinds: Go finding/record kinds == documented kinds (both directions), every call has SEV WARN|INFO" "($(cat "$GOSRC"/registry*.go | grep -cE '\br\.(finding|record)\(' ) call sites)"
else no "kinds: code/doc kind sets differ or a call lacks a WARN|INFO severity" "code=[$(cat "$GOSRC"/registry*.go | grep -oE '\br\.(finding|record)\("[a-z-]+"' | sed -E 's/.*\("//; s/"//' | sort -u | tr '\n' ' ')]"; fi
# 9b — #1780: unknown arguments are a usage error (exit 2, nothing on stdout, usage on stderr); the accumulator
#      row encoding lives in ONE helper (_vr_record) and the target count is computed ONCE.
argrej() { # argrej <kit> <args...> : rc 2, empty stdout, "usage" on stderr
  local k="$1" _ef; shift; _ef="$(mktemp "$ROOT/aerr.XXXXXX")"
  AOUT="$("$BASH_BIN" "$k/toolbelt/verify-registry.sh" "$@" 2>"$_ef")"; RC=$?; AERR="$(cat "$_ef")"; rm -f "$_ef"
  [ "$RC" = 2 ] && [ -z "$AOUT" ] && [[ "$AERR" == *"usage: verify-registry.sh"* ]]
}
kit="$(rich_kit j-argrej)"
if argrej "$kit" --bogus && argrej "$kit" --json --bogus && argrej "$kit" positional && argrej "$kit" --JSON; then
  ok "args: unknown / extra arguments → usage error, exit 2, empty stdout (also alongside --json)" "()"
else no "args: unknown argument not rejected" "rc=$RC out=[$AOUT] err=[$AERR]"; fi
run "$kit"; _plain="$OUT"; jrun "$kit"
if [ "$RC" = 0 ] && [ "$(jq_f .schema)" = "research-sdd.verify-registry/v1" ] && [ "$(printf '%s\n' "$_plain" | grep -c .)" -gt 0 ]; then
  ok "args: no argument and --json keep working after the usage check" "()"
else no "args: valid invocations broke" "rc=$RC"; fi

# 10 — ENVELOPE per kind: one small fixture per kind that case 2 does not already cover (case 2 pins nonconform-field,
#      hook-unwired, count-drift, no-corpus-marker, corpus-unresolvable, no-retros-wired, retro-drift, oversized-row,
#      absent-target). kcase <kind> <severity> <target-basename> <kit> asserts one item with that kind/severity/target.
kcase() {
  jrun "$4"
  if [ "$RC" = 0 ] \
     && [ "$(printf '%s' "$JOUT" | jq -r --arg k "$1" '[.items[]|select(.kind==$k)][0]|[.severity,.target]|join(",")' 2>/dev/null)" = "$2,$3" ]; then
    ok "JSON kind $1: item with severity $2 and target $3" "()"
  else no "JSON kind $1" "rc=$RC err=[$JERR] items=$(printf '%s' "$JOUT" | jq -c '[.items[]|[.kind,.severity,.target]]' 2>/dev/null | head -c 400)"; fi
}
# hook-off-root: wired hook, but the target is not its own git root (a git root one level up).
kit="$(mkkit k-offroot)"; ext="$ROOT/k-offroot-ext"; mkcorpus "$ext/repo/tA" 3 a; wire_hook() { mkdir -p "$1/.claude"; printf '{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"retro-gate-stop.sh"}]}]}}' > "$1/.claude/settings.json"; }
wire_hook "$ext/repo/tA"; git init -q "$ext/repo" >/dev/null 2>&1; mkdir -p "$ext/repo/tA/retros"; printf '# r\n' > "$ext/repo/tA/retros/r1.md"
write_targets "$kit" "$ext/repo/tA::3 md / hook yes"; kcase hook-off-root WARN tA "$kit"
# hook-wired-contradiction: row says hook no, the Stop hook is wired (target is its own git root).
kit="$(mkkit k-hookno)"; ext="$ROOT/k-hookno-ext"; mkcorpus "$ext/tA" 3 a; wire_hook "$ext/tA"; git init -q "$ext/tA" >/dev/null 2>&1
mkdir -p "$ext/tA/retros"; printf '# r\n' > "$ext/tA/retros/r1.md"
write_targets "$kit" "$ext/tA::3 md / hook no"; kcase hook-wired-contradiction WARN tA "$kit"
# nc-contradiction: the kit row carries nc but a RESEARCH-STATE.md sits under the kit dir.
kit="$(mkkit k-nccontra)"; mkcorpus "$kit/tA" 3 a; write_targets "$kit"; kcase nc-contradiction WARN "$(basename "$kit")" "$kit"
# nc-no-count / nc count-drift: nc rows (hand-written) without a count, and with a count far from the .md files at root.
kit="$(mkkit k-ncnocount)"; ext="$ROOT/k-ncnocount-ext"; mkdir -p "$ext/n1"; printf '# a\n' > "$ext/n1/a.md"
write_targets "$kit"; printf '| 5 | n1 | mature (git yes / nc) | `%s` |\n' "$ext/n1" >> "$kit/TARGETS.md"; kcase nc-no-count WARN n1 "$kit"
kit="$(mkkit k-ncdrift)"; ext="$ROOT/k-ncdrift-ext"; mkdir -p "$ext/n1"; printf '# a\n' > "$ext/n1/a.md"
write_targets "$kit"; printf '| 5 | n1 | mature (40 md / nc / git yes) | `%s` |\n' "$ext/n1" >> "$kit/TARGETS.md"; kcase count-drift WARN n1 "$kit"
# catalog-*: a local gen-catalog.py plus a CATALOG.md. rows <n> prints n data rows.
cat_fix() { # <name> <blocks-on-disk> <catalog-text-before-table|-> <rows> ; echo kit
  local kit ext i; kit="$(mkkit "$1")"; ext="$ROOT/$1-ext"
  if [ "$2" -gt 0 ]; then mkcorpus "$ext/tA" "$2" a; else mkdir -p "$ext/tA"; printf '# state\n\n<!-- research-state.v1 -->\ncovered_blocks: 5\n<!-- /research-state.v1 -->\n' > "$ext/tA/RESEARCH-STATE.md"; fi
  mkdir -p "$ext/tA/tools" "$ext/tA/retros"; printf '#!/usr/bin/env python3\n# gen-catalog\n' > "$ext/tA/tools/gen-catalog.py"; printf '# r\n' > "$ext/tA/retros/r1.md"
  { printf '# Catalogo\n\n%s\n\n| # | file | title |\n|---|---|---|\n' "$3"; i=0; while [ "$i" -lt "$4" ]; do i=$((i+1)); printf '| %d | f%d.md | T%d |\n' "$i" "$i" "$i"; done; } > "$ext/tA/CATALOG.md"
  write_targets "$kit" "$ext/tA::5 md"; printf '%s' "$kit"
}
kcase catalog-stale-header WARN tA "$(cat_fix k-cathead 5 'Total: **9 bloques**' 3)"
kcase catalog-stale WARN tA "$(cat_fix k-catstale 8 'Total: **5 bloques**' 5)"
kcase catalog-disc-zero WARN tA "$(cat_fix k-catdisc 0 'Total: **5 bloques**' 5)"
kcase catalog-unparseable WARN tA "$(cat_fix k-catnoparse 5 '(no count line here)' 1)"
# retros-unreadable: retros/ chmod 000 (a root user ignores the mode, so the case is skipped there with a reason).
kit="$(mkkit k-unread)"; ext="$ROOT/k-unread-ext"; mkcorpus "$ext/tA" 4 a; mkdir -p "$ext/tA/retros"; printf '# r\n' > "$ext/tA/retros/r1.md"
write_targets "$kit" "$ext/tA::4 md / 2 retros"; chmod 000 "$ext/tA/retros"
if [ "$(id -u)" = 0 ]; then ok "JSON kind retros-unreadable: SKIPPED — running as root, chmod 000 is not enforced" "()"; else kcase retros-unreadable WARN tA "$kit"; fi
chmod 755 "$ext/tA/retros"
# no-claimed-count: corpus row without any 'N md' claim.
kit="$(mkkit k-noclaim)"; ext="$ROOT/k-noclaim-ext"; mkcorpus "$ext/tA" 3 a; mkdir -p "$ext/tA/retros"; printf '# r\n' > "$ext/tA/retros/r1.md"
write_targets "$kit" "$ext/tA::git yes"; kcase no-claimed-count WARN tA "$kit"
# unclassifiable-blocks: block<N>.md names the canonical discriminator does not count (real 0).
kit="$(mkkit k-unclass)"; ext="$ROOT/k-unclass-ext"; mkdir -p "$ext/tA/retros"; printf '# s\n' > "$ext/tA/RESEARCH-STATE.md"; printf '# r\n' > "$ext/tA/retros/r1.md"
for _i in 1 2 3; do printf '# b\n' > "$ext/tA/block${_i}.md"; done
write_targets "$kit" "$ext/tA::0 md"; kcase unclassifiable-blocks WARN tA "$kit"
# kit-not-registered: TARGETS.md without the kit's own row.
kit="$(mkkit k-notreg)"; ext="$ROOT/k-notreg-ext"; mkcorpus "$ext/tA" 3 a; mkdir -p "$ext/tA/retros"; printf '# r\n' > "$ext/tA/retros/r1.md"
printf '# t\n\n| # | name | maturity | path |\n|---|---|---|---|\n| 1 | t1 | mature (3 md / git yes) | `%s` |\n' "$ext/tA" > "$kit/TARGETS.md"
kcase kit-not-registered WARN "$(basename "$kit")" "$kit"

# --- TEETH (--prove-teeth): the Go source has its own mutation gate (`make teeth` in research-sdd/rsdd); here each
#     mutant of the doc/Go kind sets and of the SHIM must break the case that pins it.
if [ "${1:-}" = "--prove-teeth" ]; then
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  mutant_bootstrap mutant_chain mutant_or_count mutant_chain_or_count || exit 2
  # gomut <label> <file> <sed-expr> : a copy of the Go sources in $ROOT/gomut-<label> with <file> mutated; prints the dir.
  gomut() {
    local d="$ROOT/gomut-$1"; mkdir -p "$d"; cp "$GOSRC"/registry*.go "$d/"; rm -f "$d"/*_test.go
    mutant_chain_or_count fail "teeth JSON-$1" "$GOSRC/$2" "$d/$2.mut" "$3" || return 1
    mv "$d/$2.mut" "$d/$2"; printf '%s' "$d"
  }
  # kind renamed / severity changed / record renamed in the Go source → the structural case breaks.
  for _t in 'kindcode|registrychecks.go|s/r.finding("hook-unwired", "WARN"/r.finding("hook-unwired-x", "WARN"/' \
            'kindsev|registry.go|s/r.finding("count-drift", "WARN"/r.finding("count-drift", "ERR"/' \
            'kindabs|registry.go|s/r.record("absent-target", "INFO"/r.record("absent-target-x", "INFO"/'; do
    IFS='|' read -r _l _f _s <<<"$_t"
    if _d="$(gomut "$_l" "$_f" "$_s")"; then
      if ! kinds_check "$_d" "$DOC"; then ok "teeth JSON-$_l: mutated Go source breaks the kinds case (has teeth)" "()"; else no "teeth JSON-$_l: mutant survived — kinds case is THEATER" ""; fi
    fi
  done
  # Doc-side teeth: a documented kind removed / an undocumented kind added must break kinds_check against the Go source.
  _dm1="$ROOT/doc-drop.md"; _dm2="$ROOT/doc-extra.md"
  sed '/^| `kit-not-registered` |/d' "$DOC" > "$_dm1"
  sed 's/^| `kit-not-registered` |/| `ghost-kind` | invented |\n| `kit-not-registered` |/' "$DOC" > "$_dm2"
  if ! cmp -s "$DOC" "$_dm1" && ! kinds_check "$GOSRC" "$_dm1"; then ok "teeth JSON-docdrop: a kind missing from the doc breaks the structural case" "()"; else no "teeth JSON-docdrop: mutant survived — structural case is THEATER" ""; fi
  if ! cmp -s "$DOC" "$_dm2" && ! kinds_check "$GOSRC" "$_dm2"; then ok "teeth JSON-docextra: an undocumented-in-code kind in the doc breaks the structural case" "()"; else no "teeth JSON-docextra: mutant survived — structural case is THEATER" ""; fi
  # Shim teeth: the arguments dropped → --json ignored, the envelope cases lose their JSON.
  if mutant_chain_or_count fail "teeth JSON-args" "$SUT" "$ROOT/jt-args.sh" 's/ "\$@"$//'; then
    _mk="$(mkkit jt-args)"; cp "$ROOT/jt-args.sh" "$_mk/toolbelt/verify-registry.sh"; jrun "$_mk"
    if ! jq -e . >/dev/null 2>&1 <<<"$JOUT"; then ok "teeth JSON-args: arguments dropped → no envelope (has teeth)" "()"; else no "teeth JSON-args: mutant still prints the envelope" ""; fi
  fi
  # Shim teeth: the kit hand-off dropped → the sandbox kit's own registry is not reconciled.
  if mutant_chain_or_count fail "teeth JSON-kit" "$SUT" "$ROOT/jt-kit.sh" 's/ --kit "\$KIT"//'; then
    _bk="$(clean_kit jt-kitb)"; jrun "$_bk"; _bt="$(jq_f '[.state,.counts.targets]|join(",")')"
    _mk="$(clean_kit jt-kit)"; cp "$ROOT/jt-kit.sh" "$_mk/toolbelt/verify-registry.sh"; jrun "$_mk"
    if [ -n "$_bt" ] && [ "$(jq_f '[.state,.counts.targets]|join(",")')" != "$_bt" ]; then ok "teeth JSON-kit: --kit dropped → another kit is reconciled (has teeth)" "()"; else no "teeth JSON-kit: mutant still reconciles the sandbox kit" ""; fi
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
