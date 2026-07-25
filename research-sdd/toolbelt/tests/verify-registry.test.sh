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

# 10 — LOCAL-GENERATOR AUTHORITY (Fix #37). A corpus with its OWN generator (<corpus>/tools/gen-catalog.py)
#      plus a CATALOG.md whose "Total: N" differs from the raw canonical discriminator must reconcile against
#      that CATALOG total, not the discriminator (niagara: CATALOG 239 vs discriminator 237). Fixture: 5 real
#      block files (discriminator=5) but CATALOG says Total 40. (a) claim 40 md → matches CATALOG → QUIET;
#      (b) claim 5 md → matches the discriminator but NOT the CATALOG → now DRIFTS naming real=40 — proving
#      the CATALOG total (not the raw 5) drives the comparison when the local generator is present.
kit="$(mkkit c10-catalog)"; tgt="$kit/targetA"
mkcorpus "$tgt" 5 "a"                                   # 5 real block files → discriminator=5
mkdir -p "$tgt/tools"; printf '#!/usr/bin/env python3\n# gen-catalog\n' > "$tgt/tools/gen-catalog.py"
printf '# Catalogo de bloques\n\nTotal: **40 bloques**\n' > "$tgt/CATALOG.md"
write_targets "$kit" "$tgt::40 md"                      # claim matches the CATALOG total
run "$kit"
match_ok=0
[ "$RC" = 0 ] && ! grep -q 'refresh the row' <<<"$OUT" && grep -q 'Registry consistent with reality' <<<"$OUT" && match_ok=1
kit2="$(mkkit c10b-catalog-drift)"; tgt2="$kit2/targetA"
mkcorpus "$tgt2" 5 "a"
mkdir -p "$tgt2/tools"; printf '#!/usr/bin/env python3\n# gen-catalog\n' > "$tgt2/tools/gen-catalog.py"
printf '# Catalogo de bloques\n\nTotal: **40 bloques**\n' > "$tgt2/CATALOG.md"
write_targets "$kit2" "$tgt2::5 md"                     # claim matches the discriminator, NOT the CATALOG
OUT2="$("$BASH_BIN" "$kit2/toolbelt/verify-registry.sh" 2>&1)"; RC2=$?
drift_ok=0
[ "$RC2" = 0 ] && grep -qE 'WARN[[:space:]]+targetA .* claims 5 md but the corpus has 40 real block' <<<"$OUT2" \
  && grep -q 'CATALOG.md total via local gen-catalog.py' <<<"$OUT2" && drift_ok=1
if [ "$match_ok" = 1 ] && [ "$drift_ok" = 1 ]; then
  ok "10 local gen-catalog.py → CATALOG total (40) is authoritative, not discriminator (5)" "(exit $RC/$RC2)"
else
  no "10 local gen-catalog.py → CATALOG total (40) is authoritative, not discriminator (5)" "match=$match_ok drift=$drift_ok out=[$OUT] out2=[$OUT2]"
fi

# 11 — NC-EXEMPT: a target row with '/ nc' flag and NO RESEARCH-STATE.md is legitimately non-corpus.
#      The verifier must NOT emit 'corpus layout not resolvable'; instead it checks the root-level
#      .md count (maxdepth 1). A matching claim → no WARN, 'consistent' summary, exit 0.
kit="$(mkkit c11-nc-exempt)"; tgt="$kit/targetNC"
mkdir -p "$tgt"
printf '# README\n' > "$tgt/README.md"
printf '# ROADMAP\n' > "$tgt/ROADMAP.md"
printf '# GAPS\n'   > "$tgt/GAPS.md"   # 3 root-level .md, no RESEARCH-STATE
{ printf '# targets\n\n| # | name | maturity | path |\n|---|---|---|---|\n'
  printf '| 1 | targetNC | intermediate (3 md / nc / git no / remote no / hook no) | `%s` |\n' "$tgt"
} > "$kit/TARGETS.md"
run "$kit"
if [ "$RC" = 0 ] \
   && ! grep -q 'corpus layout not resolvable' <<<"$OUT" \
   && ! grep -qE 'WARN[[:space:]]+targetNC' <<<"$OUT" \
   && grep -q 'Summary: reconciled 1 target' <<<"$OUT" \
   && grep -q 'Registry consistent with reality' <<<"$OUT"; then
  ok "11 nc-marked no-RESEARCH-STATE + claim matches → no warn, consistent" "(exit $RC)"
else
  no "11 nc-marked no-RESEARCH-STATE + claim matches → no warn, consistent" "exit=$RC out=[$OUT]"
fi

