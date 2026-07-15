#!/usr/bin/env bash
# verify-corrections.test.sh — RED-FIRST harness for verify-corrections.sh (§14 reciprocal-backlink lint).
#
# The load-bearing behaviour (retro delta): §14 says a correcting block must add a "corrected in BN" note to
# the block it corrects (keep the original text, add the note). Today only the FORWARD half is written by
# habit (the correcting block declares "Corrects [Block N]"); the reciprocal backlink is silently skipped —
# and a self-report can even CLAIM it happened when the git diff proves the target file was never touched.
# This lint mechanizes the reciprocal check: a one-directional correction (declared, not back-linked) FAILs.
# The discriminating case declares a correction whose target lacks the backlink and asserts exit 1; the
# boundary cases (backlink present; a bare [Block N] connection with no correction verb) assert exit 0 so the
# FAIL is provably gated on a real one-directional correction, not on any [Block N] mention. --prove-teeth
# neuters the FAIL and asserts the one-directional fixture then passes, proving the check is not theater.
#
# Usage: verify-corrections.test.sh [--prove-teeth]   Exit: 0 all held · 1 regression · 2 harness (SUT missing).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../verify-corrections.sh"
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
run(){ bash "$SUT" "$1" 2>/dev/null; }
code(){ bash "$SUT" "$1" >/dev/null 2>&1; echo $?; }

echo "== verify-corrections.test.sh (SUT: $(basename "$SUT")) =="

# 1 — no block files under the target → exit 2 (nothing to lint).
d="$TMP/empty"; mkdir -p "$d"; printf '# not a block\n' > "$d/notes.md"
if [ "$(code "$d")" = 2 ]; then ok "no block files → exit 2"; else no "empty: got $(code "$d") (want 2)"; fi

# 2 — RECIPROCATED correction: B33 declares 'Corrects [Block 8]' AND block-8 carries 'corrected in B33' → exit 0.
d="$TMP/ok"; mkdir -p "$d"
printf '# Block 33\n\n> Corrects [Block 8] §2 on Docker.\n\nBody.\n' > "$d/t-block33.md"
printf '# Block 8\n\nOriginal claim.\n\n> Note: corrected in B33 (new citation sources/x.pdf).\n' > "$d/t-block8.md"
out="$(run "$d")"
if [ "$(code "$d")" = 0 ] && printf '%s\n' "$out" | grep -qE 'ok +every declared correction'; then
  ok "reciprocated correction (B33→B8, B8 has 'corrected in B33') → exit 0 + ok line"
else no "ok-case: exit $(code "$d") :: $(printf '%s\n' "$out" | grep -iE 'fail|ok ' | head -1)"; fi

# 3 — CORE (retro delta): B33 declares 'Corrects [Block 8]' but block-8 has NO 'corrected in B33' backlink
#     → FAIL exit 1. This is the exact B33→B8 gap the retro caught (the correcting commit never touched B8).
d="$TMP/onedir"; mkdir -p "$d"
printf '# Block 33\n\n> Corrects [Block 8] §2 on Docker.\n\nBody.\n' > "$d/t-block33.md"
printf '# Block 8\n\nOriginal Docker claim, never annotated.\n' > "$d/t-block8.md"
out="$(run "$d")"
if [ "$(code "$d")" = 1 ] && printf '%s\n' "$out" | grep -qE 'FAIL.*B33 corrects \[Block 8\].*reciprocal'; then
  ok "one-directional correction (B8 lacks 'corrected in B33') → FAIL exit 1"
else no "onedir: exit $(code "$d") :: $(printf '%s\n' "$out" | grep -iE 'fail' | head -1)"; fi

# 4 — NEGATIVE CONTROL: a bare '[Block 8]' CONNECTION (no correction verb) must NOT fire — proves the FAIL is
#     gated on a real correction declaration, not on any [Block N] reference.
d="$TMP/connection"; mkdir -p "$d"
printf '# Block 33\n\n## Connections\n- **[Block 8]** — extends its Docker discussion.\n' > "$d/t-block33.md"
printf '# Block 8\n\nOriginal claim.\n' > "$d/t-block8.md"
if [ "$(code "$d")" = 0 ]; then ok "bare [Block 8] connection (no 'corrects' verb) → exit 0 (no false FAIL)"
else no "connection: exit $(code "$d") (want 0 — false FAIL on a plain connection)"; fi

