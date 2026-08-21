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
#   * operational failures (helper file absent, broken lib, missing TARGETS.md) → exit 1;
#   * advisory findings (drift, schema) remain WARN-only → exit 0.
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
LIB="$HERE/../lib/retro-status.sh"   # shared helper the SUT now sources for retro_is_excluded
[ -f "$LIB" ] || { echo "FATAL: helper not found: $LIB" >&2; exit 2; }
TP_LIB="$HERE/../lib/target-paths.sh"  # shared path derivation the SUT now sources
[ -f "$TP_LIB" ] || { echo "FATAL: target-paths helper not found: $TP_LIB" >&2; exit 2; }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
pass=0; fail=0
ok() { printf '  PASS  %-58s %s\n' "$1" "${2:-}"; pass=$((pass+1)); }
no() { printf '  FAIL  %-58s %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

# mkkit <name> : lay down a runnable COPY of the SUT and its shared helper at <ROOT>/<name>/toolbelt/
# so KIT=dirname/.. resolves inside the sandbox; echoes the kit dir. TARGETS.md goes at its top.
mkkit() {
  local kit="$ROOT/$1"
  mkdir -p "$kit/toolbelt/lib"
  cp "$SUT" "$kit/toolbelt/verify-registry.sh"
  cp "$LIB" "$kit/toolbelt/lib/retro-status.sh"   # SUT sources this for retro_is_excluded
  cp "$TP_LIB" "$kit/toolbelt/lib/target-paths.sh" # SUT sources this for target_paths_all
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

# 7 — MISSING TARGETS.md → operational failure: exit 1, prints 'cannot find', no Summary.
#     Updated from the old exit-0 WARN-only contract in issue #140: verify-registry now matches
#     the sibling scripts (sweep-retros, sweep-audits). A missing registry cannot be surfaced
#     as an advisory finding; it is an operational failure that aborts the instrument.
kit="$(mkkit c7-notargets)"   # no write_targets → TARGETS.md absent
run "$kit"
if [ "$RC" = 1 ] && grep -qi 'cannot find' <<<"$OUT" && ! grep -q 'Summary:' <<<"$OUT"; then
  ok "7 missing TARGETS.md → exit 1 (operational), 'cannot find', no summary" "(exit $RC)"
else
  no "7 missing TARGETS.md → exit 1 (operational), 'cannot find', no summary" "exit=$RC out=[$OUT]"
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

# 14 — NC-CONTRADICTION: nc-marked row + resolvable RESEARCH-STATE.md under the target →
#      contradiction WARN fires; the nc assertion contradicts disk and must be flagged so the
#      operator can correct either the row or the repository. Prevents a false nc certification
#      from hiding a real corpus target.
kit="$(mkkit c14-nc-contradiction)"; tgt="$kit/targetNC"
mkcorpus "$tgt" 3 "nc"   # RESEARCH-STATE.md + 3 nc-block*.md at $tgt root
{ printf '# targets\n\n| # | name | maturity | path |\n|---|---|---|---|\n'
  printf '| 1 | targetNC | intermediate (3 md / nc / git no) | `%s` |\n' "$tgt"
} > "$kit/TARGETS.md"
run "$kit"
if [ "$RC" = 0 ] \
   && grep -qE 'WARN[[:space:]]+targetNC.*RESEARCH-STATE' <<<"$OUT"; then
  ok "14 nc + resolvable RESEARCH-STATE → contradiction WARN, exit 0" "(exit $RC)"
else
  no "14 nc + resolvable RESEARCH-STATE → contradiction WARN, exit 0" "exit=$RC out=[$OUT]"
fi

# 15 — EXCLUDED-ONLY RETROS (B2): a target with blocks AND a §18-excluded retro (carrying
#      '<!-- kit-retro: exclude -->') is still effectively retro-free from the §18 perspective.
#      The '§18 feedback not wired' INFO must STILL fire — excluded files are not §18 kit retros.
#      RED before wiring retro_is_excluded: the old find|grep-q. sees the excluded file and
#      suppresses the INFO (false negative — the target looks wired when it is not).
kit="$(mkkit c15-excluded-only-retros)"; tgt="$kit/targetA"
mkcorpus "$tgt" 4 "a"
mkdir -p "$tgt/retros"
printf '<!-- kit-retro: exclude -->\n# client retro — not §18\nbody\n' > "$tgt/retros/client.md"
write_targets "$kit" "$tgt::4 md"
run "$kit"
if [ "$RC" = 0 ] \
   && grep -qE 'INFO[[:space:]]+targetA — [0-9]+ block\(s\) on disk but no retros' <<<"$OUT"; then
  ok "15 only-excluded retros → §18 feedback not wired INFO still fires (B2 wiring)" "(exit $RC)"
else
  no "15 only-excluded retros → §18 feedback not wired INFO still fires (B2 wiring)" "exit=$RC out=[$OUT]"
fi

# 16 — RED FIRST: bare `block<N>.md` files (no canonical prefix) → canonical discriminator
#      returns 0; the counter is SILENT and neither the drift guard nor the §18 INFO can fire.
#      After the fix, a WARN naming the count and reason fires instead of silence, and §18 fires
#      too — a target with 13 unclassifiable blocks and no retro must not be exempted by its
#      own non-canonical naming.
kit="$(mkkit c16-unclassifiable)"; tgt="$kit/targetA"
mkdir -p "$tgt"
printf '# state\n\n<!-- research-state.v1 -->\ncovered_blocks: 13\n<!-- /research-state.v1 -->\n' \
  > "$tgt/RESEARCH-STATE.md"
for i in $(seq 1 13); do printf '# Block %d\n' "$i" > "$tgt/block${i}.md"; done
# Claim 13 md (what the operator believes) so the unclaimed-count branch does not short-circuit
# and both the unclassifiable guard and the §18 check remain reachable.
write_targets "$kit" "$tgt::13 md"
run "$kit"
if [ "$RC" = 0 ] \
   && grep -qE 'WARN[[:space:]]+targetA.*unclassifiable' <<<"$OUT" \
   && grep -qE 'INFO[[:space:]]+targetA.*13 candidate block file\(s\) \(unclassifiable\)' <<<"$OUT"; then
  ok "16 bare block<N>.md → unclassifiable WARN + §18 INFO fire (anti-silent-zero)" "(exit $RC)"
else
  no "16 bare block<N>.md → unclassifiable WARN + §18 INFO fire (anti-silent-zero)" "exit=$RC out=[$OUT]"
fi

# 17 — CANONICAL regression guard: foo-block1.md..foo-block5.md → discriminator counts 5,
#      NO unclassifiable diagnostic emitted, behaviour unchanged from before this fix.
#      A retro is provided so §18 INFO does not confuse the assertion.
kit="$(mkkit c17-canonical-nochange)"; tgt="$kit/targetA"
mkcorpus "$tgt" 5 "foo"
mkdir -p "$tgt/retros"; printf '# retro\nbody\n' > "$tgt/retros/2026-01-01-retro.md"
write_targets "$kit" "$tgt::5 md"
run "$kit"
if [ "$RC" = 0 ] \
   && ! grep -q 'unclassifiable' <<<"$OUT" \
   && grep -q '0 count drift' <<<"$OUT" \
   && grep -q 'Registry consistent with reality' <<<"$OUT"; then
  ok "17 canonical foo-block<N>.md → no unclassifiable diagnostic, counted correctly" "(exit $RC)"
else
  no "17 canonical foo-block<N>.md → no unclassifiable diagnostic, counted correctly" "exit=$RC out=[$OUT]"
fi

# 18 — EMPTY corpus: no block files and no block-like candidates → no unclassifiable WARN.
#      Ensures the guard does not false-alarm when real=0 AND no candidates exist.
kit="$(mkkit c18-empty)"; tgt="$kit/targetA"
mkdir -p "$tgt"
printf '# state\n\n<!-- research-state.v1 -->\ncovered_blocks: 0\n<!-- /research-state.v1 -->\n' \
  > "$tgt/RESEARCH-STATE.md"
write_targets "$kit" "$tgt::0 md"
run "$kit"
if [ "$RC" = 0 ] \
   && ! grep -q 'unclassifiable' <<<"$OUT" \
   && grep -q 'Registry consistent with reality' <<<"$OUT"; then
  ok "18 empty corpus → no unclassifiable diagnostic, no false alarm" "(exit $RC)"
else
  no "18 empty corpus → no unclassifiable diagnostic, no false alarm" "exit=$RC out=[$OUT]"
fi

# 19 — FALSE-POSITIVE GUARD: ordinary corpus docs (README.md, INDEX.md, CATALOG.md,
#      RESEARCH-STATE.md, SOURCES.md) carry no 'block'/'bloque' in their names and must
#      NOT trigger the unclassifiable diagnostic. This guard matters most: a noisy false
#      alarm on every session trains operators to ignore the signal, defeating its purpose.
#
#      Extended with boundary names that exercise the new matching rule: these are plausible
#      corpus documents (especially in Spanish-authored corpora) that the OLD regex fired on,
#      causing false alarms. All four must remain silent under the fixed rule:
#        blocking-issues.md   — 'block' in name, but followed by a letter, not a digit
#        block-diagram.md     — 'block' in name, followed by '-d', no digit after separator
#        bloques-pendientes.md — 'bloque' in name, followed by 's', not a digit
#        roadblock.md         — does NOT start with block/bloque; '/' appears before 'roadblock'
#      The old comment INCORRECTLY named roadblock.md as the false-positive surface; in reality
#      it never fired (path separator is before 'roadblock', not before 'block').
kit="$(mkkit c19-fp-guard)"; tgt="$kit/targetA"
mkdir -p "$tgt"
printf '# state\n\n<!-- research-state.v1 -->\ncovered_blocks: 0\n<!-- /research-state.v1 -->\n' \
  > "$tgt/RESEARCH-STATE.md"
printf '# README\n'  > "$tgt/README.md"
printf '# INDEX\n'   > "$tgt/INDEX.md"
printf '# CATALOG\n' > "$tgt/CATALOG.md"
printf '# SOURCES\n' > "$tgt/SOURCES.md"
# Boundary names that fire under the old '/(block|bloque)' regex but must not fire after the fix.
printf '# blocking issues\n' > "$tgt/blocking-issues.md"
printf '# block diagram\n'   > "$tgt/block-diagram.md"
printf '# pendientes\n'      > "$tgt/bloques-pendientes.md"
printf '# roadblock\n'       > "$tgt/roadblock.md"
write_targets "$kit" "$tgt::0 md"
run "$kit"
if [ "$RC" = 0 ] \
   && ! grep -q 'unclassifiable' <<<"$OUT"; then
  ok "19 ordinary docs + boundary names (blocking-issues/block-diagram/bloques-pendientes/roadblock) → no false alarm" "(exit $RC)"
else
  no "19 ordinary docs + boundary names (blocking-issues/block-diagram/bloques-pendientes/roadblock) → no false alarm" "exit=$RC out=[$OUT]"
fi

# 20 — FAIL-CLOSED on a broken target-paths helper. verify-registry sources lib/target-paths.sh;
#      a helper that exists but defines no function must abort with exit 1, a 'failed to define'
#      message, and no Summary line. Updated from the old exit-0 in issue #140: a broken
#      instrument is an operational failure, not an advisory finding.
kit="$(mkkit c20-broken-tp)"; tgt="$kit/targetA"
mkcorpus "$tgt" 3 "a"
write_targets "$kit" "$tgt::3 md"
printf '#!/usr/bin/env bash\n# broken: sources cleanly but defines no target_paths_all\n' \
  > "$kit/toolbelt/lib/target-paths.sh"
run "$kit"
if [ "$RC" = 1 ] \
   && grep -q 'failed to define target_paths_all' <<<"$OUT" \
   && ! grep -q 'Summary:' <<<"$OUT"; then
  ok "20 broken target-paths helper → exit 1, 'failed to define' message, no summary" "(exit $RC)"
else
  no "20 broken target-paths helper → exit 1, 'failed to define' message, no summary" "exit=$RC out=[$OUT]"
fi

# 21 — \$RESEARCH_HOME path form resolves. A TARGETS.md row written as \`\$RESEARCH_HOME/sub\`
#      was invisible to the old backtick+slash grep; after the retrofit it expands and the corpus
#      directory IS walked (not "corpus layout not resolvable"). Note: the row-lookup inside
#      verify-registry.sh uses the EXPANDED path as needle, but TARGETS.md stores the literal
#      \`\$RESEARCH_HOME/...\` form, so the claimed-count row is empty → "no claimed N md" WARN fires.
#      That is a pre-existing row-lookup limitation, NOT a regression of this retrofit.
#      The key assertion: 1 target reconciled AND corpus was found (not "not resolvable").
#      RED before retrofit: old grep sees nothing, Summary: 0 targets (or zero-paths guard fires).
kit="$(mkkit c21-rh-path)"
_rh_base_vr="$ROOT/rh_base_vr_$$"
mkdir -p "$_rh_base_vr"
tgt="$_rh_base_vr/rh_corpus"
mkcorpus "$tgt" 4 "r"
{ printf '# targets\n\n| # | name | maturity | path |\n|---|---|---|---|\n'
  printf '| 1 | t1 | mature (4 md / git yes / hook yes) | `$RESEARCH_HOME/rh_corpus` |\n'
} > "$kit/TARGETS.md"
OUT="$(RESEARCH_HOME="$_rh_base_vr" "$BASH_BIN" "$kit/toolbelt/verify-registry.sh" 2>&1)"; RC=$?
unset _rh_base_vr
if [ "$RC" = 0 ] \
   && grep -q 'reconciled 1 target' <<<"$OUT" \
   && ! grep -q 'corpus layout not resolvable' <<<"$OUT"; then
  ok "21 \$RESEARCH_HOME path → expanded, corpus found (not 'not resolvable'), 1 target reconciled" "(exit $RC)"
else
  no "21 \$RESEARCH_HOME path → expanded, corpus found (not 'not resolvable'), 1 target reconciled" "exit=$RC out=[$OUT]"
fi

# 22 — ANTI-SILENT-ZERO (WARN-only): TARGETS.md with no backtick paths → loud ERROR message,
#      exit 0 (WARN-only contract), no Summary line.
#      RED before retrofit: inline grep returns empty, run exits 0 with "reconciled 0 targets."
kit="$(mkkit c22-zeropaths)"
printf '# targets\n\n| # | name | path |\n|---|---|---|\n| 1 | t1 | /no/backticks |\n' \
  > "$kit/TARGETS.md"
run "$kit"
if [ "$RC" = 0 ] \
   && grep -qi 'ERROR.*no usable target paths' <<<"$OUT" \
   && ! grep -q 'Summary:' <<<"$OUT"; then
  ok "22 no usable paths → exit 0 (WARN-only), ERROR message, no summary" "(exit $RC)"
else
  no "22 no usable paths → exit 0 (WARN-only), ERROR message, no summary" "exit=$RC out=[$OUT]"
fi

# 23 — $RESEARCH_HOME path: row uses `$RESEARCH_HOME/...` form, corpus on disk, claimed count
#      matches real count → row IS found via the raw (as-written) token, count IS reconciled,
#      "no claimed 'N md' count" WARN does NOT fire, "Registry consistent with reality" IS present.
#      RED before fix: verify-registry uses the EXPANDED path as needle → grep misses the raw
#      `$RESEARCH_HOME/...` form in TARGETS.md → claimed="" → "no claimed" WARN fires.
kit="$(mkkit c23-rh-rowlookup)"
_rh_base_vr23="$ROOT/rh_base_vr23_$$"
mkdir -p "$_rh_base_vr23"
tgt="$_rh_base_vr23/rh_corpus"
mkcorpus "$tgt" 5 "r"
{ printf '# targets\n\n| # | name | maturity | path |\n|---|---|---|---|\n'
  printf '| 1 | t1 | mature (5 md / git yes / hook yes) | `$RESEARCH_HOME/rh_corpus` |\n'
} > "$kit/TARGETS.md"
OUT="$(RESEARCH_HOME="$_rh_base_vr23" "$BASH_BIN" "$kit/toolbelt/verify-registry.sh" 2>&1)"; RC=$?
unset _rh_base_vr23
if [ "$RC" = 0 ] \
   && grep -q 'reconciled 1 target' <<<"$OUT" \
   && grep -q '0 count drift' <<<"$OUT" \
   && grep -q 'Registry consistent with reality' <<<"$OUT" \
   && ! grep -qE 'no claimed.*md.*count' <<<"$OUT"; then
  ok "23 \$RESEARCH_HOME row: raw token lookup, count reconciled, no 'no claimed' warn" "(exit $RC)"
else
  no "23 \$RESEARCH_HOME row: raw token lookup, count reconciled, no 'no claimed' warn" "exit=$RC out=[$OUT]"
fi

# ---- KIT-SELF-REGISTRATION GATE (kit-sup #6) -------------------------------------------------------
# verify-registry.sh must warn when the kit repo itself is NOT listed as a target in its own
# TARGETS.md. A kit that supervises other corpora without supervising itself is the exact gap
# kit-sup #6 closes.

# 24 — kit IS in its own TARGETS.md → NO self-reg WARN.
#      The kit row carries nc (no corpus) to avoid the contradiction check; the target is placed
#      OUTSIDE the kit dir so the nc search can't see the target's RESEARCH-STATE.md.
kit="$(mkkit c24-selfreg-ok)"
tgt24="$ROOT/c24-selfreg-tgt"   # sibling of kit — not a subdir of kit
mkcorpus "$tgt24" 3 "a"
{ printf '# targets\n\n| # | name | maturity | path |\n|---|---|---|---|\n'
  printf '| 1 | t1 | mature (3 md / git yes / hook yes) | `%s` |\n' "$tgt24"
  printf '| 2 | kit | active (0 md / nc / git yes) | `%s` |\n' "$kit"
} > "$kit/TARGETS.md"
run "$kit"
if [ "$RC" = 0 ] \
   && ! grep -qiE 'kit repo is NOT in its own TARGETS' <<<"$OUT"; then
  ok "24 kit IS in own TARGETS.md → no self-reg WARN" "(exit $RC)"
else
  no "24 kit in TARGETS.md → self-reg WARN should not fire" "exit=$RC out=[$OUT]"
fi

# 25 — kit ABSENT from its own TARGETS.md → self-reg WARN fires, exit still 0 (WARN-only).
kit="$(mkkit c25-selfreg-absent)"; tgt="$kit/targetA"
mkcorpus "$tgt" 3 "a"
write_targets "$kit" "$tgt::3 md"   # kit dir is NOT included in TARGETS.md
run "$kit"
if [ "$RC" = 0 ] \
   && grep -qiE 'kit repo is NOT in its own TARGETS' <<<"$OUT"; then
  ok "25 kit ABSENT from TARGETS.md → self-reg WARN fires (exit 0)" "(exit $RC)"
else
  no "25 kit absent → expected self-reg WARN but not found" "exit=$RC out=[$OUT]"
fi

# 26 — FALSE-POSITIVE: kit row registers the REPO ROOT (dirname $KIT), not the kit subdir.
#      In sdd-investigacion, TARGETS.md row 22 registers /home/.../sdd-investigacion (repo root)
#      while $KIT resolves to .../sdd-investigacion/research-sdd (the kit subdirectory).
#      Both conventions are valid; the gate must accept either and NOT fire the self-reg WARN.
repo26="$ROOT/c26-repo"          # the "repo root" that TARGETS.md will register
kit26="$repo26/research-sdd"     # KIT resolves here: dirname(verify-registry.sh)/..
mkdir -p "$kit26/toolbelt/lib" "$repo26"
cp "$SUT" "$kit26/toolbelt/verify-registry.sh"
cp "$LIB" "$kit26/toolbelt/lib/retro-status.sh"
cp "$TP_LIB" "$kit26/toolbelt/lib/target-paths.sh"
# Register the repo root with nc + 0 md → count check trivially passes (0 == 0), no other noise.
{ printf '# targets\n\n| # | name | maturity | path |\n|---|---|---|---|\n'
  printf '| 1 | sdd-investigacion | intermediate (0 md / nc / git yes) | `%s` |\n' "$repo26"
} > "$kit26/TARGETS.md"
OUT="$("$BASH_BIN" "$kit26/toolbelt/verify-registry.sh" 2>&1)"; RC=$?
if [ "$RC" = 0 ] \
   && ! grep -qiE 'kit repo is NOT in its own TARGETS' <<<"$OUT"; then
  ok "26 kit registered as REPO ROOT (dirname \$KIT) → no false-positive self-reg WARN" "(exit $RC)"
else
  no "26 kit registered as REPO ROOT → self-reg WARN fired (false positive)" "exit=$RC out=[$OUT]"
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

  # teeth-nc-contradiction: neuter the contradiction-check guard (replace the condition with `false`)
  # → an nc-marked target WITH a resolvable RESEARCH-STATE.md must STOP emitting the contradiction
  # WARN, proving that test 14 depends on the real NC-CONTRADICTION-CHECK, not theater.
  echo "-- teeth-nc-contradiction: neuter contradiction-check (false); nc+RESEARCH-STATE must NOT WARN --"
  kit="$(mkkit teeth-nc-contradiction)"; tgt="$kit/targetNC"
  mkcorpus "$tgt" 3 "nc"   # RESEARCH-STATE.md + blocks at $tgt root — same fixture as test 14
  { printf '# targets\n\n| # | name | maturity | path |\n|---|---|---|---|\n'
    printf '| 1 | targetNC | intermediate (3 md / nc / git no) | `%s` |\n' "$tgt"
  } > "$kit/TARGETS.md"
  mut="$kit/toolbelt/verify-registry.sh"
  if grep -q '# NC-CONTRADICTION-CHECK' "$mut"; then
    sed -i '/# NC-CONTRADICTION-CHECK/ s/.*/    if false; then  # NC-CONTRADICTION-CHECK [MUTATED]/' "$mut"
    mout="$("$BASH_BIN" "$mut" 2>&1)"; mrc=$?
    if [ "$mrc" = 0 ] && ! grep -qE 'WARN[[:space:]]+targetNC.*RESEARCH-STATE' <<<"$mout"; then
      ok "teeth-nc-contradiction: neutered check → nc+RESEARCH-STATE emits no contradiction WARN (test 14 has teeth)" "(exit $mrc)"
    else
      no "teeth-nc-contradiction: neutered check still emits WARN or exited non-zero" "mrc=$mrc mout=[$mout]"
    fi
  else
    no "teeth-nc-contradiction: NC-CONTRADICTION-CHECK sentinel not found in SUT"
  fi

  # teeth-unclassifiable: neuter the unclassifiable-check guard (identified by # UNCLASSIFIABLE-CHECK
  # sentinel in the SUT); the bare block<N>.md fixture must STOP emitting the WARN — proving test 16
  # depends on the real guard and not on coincidental output.
  echo "-- teeth-unclassifiable: neuter UNCLASSIFIABLE-CHECK; bare block<N>.md must NOT WARN --"
  kit="$(mkkit teeth-unclassifiable)"; tgt="$kit/targetA"
  mkdir -p "$tgt"
  printf '# state\n\n<!-- research-state.v1 -->\ncovered_blocks: 13\n<!-- /research-state.v1 -->\n' \
    > "$tgt/RESEARCH-STATE.md"
  for i in $(seq 1 13); do printf '# Block %d\n' "$i" > "$tgt/block${i}.md"; done
  write_targets "$kit" "$tgt::13 md"
  mut="$kit/toolbelt/verify-registry.sh"
  if grep -q '# UNCLASSIFIABLE-CHECK' "$mut"; then
    sed -i '/# UNCLASSIFIABLE-CHECK/ s/.*/    if false; then  # UNCLASSIFIABLE-CHECK [MUTATED]/' "$mut"
    mout="$("$BASH_BIN" "$mut" 2>&1)"; mrc=$?
    # Assert that targetA's unclassifiable WARN is absent. Pin to targetA explicitly: the kit name
    # may contain "unclassifiable" (e.g. teeth-unclassifiable) and the self-reg gate now emits
    # `WARN  <kit-name> — kit repo is NOT...`, which would false-match a bare .*unclassifiable pattern.
    if [ "$mrc" = 0 ] && ! grep -qE 'WARN[[:space:]]+targetA.*unclassifiable' <<<"$mout"; then
      ok "teeth-unclassifiable: neutered guard → bare blocks emit NO unclassifiable WARN (test 16 has teeth)" "(exit $mrc)"
    else
      no "teeth-unclassifiable: neutered mutant STILL emits unclassifiable WARN → test 16 is THEATER" "mrc=$mrc mout=[$mout]"
    fi
  else
    no "teeth-unclassifiable: UNCLASSIFIABLE-CHECK sentinel not found in SUT (guard not implemented or marker missing)"
  fi

  # teeth-count-subst: neuter the count+noun substitution (identified by # SUBST-COUNT-CHECK sentinel
  # in the SUT). When the substitution is a no-op, the INFO must report "0 block(s) on disk" instead
  # of "13 candidate block file(s) (unclassifiable) on disk" — proving that test 16's explicit count
  # assertion is load-bearing: deleting or breaking the substitution goes RED, not vacuously green.
  # A marker guard (`grep -q '# SUBST-COUNT-CHECK'`) ensures a missed sed is detected and reported
  # rather than passing vacuously.
  echo "-- teeth-count-subst: neuter SUBST-COUNT-CHECK; INFO must NOT name 13 candidate files --"
  kit="$(mkkit teeth-count-subst)"; tgt="$kit/targetA"
  mkdir -p "$tgt"
  printf '# state\n\n<!-- research-state.v1 -->\ncovered_blocks: 13\n<!-- /research-state.v1 -->\n' \
    > "$tgt/RESEARCH-STATE.md"
  for i in $(seq 1 13); do printf '# Block %d\n' "$i" > "$tgt/block${i}.md"; done
  write_targets "$kit" "$tgt::13 md"
  mut="$kit/toolbelt/verify-registry.sh"
  if grep -q '# SUBST-COUNT-CHECK' "$mut"; then
    # Replace the substitution guard with `if false; then` so the body never runs:
    # _vr_effective_count stays at $real (0) and _vr_count_noun stays "block(s) on disk"
    # — the pre-fix misleading output. Using `if false; then` preserves the fi structure.
    sed -i '/# SUBST-COUNT-CHECK/ s/.*/      if false; then  # SUBST-COUNT-CHECK [MUTATED]/' "$mut"
    mout="$("$BASH_BIN" "$mut" 2>&1)"; mrc=$?
    if [ "$mrc" = 0 ] && ! grep -qE 'INFO[[:space:]]+targetA.*13 candidate block file' <<<"$mout"; then
      ok "teeth-count-subst: neutered substitution → INFO no longer names 13 candidate files (test 16 count assertion has teeth)" "(exit $mrc)"
    else
      no "teeth-count-subst: neutered mutant STILL names 13 candidate files → test 16 count assertion is THEATER" "mrc=$mrc mout=[$mout]"
    fi
  else
    no "teeth-count-subst: SUBST-COUNT-CHECK sentinel not found in SUT (substitution not implemented or marker missing)"
  fi

  # teeth-VR-T1: neuter declare-F for target_paths_all → broken helper lacks the specific message.
  # This proves case 20's 'failed to define target_paths_all' message assertion is load-bearing.
  # NOTE (issue #140): neutering only the target_paths_all guard leaves target_paths_pairs firing
  # (exit 1), so the mutant may still exit non-zero — but via the OTHER guard, without the specific
  # message. The assertion checks message absence only; exit code teeth are covered by M2 below.
  echo "-- teeth VR-T1: neuter declare-F for target_paths_all; 'failed to define target_paths_all' msg must vanish --"
  _vr_tp_anchor='declare -F target_paths_all >/dev/null 2>&1 || { echo "verify-registry:'
  if ! grep -qF "$_vr_tp_anchor" "$SUT"; then
    no "teeth VR-T1: locate declare-F target_paths_all guard in SUT" "anchor not found — SUT drifted?"
  else
    kit="$(mkkit teeth-vr-t1)"; tgt="$kit/targetA"
    mkcorpus "$tgt" 3 "a"
    write_targets "$kit" "$tgt::3 md"
    printf '#!/usr/bin/env bash\n# broken: no target_paths_all\n' > "$kit/toolbelt/lib/target-paths.sh"
    mut="$kit/toolbelt/verify-registry.sh"
    # Entire single-line guard replaced with no-op; the 'failed to define target_paths_all' echo is gone.
    sed 's/declare -F target_paths_all .*/: # __VRT1_NEUTERED__/' "$SUT" > "$mut"
    mout_t1="$("$BASH_BIN" "$mut" 2>&1)"; mrc_t1=$?
    # Assert: specific message is absent (proves the message assertion in case 20 has teeth).
    # Exit code may still be non-zero (via target_paths_pairs guard) — that is expected and correct.
    if ! grep -q 'failed to define target_paths_all' <<<"$mout_t1"; then
      ok "teeth VR-T1: guard-neutered mutant lacks 'failed to define target_paths_all' msg (case 20 msg-assertion has teeth)" "(exit $mrc_t1)"
    else
      no "teeth VR-T1: mutant STILL has 'failed to define target_paths_all' msg — case 20 msg-assertion is THEATER" "rc=$mrc_t1 out=[$mout_t1]"
    fi
  fi

  # teeth-VR-T2: remove RESEARCH_HOME expansion → case 21 goes RED (reconciled 0 targets, not 1).
  echo "-- teeth VR-T2: strip RESEARCH_HOME expansion; case 21 must show 0 targets reconciled --"
  kit="$(mkkit teeth-vr-t2)"
  _rh_base_vt2="$ROOT/rh_vt2_$$"
  mkdir -p "$_rh_base_vt2"
  tgt="$_rh_base_vt2/rh_corpus"
  mkcorpus "$tgt" 4 "r"
  { printf '# targets\n\n| # | name | maturity | path |\n|---|---|---|---|\n'
    printf '| 1 | t1 | mature (4 md / git yes / hook yes) | `$RESEARCH_HOME/rh_corpus` |\n'
  } > "$kit/TARGETS.md"
  # The stripped helper defines both functions so verify-registry.sh gets past the declare-F
  # guards. Neither function handles $RESEARCH_HOME paths (Form 1 only: absolute `/` paths).
  # With the $RESEARCH_HOME path in TARGETS.md, all_pairs is empty → zero-paths guard fires.
  cat > "$kit/toolbelt/lib/target-paths.sh" <<'VRT2STRIPPED'
#!/usr/bin/env bash
if ! declare -F target_paths_all >/dev/null 2>&1; then
  target_paths_all() {
    local f="${1:-}"
    [ -n "$f" ] || return 0
    [ -f "$f" ] || { echo "target-paths: cannot read ${f}" >&2; return 1; }
    grep -oE '`/[^`]+`' "$f" 2>/dev/null | tr -d '`' | sort -u
  }
fi
if ! declare -F target_paths_pairs >/dev/null 2>&1; then
  target_paths_pairs() {
    local f="${1:-}"
    [ -n "$f" ] || return 0
    [ -f "$f" ] || { echo "target-paths: cannot read ${f}" >&2; return 1; }
    grep -oE '`/[^`]+`' "$f" 2>/dev/null | tr -d '`' | awk '{print $0 "\t" $0}' | sort -u
  }
fi
VRT2STRIPPED
  mout_t2="$(RESEARCH_HOME="$_rh_base_vt2" "$BASH_BIN" "$kit/toolbelt/verify-registry.sh" 2>&1)"; mrc_t2=$?
  unset _rh_base_vt2
  # Without RESEARCH_HOME expansion, all_pairs yields nothing for the $RESEARCH_HOME/rh_corpus row →
  # zero-paths guard fires (ERROR, no Summary). Case 21 expects 'reconciled 1 target'; this mutant
  # cannot reach it — confirming case 21 depends on RESEARCH_HOME expansion in target_paths_pairs.
  if ! grep -q 'reconciled 1 target' <<<"$mout_t2"; then
    ok "teeth VR-T2: stripped mutant does not reconcile 1 target → case 21 has teeth" "()"
  else
    no "teeth VR-T2: stripped mutant still reconciled 1 target — case 21 is THEATER" "rc=$mrc_t2 out=[$mout_t2]"
  fi

  # teeth-VR-T3: remove the zero-paths guard → case 22 must lose its specific "no usable target
  # paths" message. With the guard removed, the script now hits the ALL-ABSENT-CHECK (dir_reached=0
  # after the empty-paths loop) → exits 1, emitting a different ERROR. Test 22 asserts exit 0 +
  # the specific "no usable target paths" message; both fail on this mutant → test 22 has teeth.
  echo "-- teeth VR-T3: remove zero-paths guard; 'no usable target paths' msg must vanish (case 22 has teeth) --"
  _vr_zp_anchor='if \[ -z "\$paths" \]; then'
  if ! grep -qE "$_vr_zp_anchor" "$SUT"; then
    no "teeth VR-T3: locate zero-paths guard in SUT" "anchor not found — SUT drifted?"
  else
    kit="$(mkkit teeth-vr-t3)"
    printf '# targets\n\n| # | name | path |\n|---|---|---|\n| 1 | t1 | /no/backticks |\n' \
      > "$kit/TARGETS.md"
    sed '/if \[ -z "\$paths" \]/,/^fi$/d' "$SUT" > "$kit/toolbelt/verify-registry.sh"
    mout_t3="$("$BASH_BIN" "$kit/toolbelt/verify-registry.sh" 2>&1)"; mrc_t3=$?
    # The mutant no longer emits "no usable target paths" (zero-paths guard gone); instead
    # ALL-ABSENT-CHECK fires. Test 22's `[ "$RC" = 0 ]` and specific-message assertions both fail.
    if ! grep -qi 'ERROR.*no usable target paths' <<<"$mout_t3"; then
      ok "teeth VR-T3: guard-removed mutant lacks 'no usable target paths' msg (case 22 has teeth)" "(exit $mrc_t3)"
    else
      no "teeth VR-T3: guard-removed mutant still shows 'no usable target paths' msg — case 22 has no teeth" "rc=$mrc_t3 out=[$mout_t3]"
    fi
  fi

  # teeth-kit-self-reg: neuter the KIT-SELF-REG-CHECK (kit-sup #6 gate); the kit-absent fixture
  # (test 25) must STOP emitting the self-reg WARN, proving the assertion is load-bearing.
  echo "-- teeth-kit-self-reg: neuter KIT-SELF-REG-CHECK; kit-absent fixture must NOT WARN --"
  kit="$(mkkit teeth-kit-self-reg)"; tgt="$kit/targetA"
  mkcorpus "$tgt" 3 "a"
  write_targets "$kit" "$tgt::3 md"   # kit dir NOT in TARGETS.md (same fixture as test 25)
  mut="$kit/toolbelt/verify-registry.sh"
  if grep -q '# KIT-SELF-REG-CHECK' "$mut"; then
    sed -i '/# KIT-SELF-REG-CHECK/ s/.*/  : # KIT-SELF-REG-CHECK [NEUTERED]/' "$mut"
    mout_ksr="$("$BASH_BIN" "$mut" 2>&1)"; mrc_ksr=$?
    if [ "$mrc_ksr" = 0 ] && ! grep -qiE 'kit repo is NOT in its own TARGETS' <<<"$mout_ksr"; then
      ok "teeth-kit-self-reg: neutered gate → kit-absent fixture emits NO self-reg WARN (test 25 has teeth)" "(exit $mrc_ksr)"
    else
      no "teeth-kit-self-reg: neutered mutant STILL emits self-reg WARN → test 25 is THEATER" "mrc=$mrc_ksr mout=[$mout_ksr]"
    fi
  else
    no "teeth-kit-self-reg: KIT-SELF-REG-CHECK sentinel not found in SUT (gate not implemented or marker missing)"
  fi

  # teeth-rh-rowlookup: neuter the raw-token lookup (identified by # RH-ROW-LOOKUP sentinel in the
  # SUT). With the lookup neutered, raw_p="" → fallback to expanded path → grep misses the raw
  # `$RESEARCH_HOME/...` form in TARGETS.md → claimed="" → "no claimed" WARN fires → test 23 RED.
  echo "-- teeth-rh-rowlookup: neuter RH-ROW-LOOKUP; \$RESEARCH_HOME row must fire 'no claimed' WARN --"
  kit="$(mkkit teeth-rh-rowlookup)"
  _rh_base_teeth23="$ROOT/rh_teeth23_$$"
  mkdir -p "$_rh_base_teeth23"
  tgt="$_rh_base_teeth23/rh_corpus"
  mkcorpus "$tgt" 5 "r"
  { printf '# targets\n\n| # | name | maturity | path |\n|---|---|---|---|\n'
    printf '| 1 | t1 | mature (5 md / git yes / hook yes) | `$RESEARCH_HOME/rh_corpus` |\n'
  } > "$kit/TARGETS.md"
  mut="$kit/toolbelt/verify-registry.sh"
  if grep -q '# RH-ROW-LOOKUP' "$mut"; then
    sed -i '/# RH-ROW-LOOKUP/ s/.*/  raw_p=""  # RH-ROW-LOOKUP [MUTATED]/' "$mut"
    mout_t23="$(RESEARCH_HOME="$_rh_base_teeth23" "$BASH_BIN" "$mut" 2>&1)"; mrc_t23=$?
    unset _rh_base_teeth23
    if [ "$mrc_t23" = 0 ] && grep -qE 'no claimed.*md.*count' <<<"$mout_t23"; then
      ok "teeth-rh-rowlookup: neutered lookup → 'no claimed' WARN fires (test 23 has teeth)" "(exit $mrc_t23)"
    else
      no "teeth-rh-rowlookup: neutered mutant did NOT fire 'no claimed' WARN — test 23 has no teeth" "mrc=$mrc_t23 mout=[$mout_t23]"
    fi
  else
    no "teeth-rh-rowlookup: RH-ROW-LOOKUP sentinel not found in SUT (fix not implemented or marker missing)"
    unset _rh_base_teeth23
  fi

  # teeth-catalog-disc-zero: neuter the CATALOG-DISC-ZERO sentinel; the disc=0 fixture (bare
  # block<N>.md files, CATALOG=5) must STOP emitting the two-candidate reconciliation WARN —
  # proving test 30 depends on the real disc-zero branch and is not vacuously green.
  echo "-- teeth-catalog-disc-zero: neuter CATALOG-DISC-ZERO; disc=0 fixture must NOT WARN about reconciliation --"
  kit="$(mkkit teeth-cat-disc-zero)"; tgt="$kit/targetA"
  mkdir -p "$tgt"
  printf '# state\n\n<!-- research-state.v1 -->\ncovered_blocks: 5\n<!-- /research-state.v1 -->\n' \
    > "$tgt/RESEARCH-STATE.md"
  for i in $(seq 1 5); do printf '# Block %d\n' "$i" > "$tgt/block${i}.md"; done
  mkdir -p "$tgt/tools"; printf '#!/usr/bin/env python3\n# gen-catalog\n' > "$tgt/tools/gen-catalog.py"
  printf '# Catalogo\n\nTotal: **5 bloques**\n' > "$tgt/CATALOG.md"
  write_targets "$kit" "$tgt::5 md"
  mut="$kit/toolbelt/verify-registry.sh"
  if grep -q '# CATALOG-DISC-ZERO' "$mut"; then
    sed -i '/# CATALOG-DISC-ZERO/ s/.*/        : # CATALOG-DISC-ZERO [MUTATED]/' "$mut"
    mout="$("$BASH_BIN" "$mut" 2>&1)"; mrc=$?
    if [ "$mrc" = 0 ] && ! grep -q 'non-canonical block naming' <<<"$mout"; then
      ok "teeth-catalog-disc-zero: neutered → disc=0 fixture emits NO two-candidate WARN (test 30 has teeth)" "(exit $mrc)"
    else
      no "teeth-catalog-disc-zero: neutered mutant STILL emits two-candidate WARN → test 30 is THEATER" "mrc=$mrc mout=[$mout]"
    fi
  else
    no "teeth-catalog-disc-zero: CATALOG-DISC-ZERO sentinel not found in SUT (disc-zero branch not implemented or marker missing)"
  fi

  # teeth-catalog-freshness: neuter the CATALOG-FRESHNESS-CHECK sentinel on the stale-WARN echo
  # line; the stale fixture (disc=8, CATALOG=5, diff=3>tol=2) must STOP emitting the freshness WARN
  # — proving test 27 is load-bearing and not vacuously green.
  echo "-- teeth-catalog-freshness: neuter CATALOG-FRESHNESS-CHECK; stale fixture must NOT WARN about staleness --"
  kit="$(mkkit teeth-cat-fresh)"; tgt="$kit/targetA"
  mkcorpus "$tgt" 8 "a"
  mkdir -p "$tgt/tools"; printf '#!/usr/bin/env python3\n# gen-catalog\n' > "$tgt/tools/gen-catalog.py"
  printf '# Catalogo\n\nTotal: **5 bloques**\n' > "$tgt/CATALOG.md"
  write_targets "$kit" "$tgt::5 md"
  mut="$kit/toolbelt/verify-registry.sh"
  if grep -q '# CATALOG-FRESHNESS-CHECK' "$mut"; then
    sed -i '/# CATALOG-FRESHNESS-CHECK/ s/.*/        : # CATALOG-FRESHNESS-CHECK [MUTATED]/' "$mut"
    mout="$("$BASH_BIN" "$mut" 2>&1)"; mrc=$?
    if [ "$mrc" = 0 ] && ! grep -q 'CATALOG may be stale' <<<"$mout"; then
      ok "teeth-catalog-freshness: neutered check → stale fixture emits NO freshness WARN (test 27 has teeth)" "(exit $mrc)"
    else
      no "teeth-catalog-freshness: neutered check STILL emits freshness WARN → test 27 is THEATER" "mrc=$mrc mout=[$mout]"
    fi
  else
    no "teeth-catalog-freshness: CATALOG-FRESHNESS-CHECK sentinel not found in SUT (freshness check not implemented or marker missing)"
  fi

  # teeth-kit-parent-match: remove the || [...$_kit_parent...] branch from the gate; a kit
  # registered via its repo root (dirname $KIT) must fire the self-reg WARN again — proving
  # test 26 depends on the real parent-dir check and is not vacuously green.
  echo "-- teeth-kit-parent-match: neuter parent-dir match; repo-root registration must re-WARN --"
  repo26t="$ROOT/c26t-repo"
  kit26t="$repo26t/research-sdd"
  mkdir -p "$kit26t/toolbelt/lib" "$repo26t"
  cp "$SUT" "$kit26t/toolbelt/verify-registry.sh"
  cp "$LIB" "$kit26t/toolbelt/lib/retro-status.sh"
  cp "$TP_LIB" "$kit26t/toolbelt/lib/target-paths.sh"
  { printf '# targets\n\n| # | name | maturity | path |\n|---|---|---|---|\n'
    printf '| 1 | sdd-investigacion | intermediate (0 md / nc / git yes) | `%s` |\n' "$repo26t"
  } > "$kit26t/TARGETS.md"
  mut26t="$kit26t/toolbelt/verify-registry.sh"
  if grep -qF '# KIT-PARENT-MATCH' "$mut26t"; then
    sed -i 's/ || \[ "$_rv_expanded" = "$_kit_parent" \]//' "$mut26t"
    mout26t="$("$BASH_BIN" "$mut26t" 2>&1)"; mrc26t=$?
    if [ "$mrc26t" = 0 ] && grep -qiE 'kit repo is NOT in its own TARGETS' <<<"$mout26t"; then
      ok "teeth-kit-parent-match: neutered → repo-root registration fires WARN (test 26 has teeth)" "(exit $mrc26t)"
    else
      no "teeth-kit-parent-match: mutant did NOT fire self-reg WARN — test 26 has no teeth" "mrc=$mrc26t mout=[$mout26t]"
    fi
  else
    no "teeth-kit-parent-match: KIT-PARENT-MATCH sentinel not found in SUT"
  fi
fi

# 27 — CATALOG-FRESHNESS STALE: gen-catalog.py + CATALOG.md present; CATALOG claims 5 but
#      discriminator counts 8 (diff 3 > tol 2) → freshness WARN fires naming the counts + diff.
#      WARN-only: drift comparison (claimed=5 vs CATALOG=5) still passes → exit 0, no drift WARN.
kit="$(mkkit c27-catalog-stale)"; tgt="$kit/targetA"
mkcorpus "$tgt" 8 "a"   # 8 real block files → discriminator=8
mkdir -p "$tgt/tools"; printf '#!/usr/bin/env python3\n# gen-catalog\n' > "$tgt/tools/gen-catalog.py"
printf '# Catalogo\n\nTotal: **5 bloques**\n' > "$tgt/CATALOG.md"   # CATALOG claims 5 (stale)
write_targets "$kit" "$tgt::5 md"   # claim matches the (stale) CATALOG total
run "$kit"
if [ "$RC" = 0 ] \
   && grep -qE 'WARN[[:space:]]+targetA.*CATALOG.*5.*discriminator 8' <<<"$OUT" \
   && grep -q 'CATALOG may be stale' <<<"$OUT" \
   && ! grep -qE 'WARN[[:space:]]+targetA.*refresh the row' <<<"$OUT"; then
  ok "27 stale CATALOG (disc=8 vs CATALOG=5, diff 3>tol) → freshness WARN, no drift WARN, exit 0" "(exit $RC)"
else
  no "27 stale CATALOG (disc=8 vs CATALOG=5, diff 3>tol) → freshness WARN, no drift WARN, exit 0" "exit=$RC out=[$OUT]"
fi

# 28 — CATALOG-FRESHNESS FRESH: gen-catalog.py + CATALOG.md present; CATALOG claims 6 and
#      discriminator counts 5 (diff 1 ≤ tol 2) → NO freshness WARN fires; drift=0, consistent.
#      Negative control: a within-tolerance difference must NOT trigger a staleness alarm.
kit="$(mkkit c28-catalog-fresh)"; tgt="$kit/targetA"
mkcorpus "$tgt" 5 "a"   # 5 real block files → discriminator=5
mkdir -p "$tgt/tools"; printf '#!/usr/bin/env python3\n# gen-catalog\n' > "$tgt/tools/gen-catalog.py"
printf '# Catalogo\n\nTotal: **6 bloques**\n' > "$tgt/CATALOG.md"   # diff=1 ≤ tol=2 → fresh
write_targets "$kit" "$tgt::6 md"   # claim matches CATALOG total
run "$kit"
if [ "$RC" = 0 ] \
   && ! grep -q 'CATALOG may be stale' <<<"$OUT" \
   && ! grep -q 'freshness undeterminable' <<<"$OUT" \
   && grep -q '0 count drift' <<<"$OUT" \
   && grep -q 'Registry consistent with reality' <<<"$OUT"; then
  ok "28 fresh CATALOG (disc=5 vs CATALOG=6, diff 1≤tol) → no freshness WARN, drift=0" "(exit $RC)"
else
  no "28 fresh CATALOG (disc=5 vs CATALOG=6, diff 1≤tol) → no freshness WARN, drift=0" "exit=$RC out=[$OUT]"
fi

# 29 — CATALOG-FRESHNESS UNDETERMINABLE: gen-catalog.py present + CATALOG.md present but CATALOG
#      has no parseable total → freshness-undeterminable WARN fires; discriminator count is used.
#      The four states (absent/fresh/stale/undeterminable) must all produce distinct output.
kit="$(mkkit c29-catalog-noparse)"; tgt="$kit/targetA"
mkcorpus "$tgt" 5 "a"   # 5 real block files → discriminator=5
mkdir -p "$tgt/tools"; printf '#!/usr/bin/env python3\n# gen-catalog\n' > "$tgt/tools/gen-catalog.py"
printf '# Catalogo\n\n(no total line here)\n' > "$tgt/CATALOG.md"   # no parseable total
write_targets "$kit" "$tgt::5 md"   # claim matches discriminator → no drift
run "$kit"
if [ "$RC" = 0 ] \
   && grep -q 'freshness undeterminable' <<<"$OUT" \
   && ! grep -q 'CATALOG may be stale' <<<"$OUT" \
   && ! grep -qE 'WARN[[:space:]]+targetA.*refresh the row' <<<"$OUT"; then
  ok "29 CATALOG no parseable total → freshness-undeterminable WARN, no drift WARN, exit 0" "(exit $RC)"
else
  no "29 CATALOG no parseable total → freshness-undeterminable WARN, no drift WARN, exit 0" "exit=$RC out=[$OUT]"
fi

# 30 — CATALOG-DISC-ZERO: gen-catalog.py + CATALOG.md present; discriminator finds 0 (bare
#      block<N>.md, no canonical <prefix>- component) while CATALOG claims 5. WARN must name BOTH
#      candidate causes (non-canonical naming + stale CATALOG) and must NOT assert "CATALOG may be
#      stale" alone. The unclassifiable guard must also fire, providing file-level evidence.
#      No drift WARN (claimed=5 matches CATALOG=5). Exit 0.
#      RED before fix: current code emits "CATALOG may be stale" (wrong cause) and suppresses
#      the unclassifiable guard by setting cat_authority (wrong evidence chain).
kit="$(mkkit c30-catalog-disc-zero)"; tgt="$kit/targetA"
mkdir -p "$tgt"
printf '# state\n\n<!-- research-state.v1 -->\ncovered_blocks: 5\n<!-- /research-state.v1 -->\n' \
  > "$tgt/RESEARCH-STATE.md"
for i in $(seq 1 5); do printf '# Block %d\n' "$i" > "$tgt/block${i}.md"; done  # bare naming, not canonical
mkdir -p "$tgt/tools"; printf '#!/usr/bin/env python3\n# gen-catalog\n' > "$tgt/tools/gen-catalog.py"
printf '# Catalogo\n\nTotal: **5 bloques**\n' > "$tgt/CATALOG.md"
write_targets "$kit" "$tgt::5 md"
run "$kit"
if [ "$RC" = 0 ] \
   && grep -q 'non-canonical block naming' <<<"$OUT" \
   && ! grep -q 'CATALOG may be stale' <<<"$OUT" \
   && grep -qE 'WARN[[:space:]]+targetA.*unclassifiable' <<<"$OUT" \
   && ! grep -qE 'WARN[[:space:]]+targetA.*refresh the row' <<<"$OUT"; then
  ok "30 disc=0 vs CATALOG=5 → both-candidate WARN, unclassifiable fires, no drift WARN, exit 0" "(exit $RC)"
else
  no "30 disc=0 vs CATALOG=5 → both-candidate WARN, unclassifiable fires, no drift WARN, exit 0" "exit=$RC out=[$OUT]"
fi

# ---- RETRO RECONCILIATION + MATURITY CELL SCHEMA VALIDATION -----------------------------------------
# Tests 31–36: new functionality added in the registry-maturity-schema work unit.
# Helper: write a TARGETS.md row with an explicit maturity parenthetical (claim is the full parens
# content, not just the block count), so retro fields and unknown fields can be injected precisely.
# write_targets_custom <kit> <target> <paren_content>
write_targets_custom() {
  local kit="$1" tgt="$2" paren="$3"
  { printf '# targets\n\n| # | name | maturity | path |\n|---|---|---|---|\n'
    printf '| 1 | targetA | mature (%s) | `%s` |\n' "$paren" "$tgt"
  } > "$kit/TARGETS.md"
}

# 31 — RETRO-MATCH: row declares N retros that matches the real non-excluded count → no retro WARN.
kit="$(mkkit c31-retro-match)"; tgt="$kit/targetA"
mkcorpus "$tgt" 4 "a"
mkdir -p "$tgt/retros"
printf '# retro 1\nbody\n' > "$tgt/retros/2026-01-01.md"
printf '# retro 2\nbody\n' > "$tgt/retros/2026-01-02.md"
write_targets_custom "$kit" "$tgt" "4 md / 2 retros / git yes / hook yes"
run "$kit"
if [ "$RC" = 0 ] && ! grep -qiE 'WARN[[:space:]]+targetA.*retro' <<<"$OUT"; then
  ok "31 retro declared, matches disk (2==2) → no retro WARN" "(exit $RC)"
else
  no "31 retro declared, matches disk (2==2) → no retro WARN" "exit=$RC out=[$OUT]"
fi

# 32 — RETRO-DRIFT: row claims N retros but the real count differs → WARN naming both counts, exit 0.
kit="$(mkkit c32-retro-drift)"; tgt="$kit/targetA"
mkcorpus "$tgt" 4 "a"
mkdir -p "$tgt/retros"
for i in 1 2 3 4 5; do printf '# retro %d\nbody\n' "$i" > "$tgt/retros/2026-01-0${i}.md"; done
write_targets_custom "$kit" "$tgt" "4 md / 2 retros / git yes / hook yes"
run "$kit"
if [ "$RC" = 0 ] \
   && grep -qiE 'WARN[[:space:]]+targetA.*2 retro.*5 non-excluded|WARN[[:space:]]+targetA.*5 non-excluded.*2 retro' <<<"$OUT"; then
  ok "32 retro claimed 2 vs real 5 → WARN naming both, exit 0" "(exit $RC)"
else
  no "32 retro claimed 2 vs real 5 → WARN naming both, exit 0" "exit=$RC out=[$OUT]"
fi

# 33 — RETRO-ABSENT: no retro field in the cell → no retro WARN (absent is legal, not a violation).
kit="$(mkkit c33-retro-absent)"; tgt="$kit/targetA"
mkcorpus "$tgt" 4 "a"
mkdir -p "$tgt/retros"
printf '# retro\nbody\n' > "$tgt/retros/2026-01-01.md"
write_targets_custom "$kit" "$tgt" "4 md / git yes / hook yes"
run "$kit"
if [ "$RC" = 0 ] && ! grep -qiE 'WARN[[:space:]]+targetA.*retro' <<<"$OUT"; then
  ok "33 no retro field in cell → no retro WARN (absent is legal)" "(exit $RC)"
else
  no "33 no retro field in cell → no retro WARN (absent is legal)" "exit=$RC out=[$OUT]"
fi

# 34 — RETRO-MALFORMED: cell contains a retro-shaped token that is not 'N retros' →
#      surfaced as non-conforming field WARN (distinct from case 33's silence for absent).
#      'retros: many' does not match ^[0-9]+ retros? and is not any other known pattern.
kit="$(mkkit c34-retro-malformed)"; tgt="$kit/targetA"
mkcorpus "$tgt" 4 "a"
write_targets_custom "$kit" "$tgt" "4 md / retros: many / git yes / hook yes"
run "$kit"
if [ "$RC" = 0 ] && grep -qiE "WARN[[:space:]]+targetA.*not in schema.*retros: many" <<<"$OUT"; then
  ok "34 malformed retro token 'retros: many' → non-conforming WARN (distinct from absent)" "(exit $RC)"
else
  no "34 malformed retro token 'retros: many' → non-conforming WARN (distinct from absent)" "exit=$RC out=[$OUT]"
fi

# 34b — BLOCK-VARIANT ACCEPTANCE: 'N md', 'N blocks', 'N blocks @date' must all be accepted
#       without triggering a non-conforming field WARN. None should generate a schema WARN.
kit="$(mkkit c34b-block-variants)"; tgt="$kit/targetA"
mkcorpus "$tgt" 4 "a"
# Three sub-cases: each as its own TARGETS.md. Share the same kit/corpus, rewrite TARGETS.md.
write_targets_custom "$kit" "$tgt" "4 md / git yes / hook yes"
run "$kit"; md_ok=0; [ "$RC" = 0 ] && ! grep -qiE 'not in schema' <<<"$OUT" && md_ok=1
write_targets_custom "$kit" "$tgt" "4 blocks / git yes / hook yes"
run "$kit"; blocks_ok=0; [ "$RC" = 0 ] && ! grep -qiE 'not in schema' <<<"$OUT" && blocks_ok=1
write_targets_custom "$kit" "$tgt" "4 blocks @2026-07-30 / git yes / hook yes"
run "$kit"; date_ok=0; [ "$RC" = 0 ] && ! grep -qiE 'not in schema' <<<"$OUT" && date_ok=1
if [ "$md_ok" = 1 ] && [ "$blocks_ok" = 1 ] && [ "$date_ok" = 1 ]; then
  ok "34b block variants (N md / N blocks / N blocks @date) → all accepted, no schema WARN" "(all 3 sub-cases)"
else
  no "34b block variants → not all accepted" "md=$md_ok blocks=$blocks_ok date=$date_ok"
fi

# 35 — UNKNOWN-FIELD: a maturity cell token that matches no known schema pattern is surfaced
#      verbatim in a WARN. The token 'widget yes' is not block/run/retro/git/remote/hook/nc/…
kit="$(mkkit c35-unknown-field)"; tgt="$kit/targetA"
mkcorpus "$tgt" 4 "a"
write_targets_custom "$kit" "$tgt" "4 md / widget yes / git yes / hook yes"
run "$kit"
if [ "$RC" = 0 ] && grep -qiE "WARN[[:space:]]+targetA.*not in schema.*widget yes" <<<"$OUT"; then
  ok "35 unknown field 'widget yes' → non-conforming WARN verbatim" "(exit $RC)"
else
  no "35 unknown field 'widget yes' → non-conforming WARN verbatim" "exit=$RC out=[$OUT]"
fi

# 36 — EXCLUDED-RETROS-NOT-COUNTED: row claims 1 retro; disk has 1 real + 1 excluded → only the
#      real one counts → declared count matches → NO drift WARN. Proves excluded retros are filtered.
kit="$(mkkit c36-excluded-retro)"; tgt="$kit/targetA"
mkcorpus "$tgt" 4 "a"
mkdir -p "$tgt/retros"
printf '# real retro\nbody\n' > "$tgt/retros/2026-01-01-real.md"
printf '<!-- kit-retro: exclude -->\n# client retro\nbody\n' > "$tgt/retros/2026-01-02-client.md"
write_targets_custom "$kit" "$tgt" "4 md / 1 retros / git yes / hook yes"
run "$kit"
if [ "$RC" = 0 ] && ! grep -qiE 'WARN[[:space:]]+targetA.*retro' <<<"$OUT"; then
  ok "36 excluded retro not counted: 1 real + 1 excluded vs claim 1 → no drift WARN" "(exit $RC)"
else
  no "36 excluded retro not counted: 1 real + 1 excluded vs claim 1 → no drift WARN" "exit=$RC out=[$OUT]"
fi

# 37 — BLOCKING 1 (last-position token): garbage in the LAST cell token must fire the schema
#      WARN. The tokenizer bug (`printf '%s'` without trailing newline) causes `read` to return
#      non-zero for the unterminated last line, silently dropping it.
#      RED before fix: 'mature (4 md / git yes / ABSOLUTE NONSENSE LAST TOKEN)' emits NO WARN.
kit="$(mkkit c37-last-token)"; tgt="$kit/targetA"
mkcorpus "$tgt" 4 "a"
write_targets_custom "$kit" "$tgt" "4 md / git yes / ABSOLUTE NONSENSE LAST TOKEN"
run "$kit"
if [ "$RC" = 0 ] && grep -qiE "WARN[[:space:]]+targetA.*not in schema.*ABSOLUTE NONSENSE LAST TOKEN" <<<"$OUT"; then
  ok "37 garbage in LAST position → schema WARN fires (tokenizer last-token fix)" "(exit $RC)"
else
  no "37 garbage in LAST position → NO schema WARN (tokenizer drops last token — BLOCKING 1)" "exit=$RC out=[$OUT]"
fi

# 38 — BLOCKING 1 (single-token cell): a cell with exactly ONE garbage token must also be
#      caught. With the bug, even a single-token cell is silently dropped because `printf '%s'`
#      emits no trailing newline, making `read` fail immediately and skip the loop body.
kit="$(mkkit c38-single-token)"; tgt="$kit/targetA"
mkcorpus "$tgt" 4 "a"
write_targets_custom "$kit" "$tgt" "COMPLETE GARBAGE ONLY TOKEN"
run "$kit"
if [ "$RC" = 0 ] && grep -qiE "WARN[[:space:]]+targetA.*not in schema.*COMPLETE GARBAGE" <<<"$OUT"; then
  ok "38 single garbage token → schema WARN fires (tokenizer single-token fix)" "(exit $RC)"
else
  no "38 single garbage token → NO schema WARN (tokenizer drops single token — BLOCKING 1)" "exit=$RC out=[$OUT]"
fi

# 39 — BLOCKING 2 (unreadable retros dir): a target whose retros/ dir exists but is chmod 000
#      must produce an OPERATIONAL WARN about inaccessibility, not a false retro count drift.
#      RED before fix: find ... 2>/dev/null silently returns 0 retros → false 'claims N but 0' drift.
kit="$(mkkit c39-unreadable-retros)"; tgt="$kit/targetA"
mkcorpus "$tgt" 4 "a"
mkdir -p "$tgt/retros"
printf '# real retro 1\nbody\n' > "$tgt/retros/2026-01-01.md"
printf '# real retro 2\nbody\n' > "$tgt/retros/2026-01-02.md"
write_targets_custom "$kit" "$tgt" "4 md / 2 retros / git yes / hook yes"
chmod 000 "$tgt/retros"
run "$kit"
chmod 755 "$tgt/retros"   # restore so cleanup works
if [ "$RC" = 0 ] \
   && grep -qiE 'WARN[[:space:]]+targetA.*(not accessible|permission)' <<<"$OUT" \
   && ! grep -qiE 'WARN[[:space:]]+targetA.*[0-9]+ retro.*found' <<<"$OUT"; then
  ok "39 unreadable retros/ → operational WARN, no false count drift (BLOCKING 2)" "(exit $RC)"
else
  no "39 unreadable retros/ → expected operational WARN but got false drift (BLOCKING 2 unfixed)" "exit=$RC out=[$OUT]"
fi

# 40 — MAJOR 4 (maxdepth 4): retro at depth 3 (<target>/research/retros/*.md) must be found.
#      RED before fix: maxdepth 2 only reaches depth-2 retros; depth-3 retros are invisible.
kit="$(mkkit c40-retro-depth3)"; tgt="$kit/targetA"
mkcorpus "$tgt/research" 4 "a"   # corpus at depth 1 (research/); RESEARCH-STATE.md is there
mkdir -p "$tgt/research/retros"
printf '# retro at depth 3\nbody\n' > "$tgt/research/retros/2026-01-01.md"
write_targets_custom "$kit" "$tgt" "4 md / 1 retros / git yes / hook yes"
run "$kit"
if [ "$RC" = 0 ] && ! grep -qiE 'WARN[[:space:]]+targetA.*retro' <<<"$OUT"; then
  ok "40 retro at depth 3 (research/retros/) → found (maxdepth 4), no drift WARN" "(exit $RC)"
else
  no "40 retro at depth 3 → NOT found (maxdepth 2 misses it — MAJOR 4 unfixed)" "exit=$RC out=[$OUT]"
fi

# 41 — BLOCKING 3 (anchored retro pattern): trailing garbage after 'N retros' must trigger NONCONFORM.
#      Unanchored '^[0-9]+[[:space:]]+retros?' passes '3 retrograde motion'.
kit="$(mkkit c41-retro-anchor)"; tgt="$kit/targetA"
mkcorpus "$tgt" 4 "a"
write_targets_custom "$kit" "$tgt" "4 md / 3 retrograde motion / git yes / hook yes"
run "$kit"
if [ "$RC" = 0 ] && grep -qiE "WARN[[:space:]]+targetA.*not in schema.*retrograde" <<<"$OUT"; then
  ok "41 '3 retrograde motion' → schema WARN fires (anchored retro pattern)" "(exit $RC)"
else
  no "41 '3 retrograde motion' → no WARN (unanchored retro pattern — BLOCKING 3)" "exit=$RC out=[$OUT]"
fi

# 42 — BLOCKING 3 (anchored block @date pattern): loose '(@.*)?' passes garbage after @.
#      '4 md @garbage not a date' must trigger NONCONFORM.
kit="$(mkkit c42-block-date-anchor)"; tgt="$kit/targetA"
mkcorpus "$tgt" 4 "a"
write_targets_custom "$kit" "$tgt" "4 md @garbage not a date / git yes / hook yes"
run "$kit"
if [ "$RC" = 0 ] && grep -qiE "WARN[[:space:]]+targetA.*not in schema" <<<"$OUT"; then
  ok "42 block '@garbage not a date' → schema WARN fires (tightened @date pattern)" "(exit $RC)"
else
  no "42 block '@garbage not a date' → no WARN (loose @date pattern — BLOCKING 3)" "exit=$RC out=[$OUT]"
fi

# 42b — BLOCKING 3 negative control: valid @date forms must still pass after pattern tightening.
#       'N blocks @YYYY-MM-DD' and 'N blocks @YYYY-MM-DD, ACTIVE' both documented in the legend.
kit="$(mkkit c42b-block-date-ok)"; tgt="$kit/targetA"
mkcorpus "$tgt" 4 "a"
mkdir -p "$tgt/retros"; printf '# retro\nbody\n' > "$tgt/retros/2026-01-01.md"
write_targets_custom "$kit" "$tgt" "4 blocks @2026-07-30 / git yes / hook yes"
run "$kit"; date_ok=0
[ "$RC" = 0 ] && ! grep -qiE 'not in schema' <<<"$OUT" && date_ok=1
write_targets_custom "$kit" "$tgt" "4 blocks @2026-07-30, ACTIVE / git yes / hook yes"
run "$kit"; active_ok=0
[ "$RC" = 0 ] && ! grep -qiE 'not in schema' <<<"$OUT" && active_ok=1
if [ "$date_ok" = 1 ] && [ "$active_ok" = 1 ]; then
  ok "42b valid @date and @date,ACTIVE → both accepted, no schema WARN" "(date=$date_ok active=$active_ok)"
else
  no "42b valid @date forms → not all accepted after pattern tightening" "date=$date_ok active=$active_ok out=[$OUT]"
fi

# 43 — MINOR 5 (singular focus): '1 focus' must be accepted without a schema WARN.
#      Pattern 'focuses?' expands to 'focuse?' (matches 'focuse' or 'focuses'), NOT 'focus'.
kit="$(mkkit c43-singular-focus)"; tgt="$kit/targetA"
mkcorpus "$tgt" 4 "a"
mkdir -p "$tgt/retros"; printf '# retro\nbody\n' > "$tgt/retros/2026-01-01.md"
write_targets_custom "$kit" "$tgt" "4 md / 1 focus / git yes / hook yes"
run "$kit"
if [ "$RC" = 0 ] && ! grep -qiE "WARN[[:space:]]+targetA.*not in schema.*focus" <<<"$OUT"; then
  ok "43 '1 focus' (singular) → accepted, no schema WARN (MINOR 5 fix)" "(exit $RC)"
else
  no "43 '1 focus' (singular) → schema WARN fires (pattern 'focuses?' misses singular — MINOR 5)" "exit=$RC out=[$OUT]"
fi

# 44 — MINOR 6 (separate retro drift counter): a retro drift must appear in the summary as
#      'N retro drift(s)', not as a count drift. Before fix, retro_drift increments `drift`.
kit="$(mkkit c44-retro-drift-counter)"; tgt="$kit/targetA"
mkcorpus "$tgt" 4 "a"
mkdir -p "$tgt/retros"
for i in 1 2 3; do printf '# retro %d\nbody\n' "$i" > "$tgt/retros/2026-01-0${i}.md"; done
write_targets_custom "$kit" "$tgt" "4 md / 1 retros / git yes / hook yes"
run "$kit"
if [ "$RC" = 0 ] \
   && grep -q '0 count drift' <<<"$OUT" \
   && grep -q '1 retro drift' <<<"$OUT"; then
  ok "44 retro drift → 0 count drift + 1 retro drift in summary (separate counters)" "(exit $RC)"
else
  no "44 retro drift → separate retro drift counter missing in summary (MINOR 6)" "exit=$RC out=[$OUT]"
fi

# ---- TEETH for new cases -----------------------------------------------------------------------
if [ "${1:-}" = "--prove-teeth" ]; then
  # teeth-retro-drift: neuter RETRO-DRIFT-CHECK sentinel; drift fixture (real=5, claim=2) must
  # stop emitting the WARN → proves test 32's WARN assertion is load-bearing.
  echo "-- teeth-retro-drift: neuter RETRO-DRIFT-CHECK; drift fixture must NOT WARN about retros --"
  kit="$(mkkit teeth-retro-drift)"; tgt="$kit/targetA"
  mkcorpus "$tgt" 4 "a"
  mkdir -p "$tgt/retros"
  for i in 1 2 3 4 5; do printf '# retro %d\nbody\n' "$i" > "$tgt/retros/2026-01-0${i}.md"; done
  write_targets_custom "$kit" "$tgt" "4 md / 2 retros / git yes / hook yes"
  mut="$kit/toolbelt/verify-registry.sh"
  if grep -q '# RETRO-DRIFT-CHECK' "$mut"; then
    sed -i '/# RETRO-DRIFT-CHECK/ s/.*/      : # RETRO-DRIFT-CHECK [MUTATED]/' "$mut"
    mout="$("$BASH_BIN" "$mut" 2>&1)"; mrc=$?
    if [ "$mrc" = 0 ] && ! grep -qiE 'WARN[[:space:]]+targetA.*retro' <<<"$mout"; then
      ok "teeth-retro-drift: neutered → drift fixture emits NO retro WARN (test 32 has teeth)" "(exit $mrc)"
    else
      no "teeth-retro-drift: neutered mutant STILL emits retro WARN → test 32 is THEATER" "mrc=$mrc mout=[$mout]"
    fi
  else
    no "teeth-retro-drift: RETRO-DRIFT-CHECK sentinel not found in SUT"
  fi

  # teeth-retro-exit0: add 'exit 1' in the drift branch; test 32's exit-0 assertion must now fail →
  # proves the '[ "$RC" = 0 ]' in test 32 is load-bearing (not vacuously true).
  echo "-- teeth-retro-exit0: drift branch exits 1; test 32 exit-0 assertion must fail --"
  kit="$(mkkit teeth-retro-exit0)"; tgt="$kit/targetA"
  mkcorpus "$tgt" 4 "a"
  mkdir -p "$tgt/retros"
  for i in 1 2 3 4 5; do printf '# retro %d\nbody\n' "$i" > "$tgt/retros/2026-01-0${i}.md"; done
  write_targets_custom "$kit" "$tgt" "4 md / 2 retros / git yes / hook yes"
  mut="$kit/toolbelt/verify-registry.sh"
  if grep -q '# RETRO-DRIFT-CHECK' "$mut"; then
    # Append 'exit 1' immediately after the WARN line carrying the RETRO-DRIFT-CHECK sentinel.
    sed -i '/# RETRO-DRIFT-CHECK/a\      exit 1' "$mut"
    mout="$("$BASH_BIN" "$mut" 2>&1)"; mrc=$?
    if [ "$mrc" != 0 ]; then
      ok "teeth-retro-exit0: exit-1 mutant exits non-zero → test 32 exit-0 check has teeth" "(exit $mrc)"
    else
      no "teeth-retro-exit0: exit-1 mutant still exited 0 → test 32 exit-0 check is THEATER" "mrc=$mrc"
    fi
  else
    no "teeth-retro-exit0: RETRO-DRIFT-CHECK sentinel not found in SUT"
  fi

  # teeth-absent-vs-malformed: neuter NONCONFORM-FIELD-CHECK; 'retros: many' fixture must stop
  # WARNing → proves test 34 is distinguishable from test 33 (absent vs malformed).
  echo "-- teeth-absent-vs-malformed: neuter NONCONFORM-FIELD-CHECK; malformed must NOT WARN --"
  kit="$(mkkit teeth-absent-malformed)"; tgt="$kit/targetA"
  mkcorpus "$tgt" 4 "a"
  write_targets_custom "$kit" "$tgt" "4 md / retros: many / git yes / hook yes"
  mut="$kit/toolbelt/verify-registry.sh"
  if grep -q '# NONCONFORM-FIELD-CHECK' "$mut"; then
    sed -i '/# NONCONFORM-FIELD-CHECK/ s/.*/      : # NONCONFORM-FIELD-CHECK [MUTATED]/' "$mut"
    mout="$("$BASH_BIN" "$mut" 2>&1)"; mrc=$?
    if [ "$mrc" = 0 ] && ! grep -qiE 'not in schema' <<<"$mout"; then
      ok "teeth-absent-vs-malformed: neutered → malformed token not flagged (test 34 has teeth)" "(exit $mrc)"
    else
      no "teeth-absent-vs-malformed: neutered mutant STILL flags malformed → test 34 is THEATER" "mrc=$mrc mout=[$mout]"
    fi
  else
    no "teeth-absent-vs-malformed: NONCONFORM-FIELD-CHECK sentinel not found in SUT"
  fi

  # teeth-unknown-field: neuter NONCONFORM-FIELD-CHECK; 'widget yes' fixture must stop WARNing →
  # proves test 35's schema-enforcement assertion is load-bearing.
  echo "-- teeth-unknown-field: neuter NONCONFORM-FIELD-CHECK; 'widget yes' must NOT WARN --"
  kit="$(mkkit teeth-unknown-field)"; tgt="$kit/targetA"
  mkcorpus "$tgt" 4 "a"
  write_targets_custom "$kit" "$tgt" "4 md / widget yes / git yes / hook yes"
  mut="$kit/toolbelt/verify-registry.sh"
  if grep -q '# NONCONFORM-FIELD-CHECK' "$mut"; then
    sed -i '/# NONCONFORM-FIELD-CHECK/ s/.*/      : # NONCONFORM-FIELD-CHECK [MUTATED]/' "$mut"
    mout="$("$BASH_BIN" "$mut" 2>&1)"; mrc=$?
    if [ "$mrc" = 0 ] && ! grep -qiE 'not in schema.*widget' <<<"$mout"; then
      ok "teeth-unknown-field: neutered → 'widget yes' not flagged (test 35 has teeth)" "(exit $mrc)"
    else
      no "teeth-unknown-field: neutered mutant STILL flags 'widget yes' → test 35 is THEATER" "mrc=$mrc mout=[$mout]"
    fi
  else
    no "teeth-unknown-field: NONCONFORM-FIELD-CHECK sentinel not found in SUT"
  fi

  # teeth-last-token: revert the tokenizer last-token fix (remove `|| [ -n "$_vr_tok" ]`) →
  # the last-position garbage fixture (test 37) must STOP emitting the schema WARN, proving
  # test 37 depends on the fix and not on coincidental output.
  echo "-- teeth-last-token: revert tokenizer fix; last-position garbage must NOT WARN --"
  kit="$(mkkit teeth-last-token)"; tgt="$kit/targetA"
  mkcorpus "$tgt" 4 "a"
  write_targets_custom "$kit" "$tgt" "4 md / git yes / ABSOLUTE NONSENSE LAST TOKEN"
  mut="$kit/toolbelt/verify-registry.sh"
  if grep -q '# TOKENIZER-LAST-TOKEN-FIX' "$mut"; then
    # Neuter: remove the '|| [ -n "$_vr_tok" ]' part so read's non-zero for the last
    # unterminated line is no longer caught, silently dropping the last token again.
    sed -i 's/ || \[ -n "\$_vr_tok" \]//' "$mut"
    mout="$("$BASH_BIN" "$mut" 2>&1)"; mrc=$?
    if [ "$mrc" = 0 ] && ! grep -qiE 'WARN[[:space:]]+targetA.*not in schema.*ABSOLUTE NONSENSE' <<<"$mout"; then
      ok "teeth-last-token: reverted tokenizer → last-position garbage emits NO WARN (test 37 has teeth)" "(exit $mrc)"
    else
      no "teeth-last-token: reverted mutant STILL emits WARN → test 37 is THEATER" "mrc=$mrc mout=[$mout]"
    fi
  else
    no "teeth-last-token: TOKENIZER-LAST-TOKEN-FIX sentinel not found in SUT — fix not applied or marker drifted"
  fi

  # teeth-retro-unreadable: neuter RETRO-UNREADABLE-CHECK (the if-condition on the guard);
  # the unreadable-dir fixture (test 39) must produce a false drift WARN instead of the
  # operational WARN, proving test 39's assertion is load-bearing.
  echo "-- teeth-retro-unreadable: neuter RETRO-UNREADABLE-CHECK; unreadable dir must produce false drift --"
  kit="$(mkkit teeth-retro-unreadable)"; tgt="$kit/targetA"
  mkcorpus "$tgt" 4 "a"
  mkdir -p "$tgt/retros"
  printf '# real retro 1\nbody\n' > "$tgt/retros/2026-01-01.md"
  printf '# real retro 2\nbody\n' > "$tgt/retros/2026-01-02.md"
  write_targets_custom "$kit" "$tgt" "4 md / 2 retros / git yes / hook yes"
  chmod 000 "$tgt/retros"
  mut="$kit/toolbelt/verify-registry.sh"
  if grep -q '# RETRO-UNREADABLE-CHECK' "$mut"; then
    sed -i '/# RETRO-UNREADABLE-CHECK/ s/.*/  if false; then  # RETRO-UNREADABLE-CHECK [MUTATED]/' "$mut"
    mout="$("$BASH_BIN" "$mut" 2>&1)"; mrc=$?
    chmod 755 "$tgt/retros"  # restore for cleanup
    # Without the guard: find on chmod-000 dir (2>/dev/null) → 0 retros → claimed=2 vs real=0 → drift WARN.
    if [ "$mrc" = 0 ] \
       && grep -qiE 'WARN[[:space:]]+targetA.*retro' <<<"$mout" \
       && ! grep -qiE 'not accessible|permission' <<<"$mout"; then
      ok "teeth-retro-unreadable: neutered → false drift WARN fires, no operational WARN (test 39 has teeth)" "(exit $mrc)"
    else
      chmod 755 "$tgt/retros" 2>/dev/null
      no "teeth-retro-unreadable: expected false drift WARN but did not get it" "mrc=$mrc mout=[$mout]"
    fi
  else
    chmod 755 "$tgt/retros" 2>/dev/null
    no "teeth-retro-unreadable: RETRO-UNREADABLE-CHECK sentinel not found in SUT"
  fi

  # teeth-retro-exclusion: remove the retro_is_excluded gate in the retro-counting loop;
  # an excluded retro gets counted, causing the claims-1/real-2 fixture to drift —
  # proves tests 15/36 depend on the gate (MINOR 7 mutation control).
  echo "-- teeth-retro-excl: remove retro_is_excluded gate; excluded retro counted → drift fires --"
  kit="$(mkkit teeth-retro-excl)"; tgt="$kit/targetA"
  mkcorpus "$tgt" 4 "a"
  mkdir -p "$tgt/retros"
  printf '# real retro\nbody\n' > "$tgt/retros/2026-01-01-real.md"
  printf '<!-- kit-retro: exclude -->\n# client retro\nbody\n' > "$tgt/retros/2026-01-02-client.md"
  write_targets_custom "$kit" "$tgt" "4 md / 1 retros / git yes / hook yes"
  mut="$kit/toolbelt/verify-registry.sh"
  # Target the retro-counting loop specifically (uses $_vr_rfile, not $_vr_rf used by reachability).
  if grep -q 'retro_is_excluded "\$_vr_rfile" && continue' "$mut"; then
    sed -i 's/retro_is_excluded "\$_vr_rfile" && continue/: # retro_is_excluded [NEUTERED]/' "$mut"
    mout="$("$BASH_BIN" "$mut" 2>&1)"; mrc=$?
    # Neutered: counts 2 (1 real + 1 excluded) vs claimed 1 → drift WARN fires.
    if [ "$mrc" = 0 ] && grep -qiE 'WARN[[:space:]]+targetA.*1 retro.*2 non-excluded|WARN[[:space:]]+targetA.*2 non-excluded.*1 retro' <<<"$mout"; then
      ok "teeth-retro-excl: exclusion gate neutered → drift WARN fires (tests 15/36 have teeth)" "(exit $mrc)"
    else
      no "teeth-retro-excl: exclusion gate neutered but expected drift WARN not found" "mrc=$mrc mout=[$mout]"
    fi
  else
    no "teeth-retro-excl: retro_is_excluded gate for \$_vr_rfile not found in SUT"
  fi
fi

# 45 — OPERATIONAL FAILURE: TARGETS.md missing → exit 1, explicit diagnostic, no summary.
#      Before issue #140 fix, verify-registry exited 0 (old WARN-only contract). After the fix
#      it must match the sibling scripts (sweep-retros, sweep-audits): a missing input is not an
#      advisory finding, it is an operational failure that aborts the instrument.
#      RED before fix: current code exits 0 (the SUT has 'exit 0' at the TARGETS.md guard).
kit="$(mkkit c45-notargets-exit1)"   # no write_targets → TARGETS.md absent
run "$kit"
if [ "$RC" = 1 ] && grep -qi 'cannot find' <<<"$OUT" && ! grep -q 'Summary:' <<<"$OUT"; then
  ok "45 missing TARGETS.md → exit 1 (operational), 'cannot find' msg, no summary" "(exit $RC)"
else
  no "45 missing TARGETS.md → exit 1 (operational), 'cannot find' msg, no summary" "exit=$RC out=[$OUT]"
fi

# 46 — OPERATIONAL FAILURE: target-paths helper exists but defines no required function → exit 1,
#      explicit 'failed to define' diagnostic, no summary. Before issue #140 fix, verify-registry
#      exited 0 (old WARN-only contract). After the fix it must match the sibling contract.
#      RED before fix: current code exits 0 (SUT has 'exit 0' at declare-F target_paths_all guard).
kit="$(mkkit c46-brokentp-exit1)"; tgt="$kit/targetA"
mkcorpus "$tgt" 3 "a"
write_targets "$kit" "$tgt::3 md"
printf '#!/usr/bin/env bash\n# broken: sources cleanly but defines no target_paths_all\n' \
  > "$kit/toolbelt/lib/target-paths.sh"
run "$kit"
if [ "$RC" = 1 ] \
   && grep -q 'failed to define target_paths_all' <<<"$OUT" \
   && ! grep -q 'Summary:' <<<"$OUT"; then
  ok "46 broken target-paths helper → exit 1 (operational), 'failed to define', no summary" "(exit $RC)"
else
  no "46 broken target-paths helper → exit 1 (operational), 'failed to define', no summary" "exit=$RC out=[$OUT]"
fi

# 47 — REGRESSION GUARD: advisory findings (drift, maturity schema) still exit 0 after the fix.
#      The fix must only change operational-failure exit codes, not over-convert advisory WARNs.
#      Sub-case a: drifted row → exit 0 + WARN (regression guard; passes before AND after fix).
#      Sub-case b: clean kit  → exit 0 (regression guard for the happy path).
#      NOTE: both sub-cases pass against the pre-fix code — this is a regression guard, not a RED case.
kit="$(mkkit c47-drift-still-exit0)"; tgt="$kit/targetA"
mkcorpus "$tgt" 5 "a"
write_targets "$kit" "$tgt::40 md"   # drift > tol
run "$kit"
drift_ok=0
[ "$RC" = 0 ] && grep -qE 'WARN.*targetA.*drift' <<<"$OUT" && drift_ok=1
kit2="$(mkkit c47b-clean-exit0)"; tgt2="$kit2/targetA"
mkcorpus "$tgt2" 5 "a"
write_targets "$kit2" "$tgt2::5 md"  # clean
OUT2="$("$BASH_BIN" "$kit2/toolbelt/verify-registry.sh" 2>&1)"; RC2=$?
clean_ok=0; [ "$RC2" = 0 ] && clean_ok=1
if [ "$drift_ok" = 1 ] && [ "$clean_ok" = 1 ]; then
  ok "47 advisory drift/clean still exit 0 after op-failure fix (regression guard)" "(drift_ok=$drift_ok clean_ok=$clean_ok)"
else
  no "47 advisory drift/clean regression guard failed" "drift_ok=$drift_ok drift_out=[$OUT] clean_ok=$clean_ok clean_out=[$OUT2]"
fi

# 48 — OPERATIONAL FAILURE: target-paths helper FILE absent (not found, before sourcing) →
#      exit 1, 'cannot find helper' diagnostic, no 'failed to define' message (that is a
#      sourcing failure, not a file-absent failure), no Summary line. This is site 1 and is
#      distinct from site 2 (helper exists but target_paths_all undefined). Both start GREEN
#      (the implementation already exists); teeth prove each guard independently.
kit="$(mkkit c48-absent-tp-file)"; tgt="$kit/targetA"
mkcorpus "$tgt" 3 "a"
write_targets "$kit" "$tgt::3 md"
rm "$kit/toolbelt/lib/target-paths.sh"   # site 1: file absent (was copied by mkkit)
run "$kit"
if [ "$RC" = 1 ] \
   && grep -q 'cannot find helper' <<<"$OUT" \
   && ! grep -q 'failed to define' <<<"$OUT" \
   && ! grep -q 'Summary:' <<<"$OUT"; then
  ok "48 helper file absent → exit 1, 'cannot find helper', no 'failed to define', no summary" "(exit $RC)"
else
  no "48 helper file absent → exit 1, 'cannot find helper', no 'failed to define', no summary" "exit=$RC out=[$OUT]"
fi

# 49 — OPERATIONAL FAILURE: target-paths helper DEFINES target_paths_all but NOT target_paths_pairs →
#      execution passes site 2 (line-48 all-guard) and fails at site 3 (line-49 pairs-guard);
#      exit 1, pairs-specific diagnostic, no 'failed to define target_paths_all' message (proves
#      execution got past site 2), no Summary line. Starts GREEN; teeth prove the guard independently.
kit="$(mkkit c49-missing-pairs-fn)"; tgt="$kit/targetA"
mkcorpus "$tgt" 3 "a"
write_targets "$kit" "$tgt::3 md"
# Stub: defines target_paths_all so line-48 guard passes; leaves target_paths_pairs undefined.
printf '#!/usr/bin/env bash\n# stub: only target_paths_all defined\ntarget_paths_all() { :; }\n' \
  > "$kit/toolbelt/lib/target-paths.sh"
run "$kit"
if [ "$RC" = 1 ] \
   && grep -q 'failed to define target_paths_pairs' <<<"$OUT" \
   && ! grep -q 'failed to define target_paths_all' <<<"$OUT" \
   && ! grep -q 'Summary:' <<<"$OUT"; then
  ok "49 pairs fn absent → exit 1, pairs-specific diagnostic, no all-fn msg, no summary" "(exit $RC)"
else
  no "49 pairs fn absent → exit 1, pairs-specific diagnostic, no all-fn msg, no summary" "exit=$RC out=[$OUT]"
fi

# ---- TEETH for op-failure tests 45-46, 48-49 (issue #140 fix) ----------------------------------------
if [ "${1:-}" = "--prove-teeth" ]; then
  # M1: revert the TARGETS-MISSING-CHECK guard (exit 1 → exit 0). Test 45 expects exit 1 for a
  # missing TARGETS.md; the mutant must exit 0 so the assertion goes RED — proving test 45 depends
  # on the real guard and is not vacuously green.
  echo "-- M1-targets-missing: revert TARGETS-MISSING-CHECK; missing TARGETS.md must exit 0 (test 45 RED) --"
  kit="$(mkkit teeth-m1-notargets)"   # no TARGETS.md
  mut="$kit/toolbelt/verify-registry.sh"
  if grep -q '# TARGETS-MISSING-CHECK' "$mut"; then
    sed -i '/# TARGETS-MISSING-CHECK/ s/exit 1/exit 0/' "$mut"
    mout_m1="$("$BASH_BIN" "$mut" 2>&1)"; mrc_m1=$?
    if [ "$mrc_m1" = 0 ]; then
      ok "M1 TARGETS-MISSING-CHECK reverted → mutant exits 0 (test 45 would fail → has teeth)" "(exit $mrc_m1)"
    else
      no "M1 TARGETS-MISSING-CHECK reverted but mutant still exits non-zero → test 45 has no teeth" "mrc=$mrc_m1 mout=[$mout_m1]"
    fi
  else
    no "M1: TARGETS-MISSING-CHECK sentinel not found in SUT (guard not implemented or marker drifted)"
  fi

  # M-all (replaces old M2): revert ONLY the line-48 VR-TP-ALL-CHECK guard (exit 1 → exit 0),
  # proving test 46 is load-bearing. Old M2 targeted VR-TP-FUNC-CHECK which appeared on BOTH
  # lines 48 and 49 — collapsing two independent guards into one mutant. Now that the sentinels
  # are differentiated (line 48: VR-TP-ALL-CHECK; line 49: VR-TP-PAIRS-CHECK), each guard has
  # its own independent control. M-all covers test 46; M-pairs (below) covers test 49.
  echo "-- M-all: revert VR-TP-ALL-CHECK (line 48 only); broken-helper must exit 0 (test 46 RED) --"
  kit="$(mkkit teeth-m-all)"; tgt="$kit/targetA"
  mkcorpus "$tgt" 3 "a"
  write_targets "$kit" "$tgt::3 md"
  printf '#!/usr/bin/env bash\n# broken: no target_paths_all\n' > "$kit/toolbelt/lib/target-paths.sh"
  mut="$kit/toolbelt/verify-registry.sh"
  if grep -q '# VR-TP-ALL-CHECK' "$mut"; then
    sed -i '/# VR-TP-ALL-CHECK/ s/exit 1/exit 0/' "$mut"
    mout_ma="$("$BASH_BIN" "$mut" 2>&1)"; mrc_ma=$?
    if [ "$mrc_ma" = 0 ]; then
      ok "M-all: VR-TP-ALL-CHECK reverted → mutant exits 0 (test 46 has teeth)" "(exit $mrc_ma)"
    else
      no "M-all: reverted but mutant still exits non-zero → test 46 has no teeth" "mrc=$mrc_ma mout=[$mout_ma]"
    fi
  else
    no "M-all: VR-TP-ALL-CHECK sentinel not found in SUT (guard not implemented or marker drifted)"
  fi

  # M-helper-file: revert ONLY the line-43 VR-TP-FILE-CHECK guard (exit 1 → exit 0). Test 48
  # expects exit 1 for a missing helper file; the mutant exits 0 immediately after the echo
  # (exit in an if-body exits the script, so lines 46-49 never run) → test 48 RED.
  echo "-- M-helper-file: revert VR-TP-FILE-CHECK (line 43); helper-file-absent must exit 0 (test 48 RED) --"
  kit="$(mkkit teeth-m-helper-file)"; tgt="$kit/targetA"
  mkcorpus "$tgt" 3 "a"
  write_targets "$kit" "$tgt::3 md"
  rm "$kit/toolbelt/lib/target-paths.sh"   # same fixture as test 48
  mut="$kit/toolbelt/verify-registry.sh"
  if grep -q '# VR-TP-FILE-CHECK' "$mut"; then
    sed -i '/# VR-TP-FILE-CHECK/ s/exit 1/exit 0/' "$mut"
    mout_mf="$("$BASH_BIN" "$mut" 2>&1)"; mrc_mf=$?
    if [ "$mrc_mf" = 0 ]; then
      ok "M-helper-file: VR-TP-FILE-CHECK reverted → mutant exits 0 (test 48 has teeth)" "(exit $mrc_mf)"
    else
      no "M-helper-file: reverted but mutant still exits non-zero → test 48 has no teeth" "mrc=$mrc_mf mout=[$mout_mf]"
    fi
  else
    no "M-helper-file: VR-TP-FILE-CHECK sentinel not found in SUT (guard not implemented or marker drifted)"
  fi

  # M-pairs: revert ONLY the line-49 VR-TP-PAIRS-CHECK guard (exit 1 → exit 0). Test 49 expects
  # exit 1 for a helper that defines target_paths_all but not target_paths_pairs; the mutant
  # exits 0 (line-48 guard passes, mutated line-49 exits 0 immediately) → test 49 RED.
  echo "-- M-pairs: revert VR-TP-PAIRS-CHECK (line 49); pairs-fn-absent must exit 0 (test 49 RED) --"
  kit="$(mkkit teeth-m-pairs)"; tgt="$kit/targetA"
  mkcorpus "$tgt" 3 "a"
  write_targets "$kit" "$tgt::3 md"
  printf '#!/usr/bin/env bash\n# stub: only target_paths_all defined\ntarget_paths_all() { :; }\n' \
    > "$kit/toolbelt/lib/target-paths.sh"   # same fixture as test 49
  mut="$kit/toolbelt/verify-registry.sh"
  if grep -q '# VR-TP-PAIRS-CHECK' "$mut"; then
    sed -i '/# VR-TP-PAIRS-CHECK/ s/exit 1/exit 0/' "$mut"
    mout_mp="$("$BASH_BIN" "$mut" 2>&1)"; mrc_mp=$?
    if [ "$mrc_mp" = 0 ]; then
      ok "M-pairs: VR-TP-PAIRS-CHECK reverted → mutant exits 0 (test 49 has teeth)" "(exit $mrc_mp)"
    else
      no "M-pairs: reverted but mutant still exits non-zero → test 49 has no teeth" "mrc=$mrc_mp mout=[$mout_mp]"
    fi
  else
    no "M-pairs: VR-TP-PAIRS-CHECK sentinel not found in SUT (guard not implemented or marker drifted)"
  fi
fi

# 50 — ALL-ABSENT OPERATIONAL FAILURE: TARGETS.md has backtick paths but every resolved path is
#      a non-existent directory. paths IS non-empty (passes the [ -z "$paths" ] guard), but the
#      per-target [ -d ] check skips every entry, leaving checked == 0 and dir_reached == 0.
#      Current code exits 0 with "Registry consistent with reality" — a false PASS (§7).
#      After fix: exit 1 AND no "consistent with reality" in output.
#      RED before fix: exits 0 + "consistent".
kit="$(mkkit c50-all-absent)"
nonexistent50="$kit/corpus-that-does-not-exist"
write_targets "$kit" "$nonexistent50::5 md"
run "$kit"
if [ "$RC" = 1 ] \
   && ! grep -qi 'consistent with reality' <<<"$OUT"; then
  ok "50 all paths absent → exit 1, no 'consistent' (anti-silent-zero operational)" "(exit $RC)"
else
  no "50 all paths absent → should exit 1 but got exit 0 + 'consistent' (DEFECT)" "exit=$RC out=[$OUT]"
fi

# 51 — REGRESSION GUARD: at least one path reconciles → exit 0, normal verdict. The new guard
#      must NOT over-fire when dir_reached >= 1 (i.e. when at least one dir exists on disk).
#      Passes before AND after the fix (regression guard, not a RED case).
kit="$(mkkit c51-one-reconciles)"; tgt="$kit/targetA"
mkcorpus "$tgt" 4 "a"
write_targets "$kit" "$tgt::4 md"
run "$kit"
if [ "$RC" = 0 ] \
   && grep -q 'Registry consistent with reality' <<<"$OUT" \
   && grep -q 'reconciled 1 target' <<<"$OUT"; then
  ok "51 one target reconciles → exit 0 + normal verdict (guard does not over-fire)" "(exit $RC)"
else
  no "51 one reconciled target → regression guard failed" "exit=$RC out=[$OUT]"
fi

# ---- TEETH for all-absent guard (test 50) -----------------------------------------------------------
if [ "${1:-}" = "--prove-teeth" ]; then
  # teeth-all-absent: neuter ALL-ABSENT-CHECK (exit 1 → exit 0); the all-absent fixture must exit 0,
  # proving test 50 depends on the real guard and is not vacuously green.
  echo "-- teeth-all-absent: neuter ALL-ABSENT-CHECK; all-absent fixture must exit 0 (test 50 RED) --"
  kit="$(mkkit teeth-all-absent)"
  nonexistent_t="$kit/corpus-that-does-not-exist"
  write_targets "$kit" "$nonexistent_t::5 md"
  mut="$kit/toolbelt/verify-registry.sh"
  if grep -q '# ALL-ABSENT-CHECK' "$mut"; then
    sed -i '/# ALL-ABSENT-CHECK/ s/exit 1/exit 0/' "$mut"
    mout="$("$BASH_BIN" "$mut" 2>&1)"; mrc=$?
    if [ "$mrc" = 0 ]; then
      ok "teeth-all-absent: neutered guard → all-absent exits 0 (test 50 has teeth)" "(exit $mrc)"
    else
      no "teeth-all-absent: neutered mutant still exits non-zero → test 50 has no teeth" "mrc=$mrc mout=[$mout]"
    fi
  else
    no "teeth-all-absent: ALL-ABSENT-CHECK sentinel not found in SUT (guard not implemented or marker drifted)"
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
