#!/usr/bin/env bash
# verify-registry.test.sh — smoke harness for verify-registry.sh (reconciles the MASTER registry
# TARGETS.md 'N md' claims against the REAL corpus block count, WARN-only). Mirrors the sweep test
# idiom (sweep-audits.test.sh): a throwaway COPY of the SUT runs inside a sandbox kit so KIT=dirname/..
# resolves hermetically, with no external target.
#
# Contract pinned here:
#   * a row whose claimed 'N md' matches the real on-disk block count (within tolerance) → NO drift WARN;
#   * a row that drifts BEYOND tolerance → a drift WARN naming the target + its claimed/real counts;
#   * a NESTED-layout corpus (<target>/research/) resolves via its RESEARCH-STATE.md, exactly like archive;
#   * a truncated '...' path row is DROPPED with the PARTIAL WARN naming its basename;
#   * the tolerance guard boundary (== tol quiet, > tol WARNs);
#   * a target with no RESEARCH-STATE → 'corpus layout not resolvable' WARN;
#   * WARN-ONLY: exit is ALWAYS 0 (even missing TARGETS.md), never a failure signal.
# The canonical BLOCK_RE discriminator + backtick-path derivation are already pinned exhaustively by
# gen-catalog / verify-state / sweep suites, so this suite spot-checks them via the count math.
#
# Usage: verify-registry.test.sh [--prove-teeth]
# Exit: 0 = every assertion held · 1 = a regression · 2 = harness error.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../verify-registry.sh"
[ -f "$SUT" ] || { echo "FATAL: script under test not found: $SUT" >&2; exit 2; }
BASH_BIN="$(type -P bash)"; [ -n "$BASH_BIN" ] || { echo "FATAL: bash not on PATH" >&2; exit 2; }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
pass=0; fail=0
ok() { printf '  PASS  %-58s %s\n' "$1" "${2:-}"; pass=$((pass+1)); }
no() { printf '  FAIL  %-58s %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

# mkkit <name> : lay down a runnable COPY of the SUT at <ROOT>/<name>/toolbelt/ so KIT=dirname/..
# resolves inside the sandbox; echoes the kit dir. TARGETS.md goes at its top.
mkkit() {
  local kit="$ROOT/$1"
  mkdir -p "$kit/toolbelt"
  cp "$SUT" "$kit/toolbelt/verify-registry.sh"
  printf '%s' "$kit"
}

# mkcorpus <corpus-dir> <nblocks> <prefix> : create a resolvable corpus — a RESEARCH-STATE.md at its
# root (the archive/verify-state anchor) plus <nblocks> canonical block files `<prefix>-block<i>.md`.
mkcorpus() {
  local dir="$1" n="$2" prefix="$3" i=0
  mkdir -p "$dir"
  printf '# state\n\n<!-- research-state.v1 -->\ncovered_blocks: %d\n<!-- /research-state.v1 -->\n' "$n" > "$dir/RESEARCH-STATE.md"
  while [ "$i" -lt "$n" ]; do i=$((i+1)); printf '# Block %d\n' "$i" > "$dir/${prefix}-block${i}.md"; done
}

# write_targets <kit> <spec...> : minimal TARGETS.md. Each spec is "<path>::<claim>" where <claim> is a
# maturity phrase such as "5 md" (or "-" to omit the count). The path is backtick-wrapped (the only thing
# the SUT resolves out of the table).
write_targets() {
  local kit="$1"; shift
  { printf '# targets\n\n| # | name | maturity | path |\n|---|---|---|---|\n'
    local i=0 spec p claim
    for spec in "$@"; do
      i=$((i+1)); p="${spec%%::*}"; claim="${spec#*::}"
      if [ "$claim" = "-" ]; then
        printf '| %d | t%d | mature | `%s` |\n' "$i" "$i" "$p"
      else
        printf '| %d | t%d | mature (%s / git yes / hook yes) | `%s` |\n' "$i" "$i" "$claim" "$p"
      fi
    done
  } > "$kit/TARGETS.md"
}

run() { OUT="$("$BASH_BIN" "$1/toolbelt/verify-registry.sh" 2>&1)"; RC=$?; }

echo "== verify-registry.test.sh (SUT: $(basename "$SUT")) =="

# 1 — MATCH: claimed 'N md' equals real block count → no drift WARN, 'consistent' summary, exit 0.
kit="$(mkkit c1-match)"; tgt="$kit/targetA"
mkcorpus "$tgt" 5 "a"
write_targets "$kit" "$tgt::5 md"
run "$kit"
if [ "$RC" = 0 ] \
   && ! grep -q 'refresh the row' <<<"$OUT" \
   && grep -q 'Summary: reconciled 1 target' <<<"$OUT" \
   && grep -q '0 count drift' <<<"$OUT" \
   && grep -q 'Registry consistent with reality' <<<"$OUT"; then
  ok "1 claimed==real → no drift WARN, consistent" "(exit $RC)"
else
  no "1 claimed==real → no drift WARN, consistent" "exit=$RC out=[$OUT]"
fi

# 2 — DRIFT beyond tolerance: claim 40 md, real 5 → drift WARN naming target + both counts, exit 0.
kit="$(mkkit c2-drift)"; tgt="$kit/targetA"
mkcorpus "$tgt" 5 "a"
write_targets "$kit" "$tgt::40 md"
run "$kit"
if [ "$RC" = 0 ] \
   && grep -qE 'WARN[[:space:]]+targetA .* claims 40 md but the corpus has 5 real block' <<<"$OUT" \
   && grep -q '1 count drift' <<<"$OUT"; then
  ok "2 claim 40 vs real 5 → drift WARN, exit 0" "(exit $RC)"
else
  no "2 claim 40 vs real 5 → drift WARN, exit 0" "exit=$RC out=[$OUT]"
fi

# 3 — NESTED layout: corpus lives at <target>/research/ (like three.js). Row registers the ROOT path; the
#     SUT must resolve the corpus via research/RESEARCH-STATE.md and count the nested blocks. Claim matches
#     → no drift, proving nested resolution (a flat <target>/*.md count would see ZERO and false-drift).
kit="$(mkkit c3-nested)"; tgt="$kit/targetN"
mkcorpus "$tgt/research" 6 "n"           # → $tgt/research/RESEARCH-STATE.md + 6 blocks
write_targets "$kit" "$tgt::6 md"        # registers the ROOT, not research/
run "$kit"
if [ "$RC" = 0 ] \
   && [ ! -e "$tgt/RESEARCH-STATE.md" ] \
   && ! grep -q 'refresh the row' <<<"$OUT" \
   && grep -q 'Registry consistent with reality' <<<"$OUT"; then
  ok "3 nested research/ corpus → resolved + counted (no false drift)" "(exit $RC)"
else
  no "3 nested research/ corpus → resolved + counted (no false drift)" "exit=$RC out=[$OUT]"
fi

# 3b — NESTED + DRIFT: same nested layout but claim 99 md vs real 6 → the drift WARN fires with the NESTED
#      count (6), proving the resolver both walks into research/ AND recounts there (teeth on nested path).
kit="$(mkkit c3b-nesteddrift)"; tgt="$kit/targetN"
mkcorpus "$tgt/research" 6 "n"
write_targets "$kit" "$tgt::99 md"
run "$kit"
if [ "$RC" = 0 ] && grep -qE 'WARN[[:space:]]+targetN .* claims 99 md but the corpus has 6 real block' <<<"$OUT"; then
  ok "3b nested + claim 99 → drift names nested count 6" "(exit $RC)"
else
  no "3b nested + claim 99 → drift names nested count 6" "exit=$RC out=[$OUT]"
fi

# 4 — TRUNCATED '...' path → dropped, PARTIAL WARN names its basename; a real target alongside still reconciles.
kit="$(mkkit c4-truncated)"; tgtA="$kit/targetA"; tgtDots="/home/x/Honeywell/.../niagara-help"
mkcorpus "$tgtA" 4 "a"
write_targets "$kit" "$tgtA::4 md" "$tgtDots::12 md"
run "$kit"
if [ "$RC" = 0 ] \
   && grep -q 'Summary: reconciled 1 target' <<<"$OUT" \
   && grep -qE 'WARN: 1 target\(s\) skipped .* PARTIAL' <<<"$OUT" \
   && grep -q 'niagara-help' <<<"$OUT"; then
  ok "4 truncated '...' path → dropped, PARTIAL WARN names it" "(exit $RC)"
else
  no "4 truncated '...' path → dropped, PARTIAL WARN names it" "exit=$RC out=[$OUT]"
fi

# 5 — TOLERANCE boundary (default tol=2). claim 7 vs real 5 → diff 2 == tol → QUIET (no drift). claim 8 vs
#     real 5 → diff 3 > tol → WARN. Pins the '-gt tol' guard (negative control for the drift assertion).
kit="$(mkkit c5-tolq)"; tgt="$kit/targetA"
mkcorpus "$tgt" 5 "a"
write_targets "$kit" "$tgt::7 md"
run "$kit"
quiet_ok=0
[ "$RC" = 0 ] && ! grep -qi 'drift.*targetA\|targetA.*drift' <<<"$OUT" && ! grep -qE 'WARN[[:space:]]+targetA' <<<"$OUT" && quiet_ok=1
kit2="$(mkkit c5-tolw)"; tgt2="$kit2/targetA"
mkcorpus "$tgt2" 5 "a"
write_targets "$kit2" "$tgt2::8 md"
OUT2="$("$BASH_BIN" "$kit2/toolbelt/verify-registry.sh" 2>&1)"; RC2=$?
warn_ok=0
[ "$RC2" = 0 ] && grep -qF 'drift 3 > tol 2' <<<"$OUT2" && grep -qE 'WARN[[:space:]]+targetA' <<<"$OUT2" && warn_ok=1
if [ "$quiet_ok" = 1 ] && [ "$warn_ok" = 1 ]; then
  ok "5 tol boundary: diff==2 quiet, diff==3 WARNs" "(exit $RC/$RC2)"
else
  no "5 tol boundary: diff==2 quiet, diff==3 WARNs" "quiet=$quiet_ok warn=$warn_ok out1=[$OUT] out2=[$OUT2]"
fi

# 6 — NON-RESOLVABLE: target dir exists but carries NO RESEARCH-STATE → 'corpus layout not resolvable' WARN,
#     counted as unresolvable, exit 0. (A row whose corpus predates the RESEARCH-STATE convention.)
kit="$(mkkit c6-noresolve)"; tgt="$kit/targetA"
mkdir -p "$tgt"; printf '# Block 1\n' > "$tgt/a-block1.md"   # blocks but no RESEARCH-STATE
write_targets "$kit" "$tgt::9 md"
run "$kit"
if [ "$RC" = 0 ] \
   && grep -qE 'WARN[[:space:]]+.*targetA — corpus layout not resolvable' <<<"$OUT" \
   && grep -q '1 unresolvable' <<<"$OUT"; then
  ok "6 no RESEARCH-STATE → 'not resolvable' WARN, exit 0" "(exit $RC)"
else
  no "6 no RESEARCH-STATE → 'not resolvable' WARN, exit 0" "exit=$RC out=[$OUT]"
fi

# 7 — MISSING TARGETS.md → WARN-only contract holds: exit 0 (NOT a failure), prints 'cannot find'.
kit="$(mkkit c7-notargets)"   # no write_targets → TARGETS.md absent
run "$kit"
if [ "$RC" = 0 ] && grep -qi 'cannot find' <<<"$OUT"; then
  ok "7 missing TARGETS.md → exit 0 (WARN-only), 'cannot find'" "(exit $RC)"
else
  no "7 missing TARGETS.md → exit 0 (WARN-only), 'cannot find'" "exit=$RC out=[$OUT]"
fi

# 8 — ENV override RSDD_REGISTRY_TOL: with tol=50, claim 40 vs real 5 (diff 35) is now WITHIN tolerance → quiet.
kit="$(mkkit c8-tolenv)"; tgt="$kit/targetA"
mkcorpus "$tgt" 5 "a"
write_targets "$kit" "$tgt::40 md"
OUT="$(RSDD_REGISTRY_TOL=50 "$BASH_BIN" "$kit/toolbelt/verify-registry.sh" 2>&1)"; RC=$?
if [ "$RC" = 0 ] && ! grep -qi 'drift.*targetA' <<<"$OUT" && grep -q '0 count drift' <<<"$OUT"; then
  ok "8 RSDD_REGISTRY_TOL=50 → diff 35 within tol, quiet" "(exit $RC)"
else
  no "8 RSDD_REGISTRY_TOL=50 → diff 35 within tol, quiet" "exit=$RC out=[$OUT]"
fi

# 9 — ROW HYGIENE lint: a master-table row with an oversized cell (> RSDD_ROW_MAXLEN, default 200) → a
#     WARN naming the target + the char count; a normal one-line row → NO such WARN. WARN-only, exit 0.
kit="$(mkkit c9-rowlint)"; tgt="$kit/targetA"
mkcorpus "$tgt" 5 "a"
big="$(printf 'x%.0s' $(seq 1 300))"    # a 300-char blob crammed into the maturity cell
{ printf '# targets\n\n| # | name | maturity | path |\n|---|---|---|---|\n'
  printf '| 1 | targetA | mature 5 md %s | `%s` |\n' "$big" "$tgt"
} > "$kit/TARGETS.md"
run "$kit"
if [ "$RC" = 0 ] && grep -qE 'WARN[[:space:]]+TARGETS row targetA master cell is [0-9]+ chars \(> 200\)' <<<"$OUT"; then
  ok "9 oversized master cell → row-hygiene WARN, exit 0" "(exit $RC)"
else
  no "9 oversized master cell → row-hygiene WARN, exit 0" "exit=$RC out=[$OUT]"
fi

# 9b — NEGATIVE control: a normal one-line row (all cells short) → NO row-hygiene WARN, and the env
#      override RSDD_ROW_MAXLEN is honored (set very low → even a short cell now WARNs).
kit="$(mkkit c9b-rowok)"; tgt="$kit/targetA"
mkcorpus "$tgt" 5 "a"
write_targets "$kit" "$tgt::5 md"
run "$kit"
norm_ok=0; [ "$RC" = 0 ] && ! grep -q 'master cell is' <<<"$OUT" && norm_ok=1
OUT2="$(RSDD_ROW_MAXLEN=5 "$BASH_BIN" "$kit/toolbelt/verify-registry.sh" 2>&1)"; RC2=$?
# write_targets labels the name column t<N>, so the WARN names 't1' (the row's name cell, not the path).
env_ok=0; [ "$RC2" = 0 ] && grep -qE 'WARN[[:space:]]+TARGETS row t1 master cell is [0-9]+ chars \(> 5\)' <<<"$OUT2" && env_ok=1
if [ "$norm_ok" = 1 ] && [ "$env_ok" = 1 ]; then
  ok "9b normal row quiet · RSDD_ROW_MAXLEN=5 WARNs" "(exit $RC/$RC2)"
else
  no "9b normal row quiet · RSDD_ROW_MAXLEN=5 WARNs" "norm=$norm_ok env=$env_ok out=[$OUT] out2=[$OUT2]"
fi

# --- TEETH (--prove-teeth): neuter the drift guard `[ "$d" -gt "$tol" ]` → the drift fixture (diff 35)
#     must STOP emitting its WARN. If it still WARNs, the case-2/case-5 drift assertions are THEATER (they
#     don't actually depend on the guard). Mirrors verify-state.test.sh's mutation self-test.
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: neuter the drift guard (-gt tol → -gt 999999); expect the drift fixture to stop WARNing --"
  kit="$(mkkit teeth-drift)"; tgt="$kit/targetA"
  mkcorpus "$tgt" 5 "a"
  write_targets "$kit" "$tgt::40 md"
  mut="$kit/toolbelt/verify-registry.sh"
  if grep -q 'if \[ "\$d" -gt "\$tol" \]; then' "$mut"; then
    sed -i 's/if \[ "\$d" -gt "\$tol" \]; then/if [ "\$d" -gt 999999 ]; then/' "$mut"
    mout="$("$BASH_BIN" "$mut" 2>&1)"; mrc=$?
    if [ "$mrc" = 0 ] && ! grep -q 'refresh the row' <<<"$mout"; then
      ok "teeth: neutered drift-guard mutant emits NO drift WARN → case 2/5 have teeth" "(exit $mrc)"
    else
      no "teeth: neutered mutant STILL WARNs drift → drift assertion is THEATER" "mrc=$mrc mout=[$mout]"
    fi
  else
    no "teeth: could not build mutant (drift guard line not found — did the SUT change?)"
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