# 5 — 'correct' the ADJECTIVE must not trip the verb detector: 'the correct value [Block 8]' → exit 0.
d="$TMP/adjective"; mkdir -p "$d"
printf '# Block 33\n\nThe correct value is 5 V, matching [Block 8].\n' > "$d/t-block33.md"
printf '# Block 8\n\nOriginal claim.\n' > "$d/t-block8.md"
if [ "$(code "$d")" = 0 ]; then ok "adjective 'correct value' + [Block 8] → exit 0 (verb-anchored, no false FAIL)"
else no "adjective: exit $(code "$d") (want 0 — 'correct' adjective wrongly treated as a correction)"; fi

# 6 — TIGHT VERB→REFERENCE BINDING (retro delta): a correction verb governs ONLY the FIRST [Block N] that
#     FOLLOWS it. B33 says 'Corrects [Block 8] §2; cf. [Block 12].' — it corrects 8 (which HAS its backlink)
#     and merely CROSS-REFERENCES 12. The trailing `cf. [Block 12]` must NOT be treated as a correction
#     target, so block-12 needs NO backlink → exit 0. RED before the fix: the loop iterated EVERY bracketed
#     ref on the verb line, demanding a 'corrected in B33' backlink in block-12 → false FAIL exit 1.
d="$TMP/cfref"; mkdir -p "$d"
printf '# Block 33\n\n> Corrects [Block 8] §2; cf. [Block 12].\n\nBody.\n' > "$d/t-block33.md"
printf '# Block 8\n\nOriginal claim.\n\n> Note: corrected in B33.\n' > "$d/t-block8.md"
printf '# Block 12\n\nUnrelated cross-referenced block, no backlink.\n' > "$d/t-block12.md"
out="$(run "$d")"
if [ "$(code "$d")" = 0 ] && printf '%s\n' "$out" | grep -qE 'ok +every declared correction'; then
  ok "verb governs only the first ref: 'Corrects [8] … cf. [12]' → 12 not a target → exit 0"
else no "cfref: exit $(code "$d") :: $(printf '%s\n' "$out" | grep -iE 'fail' | head -1)"; fi

# NEGATIVE CONTROL — neuter the FAIL in a mutant; the one-directional fixture must then pass (exit 0).
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: neuter the reciprocal-backlink FAIL (rc=1 → rc=0); expect the one-directional fixture to pass --"
  mutant="$TMP/verify-corrections.MUTANT.sh"
  sed 's/rc=1/rc=0/g' "$SUT" > "$mutant"
  d="$TMP/onedir"   # reuse case 3's one-directional fixture
  bash "$mutant" "$d" >/dev/null 2>&1; mgot=$?
  if [ "$mgot" = 0 ]; then
    ok "teeth: rc-neutered mutant passes the one-directional corpus (exit 0) → case 3 has teeth"
  else no "teeth: mutant exit $mgot (want 0) — case 3 does NOT depend on the FAIL (THEATER)"; fi

  echo "-- teeth: revert first-ref binding (drop 'head -1') so the verb governs ALL refs; the cf-fixture must FAIL --"
  bmutant="$TMP/verify-corrections.BINDMUTANT.sh"
  sed 's/ | head -1 | grep -oE/ | grep -oE/' "$SUT" > "$bmutant"
  if ! grep -q ' | head -1 | grep -oE' "$SUT"; then
    no "teeth: first-ref binding line not found in SUT (did the fix change shape?)"
  else
    d="$TMP/cfref"   # reuse case 6's cf-fixture (block-12 has NO backlink)
    bash "$bmutant" "$d" >/dev/null 2>&1; bgot=$?
    if [ "$bgot" = 1 ]; then
      ok "teeth: all-refs mutant demands a backlink in the cf-only block-12 (exit 1) → case 6 has teeth"
    else no "teeth: bind-mutant exit $bgot (want 1) — case 6 does NOT depend on first-ref binding (THEATER)"; fi
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