# 12 — NC-DRIFT: nc-marked target with 3 root-level .md but claim 40 md → drift WARN naming the
#      target + the counts; no 'corpus layout not resolvable' WARN (the nc path ran, not the fallback).
kit="$(mkkit c12-nc-drift)"; tgt="$kit/targetNC"
mkdir -p "$tgt"
printf '# README\n' > "$tgt/README.md"
printf '# ROADMAP\n' > "$tgt/ROADMAP.md"
printf '# GAPS\n'   > "$tgt/GAPS.md"   # 3 root-level .md, no RESEARCH-STATE
{ printf '# targets\n\n| # | name | maturity | path |\n|---|---|---|---|\n'
  printf '| 1 | targetNC | intermediate (40 md / nc / git no) | `%s` |\n' "$tgt"
} > "$kit/TARGETS.md"
run "$kit"
if [ "$RC" = 0 ] \
   && ! grep -q 'corpus layout not resolvable' <<<"$OUT" \
   && grep -qE 'WARN[[:space:]]+targetNC .* claims 40 md but the non-corpus target has 3' <<<"$OUT"; then
  ok "12 nc-marked claim 40 vs real 3 root-level → drift WARN, no 'not resolvable'" "(exit $RC)"
else
  no "12 nc-marked claim 40 vs real 3 root-level → drift WARN, no 'not resolvable'" "exit=$RC out=[$OUT]"
fi

# 13 — NC-MIXED: nc-marked target alongside an UNMARKED no-RESEARCH-STATE target in one registry.
#      nc target → silent (no WARN); unmarked target → 'corpus not resolvable' WARN still fires.
#      This is the anti-blank-silencer gate: nc MUST NOT suppress the fallback for unmarked rows.
kit="$(mkkit c13-nc-mixed)"; tgtA="$kit/targetNC"; tgtB="$kit/targetPlain"
mkdir -p "$tgtA" "$tgtB"
printf '# README\n' > "$tgtA/README.md"     # nc: 1 root .md
printf '# block\n' > "$tgtB/foo-block1.md"  # plain: blocks but NO RESEARCH-STATE, NO nc
{ printf '# targets\n\n| # | name | maturity | path |\n|---|---|---|---|\n'
  printf '| 1 | targetNC    | intermediate (1 md / nc / git no) | `%s` |\n' "$tgtA"
  printf '| 2 | targetPlain | intermediate (1 md / git no) | `%s` |\n' "$tgtB"
} > "$kit/TARGETS.md"
run "$kit"
if [ "$RC" = 0 ] \
   && ! grep -qE 'WARN[[:space:]]+.*targetNC' <<<"$OUT" \
   && grep -qE 'WARN[[:space:]]+.*targetPlain — corpus layout not resolvable' <<<"$OUT"; then
  ok "13 nc mixed: nc silent, unmarked still 'corpus not resolvable' (anti-blank-silencer)" "(exit $RC)"
else
  no "13 nc mixed: nc silent, unmarked still 'corpus not resolvable' (anti-blank-silencer)" "exit=$RC out=[$OUT]"
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

  # teeth-nc: neuter the nc-marker exemption check (replace the condition with `false`) → an
  # nc-marked target must fall back to the 'corpus layout not resolvable' WARN, proving tests
  # 11 / 12 / 13 depend on the real nc-grep check (# NC-EXEMPT-CHECK sentinel in the SUT).
  echo "-- teeth-nc: neuter nc-marker check (false); nc target must fall back to 'not resolvable' WARN --"
  kit="$(mkkit teeth-nc)"; tgt="$kit/targetNC"
  mkdir -p "$tgt"; printf '# nc doc\n' > "$tgt/README.md"
  { printf '# targets\n\n| # | name | maturity | path |\n|---|---|---|---|\n'
    printf '| 1 | targetNC | intermediate (1 md / nc / git no) | `%s` |\n' "$tgt"
  } > "$kit/TARGETS.md"
  mut="$kit/toolbelt/verify-registry.sh"
  # Replace the nc-marker if-condition line (identified by '# NC-EXEMPT-CHECK' sentinel) with
  # `if false; then` so the nc path is never taken and the fallback WARN fires instead.
  if grep -q '# NC-EXEMPT-CHECK' "$mut"; then
    sed -i '/# NC-EXEMPT-CHECK/ s/.*/    if false; then  # NC-EXEMPT-CHECK [MUTATED]/' "$mut"
    mout="$("$BASH_BIN" "$mut" 2>&1)"; mrc=$?
    if [ "$mrc" = 0 ] && grep -q 'corpus layout not resolvable' <<<"$mout"; then
      ok "teeth-nc: neutered nc-marker → nc target gets 'not resolvable' WARN" "(exit $mrc)"
    else
      no "teeth-nc: neutered nc mutant didn't produce 'not resolvable' WARN" "mrc=$mrc mout=[$mout]"
    fi
  else
    no "teeth-nc: NC-EXEMPT-CHECK sentinel not found in SUT (nc feature not implemented or marker missing)"
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
