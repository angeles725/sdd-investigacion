#!/usr/bin/env bash
# sessionstart-budget.test.sh — SessionStart output budget (kit issue #1816, openspec/specs/kit-session-cost).
# Runs the three trimmed hooks (verify-registry, verify-tool-catalog, sweep-breakthroughs) against FROZEN
# instrument outputs (tests/fixtures/sessionstart-budget/*.raw — a dated reading of the real fleet, sanitised,
# never the live corpus) and asserts (a) a per-hook character cap on the hook's stdout and (b) that every
# count the verbose output carried survives in the compact form (anti-silent-zero §7).
# The caps are budget assertions on a FROZEN fixture; they are NOT the live aggregate reading.
# Usage: sessionstart-budget.test.sh [--prove-teeth]
# Env:   SB_TOOLBELT  directory holding the hooks under test (default: ../ of this suite) — used to run
#                     the RED proof against the pre-trim hooks.
# Exit: 0 all held · 1 regression · 2 harness error

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TB="${SB_TOOLBELT:-$HERE/..}"
FX="$HERE/fixtures/sessionstart-budget"

pass=0; fail=0
ok() { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "== sessionstart-budget.test.sh =="

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required" >&2; exit 2; }
for f in verify-registry.raw verify-tool-catalog.raw sweep-breakthroughs.raw; do
  [ -s "$FX/$f" ] || { echo "FATAL: fixture $FX/$f missing or empty" >&2; exit 2; }
done

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export TMPDIR="$TMP"

# Caps (characters of hook stdout) on the frozen fixture.
CAP_REG=1400; CAP_CAT=700; CAP_BRK=900

# stage <hook-file> <instrument-name> <raw-fixture> — copies the hook next to a stub instrument that
# replays the frozen raw output (rc 0). Hermetic: the real instrument and the live fleet never run.
stage() {
  local hook="$1" instr="$2" raw="$3" d="$TMP/$4"
  mkdir -p "$d"
  cp "$hook" "$d/$(basename "$hook")"
  printf '#!/usr/bin/env bash\ncat "%s"\nexit 0\n' "$raw" > "$d/$instr"
  chmod +x "$d/$instr" "$d/$(basename "$hook")"
}

# chars <hook-path> [args] — number of characters the hook prints (what the SessionStart budget counts).
chars() { bash "$@" 2>&1 | wc -m | tr -d ' '; }
# ctx <hook-path> [args] — the additionalContext text.
ctx() { bash "$@" 2>&1 | jq -r '.hookSpecificOutput.additionalContext'; }

# count_lines <regex> <text> — number of lines matching.
count_lines() { printf '%s\n' "$2" | grep -cE -- "$1"; }

# run_suite <toolbelt-dir> <tag> — stages the three hooks from <toolbelt-dir> and runs every assertion.
run_cases() {
  local tb="$1" t="$2"
  stage "$tb/verify-registry-hook.sh"      verify-registry.sh      "$FX/verify-registry.raw"      "$t-reg"
  stage "$tb/verify-tool-catalog-hook.sh"  verify-tool-catalog.sh  "$FX/verify-tool-catalog.raw"  "$t-cat"
  stage "$tb/sweep-breakthroughs-hook.sh"  sweep-breakthroughs.sh  "$FX/sweep-breakthroughs.raw"  "$t-brk"
  local R="$TMP/$t-reg/verify-registry-hook.sh" C="$TMP/$t-cat/verify-tool-catalog-hook.sh" B="$TMP/$t-brk/sweep-breakthroughs-hook.sh"
  local n o

  # ---- verify-registry-hook ----
  n="$(chars "$R")"
  [ "$n" -le "$CAP_REG" ] && ok "$t reg-1 registry hook <= $CAP_REG chars (got $n)" || no "$t reg-1 registry hook over cap $CAP_REG (got $n)"
  o="$(ctx "$R")"
  # Raw fixture carries the Summary line with every count; it must pass through whole.
  grep -qF "$(grep '^Summary:' "$FX/verify-registry.raw")" <<<"$o" \
    && ok "$t reg-2 Summary line (all counts) kept verbatim" || no "$t reg-2 Summary line altered or missing"
  # No WARN is dropped without a count: shown WARN + omitted == total WARN in the raw output.
  local total shown omitted
  total="$(grep -c '^WARN' "$FX/verify-registry.raw")"
  shown="$(count_lines '^WARN  ' "$o")"
  omitted="$(printf '%s\n' "$o" | sed -n 's/^WARN: +\([0-9]*\) more WARN line.*/\1/p')"
  [ "$((shown + ${omitted:-0}))" -eq "$total" ] \
    && ok "$t reg-3 WARN lines accounted for (shown $shown + omitted ${omitted:-0} == $total)" \
    || no "$t reg-3 WARN accounting broken (shown $shown + omitted ${omitted:-0} != $total)"
  # absent-input aggregate (distinct state) still visible.
  grep -q '^INFO: 14 registered target(s) absent' <<<"$o" \
    && ok "$t reg-4 absent-target INFO count kept" || no "$t reg-4 absent-target INFO count missing"
  # per-row INFO lines are counted, not silently dropped.
  grep -q '^INFO: 1 per-row INFO line(s) omitted' <<<"$o" \
    && ok "$t reg-5 per-row INFO lines counted" || no "$t reg-5 per-row INFO count missing"
  # --full is byte-identical to the instrument output (escape hatch).
  [ "$(ctx "$R" --full)" = "Research-SDD registry check (TARGETS.md vs reality):
$(cat "$FX/verify-registry.raw")" ] \
    && ok "$t reg-6 --full passes instrument output unchanged" || no "$t reg-6 --full differs from instrument output"

  # ---- verify-tool-catalog-hook ----
  n="$(chars "$C")"
  [ "$n" -le "$CAP_CAT" ] && ok "$t cat-1 catalog hook <= $CAP_CAT chars (got $n)" || no "$t cat-1 catalog hook over cap $CAP_CAT (got $n)"
  o="$(ctx "$C")"
  grep -qF "$(grep '^Summary:' "$FX/verify-tool-catalog.raw")" <<<"$o" \
    && ok "$t cat-2 Summary line kept verbatim" || no "$t cat-2 Summary line altered or missing"
  # Every uncataloged tool name stays visible, and the stated count matches the summary's.
  local miss=0 name
  while IFS= read -r name; do
    grep -qF "$name" <<<"$o" || { miss=$((miss+1)); echo "    missing tool name: $name"; }
  done < <(sed -n "s/^WARN  installed-but-not-cataloged: '\([^']*\)'.*/\1/p" "$FX/verify-tool-catalog.raw")
  [ "$miss" -eq 0 ] && ok "$t cat-3 every uncataloged tool name still listed" || no "$t cat-3 $miss tool name(s) lost"
  grep -q 'installed-but-not-cataloged (8):' <<<"$o" \
    && ok "$t cat-4 uncataloged count (8) stated" || no "$t cat-4 uncataloged count missing"

  # ---- sweep-breakthroughs-hook ----
  n="$(chars "$B")"
  [ "$n" -le "$CAP_BRK" ] && ok "$t brk-1 breakthroughs hook <= $CAP_BRK chars (got $n)" || no "$t brk-1 breakthroughs hook over cap $CAP_BRK (got $n)"
  o="$(ctx "$B")"
  grep -qF "$(grep '^Summary:' "$FX/sweep-breakthroughs.raw")" <<<"$o" \
    && ok "$t brk-2 Summary line kept verbatim" || no "$t brk-2 Summary line altered or missing"
  grep -q '^WARN: 18 unindexed breakthrough' <<<"$o" \
    && ok "$t brk-3 unindexed count (18) stated" || no "$t brk-3 unindexed count missing"
  grep -q 'INFO: 15 target(s) not traversed (absent-input)' <<<"$o" && grep -q 'INFO: 2 corpus(es) empty-input, 15 no-match' <<<"$o" \
    && ok "$t brk-4 absent / empty-input / no-match states all counted" || no "$t brk-4 a §7 state count is missing"
  [ "$(count_lines '^WARN: unindexed breakthrough' "$(ctx "$B" --full)")" -eq 18 ] \
    && ok "$t brk-5 --full still lists all 18 unindexed lines" || no "$t brk-5 --full lost per-breakthrough lines"
}

run_cases "$TB" main

# ---- Teeth (mutation proof) --------------------------------------------------
if [ "${1:-}" = "--prove-teeth" ]; then
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  declare -F mutant_chain >/dev/null || { echo "FATAL: lib/mutant.sh did not define mutant_chain" >&2; exit 2; }
  mk_mut() { rm -f -- "$3"; mutant_chain "$@" || { fail=$((fail+1)); return 1; }; }
  echo "-- teeth: each trim, undone, must push its hook over cap or lose a count --"

  # mut_tooth <label> <hook-basename> <instr> <raw> <cap> <sed-expr> — builds the mutant, stages it and
  # requires its output to EXCEED the cap (verbose output restored). A refused build is counted once.
  mut_tooth() {
    local label="$1" hb="$2" instr="$3" raw="$4" cap="$5" expr="$6" d="$TMP/mut-$1" n
    mkdir -p "$d"
    if mk_mut "$label" "$TB/$hb" "$d/$hb" "$expr"; then
      printf '#!/usr/bin/env bash\ncat "%s"\nexit 0\n' "$raw" > "$d/$instr"
      chmod +x "$d/$instr" "$d/$hb"
      n="$(chars "$d/$hb")"
      [ "$n" -gt "$cap" ] && ok "teeth $label: mutant output $n > cap $cap (RED as required)" \
                          || no "teeth $label: mutant still within cap ($n <= $cap) — the cap does not bite"
    fi
  }

  # A: registry — WARN cap disabled (maxwarn huge) and truncation neutered: all 14 verbose WARNs return.
  mut_tooth "A registry-uncapped" verify-registry-hook.sh verify-registry.sh "$FX/verify-registry.raw" "$CAP_REG" \
    's/-v maxwarn=6 -v wmax=100/-v maxwarn=999 -v wmax=9999/'
  # B: registry — compact filter skipped entirely.
  mut_tooth "B registry-noncompact" verify-registry-hook.sh verify-registry.sh "$FX/verify-registry.raw" "$CAP_REG" \
    's/if \[ "\$_full" = 0 \]; then  # COMPACT-GUARD/if false; then/'
  # C: catalog — compaction skipped: per-tool WARN lines return.
  mut_tooth "C catalog-noncompact" verify-tool-catalog-hook.sh verify-tool-catalog.sh "$FX/verify-tool-catalog.raw" "$CAP_CAT" \
    's/if \[ "\${1:-}" != "--full" \]; then  # COMPACT-GUARD/if false; then/'
  # D: breakthroughs — unindexed collapse neutered: per-line WARNs pass through.
  mut_tooth "D breakthroughs-uncollapsed" sweep-breakthroughs-hook.sh sweep-breakthroughs.sh "$FX/sweep-breakthroughs.raw" "$CAP_BRK" \
    's/\^WARN: unindexed breakthrough\/ {/^WARN: XXunindexed breakthrough\/ {/'

  # E: count tooth — registry overflow notice removed: output stays under cap but WARN accounting (reg-3) must go red.
  mkdir -p "$TMP/mut-E"
  if mk_mut "E registry-silent-overflow" "$TB/verify-registry-hook.sh" "$TMP/mut-E/verify-registry-hook.sh" \
       '/# WARN-OVERFLOW/d'; then
    printf '#!/usr/bin/env bash\ncat "%s"\nexit 0\n' "$FX/verify-registry.raw" > "$TMP/mut-E/verify-registry.sh"
    chmod +x "$TMP/mut-E/verify-registry.sh" "$TMP/mut-E/verify-registry-hook.sh"
    o="$(ctx "$TMP/mut-E/verify-registry-hook.sh")"
    e_total=; e_shown=; e_omitted=
    e_total="$(grep -c '^WARN' "$FX/verify-registry.raw")"
    e_shown="$(count_lines '^WARN  ' "$o")"
    e_omitted="$(printf '%s\n' "$o" | sed -n 's/^WARN: +\([0-9]*\) more WARN line.*/\1/p')"
    if [ "$((e_shown + ${e_omitted:-0}))" -ne "$e_total" ]; then
      ok "teeth E: overflow notice removed → accounting breaks ($e_shown + ${e_omitted:-0} != $e_total), reg-3 goes red"
    else
      no "teeth E: mutant still accounts for every WARN line"
    fi
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
