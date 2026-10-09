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
# HERMETICITY (kit issue #1157): never read the developer's real ~/.claude/projects launch history.
export RSDD_CLAUDE_PROJECTS_DIR="/nonexistent/rsdd-claude-history"
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
  mkdir -p "$d/lib" && cp "$(dirname "$hook")/lib/hook-emit.sh" "$d/lib/hook-emit.sh"   # the hook sources lib/hook-emit.sh beside itself (#1877)
  write_stub "$d/$instr" "$raw"
  chmod +x "$d/$(basename "$hook")"
}

# write_stub <stub-path> <raw-fixture> — the one stub-instrument writer: replays <raw-fixture>, exits 0.
write_stub() {
  printf '#!/usr/bin/env bash\ncat "%s"\nexit 0\n' "$2" > "$1"
  chmod +x "$1"
}

# utf8_clean <text> — rc 0 when the text is valid UTF-8 AND carries no U+FFFD: jq --arg silently turns an
# invalid byte sequence (a split multibyte character) into U+FFFD, so validity alone would never go red.
utf8_clean() {
  iconv -f UTF-8 -t UTF-8 <<<"$1" >/dev/null 2>&1 || return 1
  ! grep -qF $'\xEF\xBF\xBD' <<<"$1"
}

# warn_accounting <raw-fixture> <hook-output> — sets WA_TOTAL / WA_SHOWN / WA_OMITTED; rc 0 when
# shown + omitted == total (no WARN dropped without a count).
warn_accounting() {
  WA_TOTAL="$(grep -c '^WARN' "$1")"
  WA_SHOWN="$(count_lines '^WARN  ' "$2")"
  WA_OMITTED="$(printf '%s\n' "$2" | sed -n 's/^WARN: +\([0-9]*\) more WARN line.*/\1/p')"
  [ "$((WA_SHOWN + ${WA_OMITTED:-0}))" -eq "$WA_TOTAL" ]
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
  warn_accounting "$FX/verify-registry.raw" "$o" \
    && ok "$t reg-3 WARN lines accounted for (shown $WA_SHOWN + omitted ${WA_OMITTED:-0} == $WA_TOTAL)" \
    || no "$t reg-3 WARN accounting broken (shown $WA_SHOWN + omitted ${WA_OMITTED:-0} != $WA_TOTAL)"
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

  # The absent-target remediation hint (last sentence of the long INFO line) must survive truncation.
  grep -qF 'Verify RESEARCH_HOME (/fx/home) and that corpora exist at the registered paths.' <<<"$o" \
    && ok "$t reg-7 absent-target remediation hint survives compact mode" || no "$t reg-7 absent-target hint truncated away"
  # Fleet/kit-level WARNs are ranked ahead of per-target WARNs, so the cap can never hide them.
  grep -q 'kit repo is NOT in its own TARGETS.md' <<<"$o" && grep -q 'master cell is 236 chars' <<<"$o" \
    && ok "$t reg-8 kit-self-registration and oversized-row WARNs named under the cap" \
    || no "$t reg-8 a kit-level WARN was hidden behind the cap"
  # Truncation is character-safe: multibyte characters straddling a cut point never yield invalid UTF-8,
  # whatever the locale or awk (registry 100/110-char cuts, catalog 160-byte cut).
  stage "$tb/verify-registry-hook.sh"     verify-registry.sh     "$FX/verify-registry-multibyte.raw"     "$t-regmb"
  stage "$tb/verify-tool-catalog-hook.sh" verify-tool-catalog.sh "$FX/verify-tool-catalog-multibyte.raw" "$t-catmb"
  local loc mb
  for loc in C C.UTF-8; do
    mb="$(LC_ALL=$loc ctx "$TMP/$t-regmb/verify-registry-hook.sh"; LC_ALL=$loc ctx "$TMP/$t-catmb/verify-tool-catalog-hook.sh")"
    utf8_clean "$mb" \
      && ok "$t reg-9 multibyte cut stays valid UTF-8 under LC_ALL=$loc" \
      || no "$t reg-9 invalid UTF-8 after a multibyte cut under LC_ALL=$loc"
  done

  # ---- verify-tool-catalog-hook ----
  n="$(chars "$C")"
  [ "$n" -le "$CAP_CAT" ] && ok "$t cat-1 catalog hook <= $CAP_CAT chars (got $n)" || no "$t cat-1 catalog hook over cap $CAP_CAT (got $n)"
  o="$(ctx "$C")"
  grep -qF "$(grep '^Summary:' "$FX/verify-tool-catalog.raw")" <<<"$o" \
    && ok "$t cat-2 Summary line kept verbatim" || no "$t cat-2 Summary line altered or missing"
  # Scoped to the COLLAPSED line only (the Summary line also lists names, so a whole-output grep would pass
  # even if the collapsed line dropped one): every raw tool name is on it and its (N) equals the name count.
  local cl miss=0 name nnames cn
  cl="$(grep '^WARN  installed-but-not-cataloged (' <<<"$o")"
  nnames=0
  while IFS= read -r name; do
    nnames=$((nnames+1))
    grep -qF "$name" <<<"$cl" || { miss=$((miss+1)); echo "    collapsed line lost tool name: $name"; }
  done < <(sed -n "s/^WARN  installed-but-not-cataloged: '\([^']*\)'.*/\1/p" "$FX/verify-tool-catalog.raw")
  [ "$miss" -eq 0 ] && [ -n "$cl" ] && ok "$t cat-3 every uncataloged tool name on the collapsed line" || no "$t cat-3 $miss tool name(s) lost from the collapsed line (line present: ${cl:+yes})"
  cn="$(sed -n 's/^WARN  installed-but-not-cataloged (\([0-9]*\)):.*/\1/p' <<<"$cl")"
  [ "${cn:-x}" = "$nnames" ] \
    && ok "$t cat-4 collapsed line count ($cn) equals the name count ($nnames)" || no "$t cat-4 collapsed count '${cn:-}' != name count $nnames"

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
  mutant_bootstrap mutant_chain || exit 2
  mk_mut() { rm -f -- "$3"; mutant_chain "$@" || { fail=$((fail+1)); return 1; }; }
  echo "-- teeth: each trim, undone, must push its hook over cap or lose a count --"

  # mut_stage <label> <hook-basename> <instr> <raw> <sed-expr> — builds a mutant of the hook and stages it next
  # to a stub instrument replaying <raw>; sets MUT_HOOK. rc 1 when the build was refused (counted once by mk_mut).
  mut_stage() {
    local label="$1" hb="$2" instr="$3" raw="$4" expr="$5" d="$TMP/mut-$1"
    mkdir -p "$d/lib" && cp "$TB/lib/hook-emit.sh" "$d/lib/hook-emit.sh"   # the mutant sources lib/hook-emit.sh beside itself (#1877)
    mk_mut "$label" "$TB/$hb" "$d/$hb" "$expr" || return 1
    write_stub "$d/$instr" "$raw"
    chmod +x "$d/$hb"
    MUT_HOOK="$d/$hb"
  }

  # mut_tooth <label> <hook-basename> <instr> <raw> <cap> <sed-expr> — the mutant's output must EXCEED the cap
  # (verbose output restored).
  mut_tooth() {
    local label="$1" cap="$5" n
    mut_stage "$1" "$2" "$3" "$4" "$6" || return 0
    n="$(chars "$MUT_HOOK")"
    [ "$n" -gt "$cap" ] && ok "teeth $label: mutant output $n > cap $cap (RED as required)" \
                        || no "teeth $label: mutant still within cap ($n <= $cap) — the cap does not bite"
  }

  # lost_tooth <label> <hook-basename> <instr> <raw> <must-be-absent regex> <sed-expr> — the mutant's output
  # must LOSE the named text (the case asserting it would go red).
  lost_tooth() {
    local label="$1" lost="$5" mo
    mut_stage "$1" "$2" "$3" "$4" "$6" || return 0
    mo="$(ctx "$MUT_HOOK")"
    if ! grep -qE "$lost" <<<"$mo"; then
      ok "teeth $label: mutant lost '$lost' (case goes red)"
    else
      no "teeth $label: mutant still carries '$lost' — the assertion does not bite"
    fi
  }

  REG=verify-registry-hook.sh; REGI=verify-registry.sh; CAT=verify-tool-catalog-hook.sh; CATI=verify-tool-catalog.sh
  # A: registry — WARN cap disabled (maxwarn huge) and truncation neutered: all verbose WARNs return.
  mut_tooth "A registry-uncapped" $REG $REGI "$FX/verify-registry.raw" "$CAP_REG" \
    's/-v maxwarn=6 -v wmax=100/-v maxwarn=999 -v wmax=9999/'
  # B: registry — compact filter skipped entirely.
  mut_tooth "B registry-noncompact" $REG $REGI "$FX/verify-registry.raw" "$CAP_REG" \
    's/if \[ "\$_full" = 0 \]; then  # COMPACT-GUARD/if false; then/'
  # C: catalog — compaction skipped: per-tool WARN lines return.
  mut_tooth "C catalog-noncompact" $CAT $CATI "$FX/verify-tool-catalog.raw" "$CAP_CAT" \
    's/if \[ "\${1:-}" != "--full" \]; then  # COMPACT-GUARD/if false; then/'
  # D: breakthroughs — unindexed collapse neutered: per-line WARNs pass through.
  mut_tooth "D breakthroughs-uncollapsed" sweep-breakthroughs-hook.sh sweep-breakthroughs.sh "$FX/sweep-breakthroughs.raw" "$CAP_BRK" \
    's/\^WARN: unindexed breakthrough\/ {/^WARN: XXunindexed breakthrough\/ {/'

  # E: count tooth — registry overflow notice removed: output stays under cap but WARN accounting (reg-3) must go red.
  if mut_stage "E registry-silent-overflow" $REG $REGI "$FX/verify-registry.raw" '/# WARN-OVERFLOW/d'; then
    if ! warn_accounting "$FX/verify-registry.raw" "$(ctx "$MUT_HOOK")"; then
      ok "teeth E: overflow notice removed → accounting breaks ($WA_SHOWN + ${WA_OMITTED:-0} != $WA_TOTAL), reg-3 goes red"
    else
      no "teeth E: mutant still accounts for every WARN line"
    fi
  fi
  # F: ranking restored to instrument order → kit-level WARNs fall behind the cap (reg-8).
  lost_tooth "F registry-instrument-order" $REG $REGI "$FX/verify-registry.raw" 'kit repo is NOT in its own' \
    's/pri\[++np\] = \$0; else oth/oth[++no] = $0; else oth/'
  # G: tail-keeping neutered → plain truncation cuts the hint (reg-7).
  lost_tooth "G registry-hint-truncated" $REG $REGI "$FX/verify-registry.raw" 'registered paths\.' \
    's/return trunc(s, hmax) " " tail/return trunc(s, 170)/'
  # H: catalog collapsed line drops a name while keeping the (8) count → cat-3 (scoped to the collapsed line) goes red.
  lost_tooth "H catalog-drops-a-name" $CAT $CATI "$FX/verify-tool-catalog.raw" 'fernflower' \
    's/ | paste -sd, - | / | head -n 7 | paste -sd, - | /'
  # I/J: byte cut restored (trim removed) → a straddled multibyte char yields invalid UTF-8 under LC_ALL=C (reg-9).
  # shellcheck disable=SC2016
  mb_tooth() {
    local label="$1" hb="$2" instr="$3" raw="$4" expr="$5" mo
    mut_stage "$label" "$hb" "$instr" "$raw" "$expr" || return 0
    mo="$(LC_ALL=C ctx "$MUT_HOOK")"
    if ! utf8_clean "$mo"; then
      ok "teeth $label: byte cut → broken UTF-8 under LC_ALL=C (reg-9 goes red)"
    else
      no "teeth $label: mutant output is still valid UTF-8 — the assertion does not bite"
    fi
  }
  mb_tooth "I registry-byte-cut" $REG $REGI "$FX/verify-registry-multibyte.raw" 's/ | _utf8_trim)"  # UTF8-TRIM/)"/'
  mb_tooth "J catalog-byte-cut" $CAT $CATI "$FX/verify-tool-catalog-multibyte.raw" 's/| cut -c1-160 | _utf8_trim)"/| cut -c1-160)"/'
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
