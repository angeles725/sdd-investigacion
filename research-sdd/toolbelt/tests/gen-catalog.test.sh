#!/usr/bin/env bash
# gen-catalog.test.sh — RED-FIRST harness for gen-catalog.py's BLOCK_RE discriminator + catalog build.
#
# WHY THIS SHAPE (anti-"test theater" + retro-provenance): gen-catalog.py's BLOCK_RE is now LOAD-BEARING
# for the whole toolbelt. A recent alignment made verify-state.sh, research-sdd-status.sh --sync-state and
# research-sdd-archive.sh all count "block files" with the SAME strict discriminator that gen-catalog.py
# defines — `<prefix>-(block|bloque)<N>[-suffix].md`. Before that, a loose `*block*` glob let decoys like
# `blocked-notes.md` inflate the count and fork the authority (two definitions of "a block"). Yet
# gen-catalog.py shipped with ZERO tests and CI did not even run on changes to it, so the #1 alignment
# could silently rot. This suite locks BLOCK_RE (count / numeric sort / number+title extraction / the
# non-conforming exclusions) AND cross-checks, on ONE shared fixture, that the set gen-catalog.py catalogs
# equals the set the toolbelt's strict `grep -E` selects — mechanizing "one definition of a block".
#
# SUT = research-sdd/templates/gen-catalog.py (the GENERIC seed shipped to every target and the copy whose
# prefix-aware BLOCK_RE the toolbelt discriminator mirrors). The repo's own tools/gen-catalog.py is a
# DIFFERENT, corpus-specialized copy (`^sdd-mental-model-bloque(\d+)\.md$`); it is NOT the discriminator's
# mirror, so it is not the SUT here — but its shared TITLE_RE is parity-checked below so the two can't drift.
#
# CASE HANDLING (reconciled): gen-catalog.py's BLOCK_RE is case-SENSITIVE (no re.IGNORECASE — lowercase
# `block`/`bloque` keyword only). The toolbelt discriminator was reconciled to match EXACTLY: `grep -E`
# (no `-i`), `[^/]+` prefix (mirrors `.+`), `[[:alnum:]_-]` suffix (mirrors `[\w-]`). So the two now share
# ONE definition of a block, INCLUDING case. Case 9 pins that agreement in both directions: re-adding `-i`
# to the grep, or `re.IGNORECASE` to BLOCK_RE, flips one set and trips the test. This suite does NOT alter
# gen-catalog.py's behaviour — the reconciliation was applied to the toolbelt scripts, not the SUT.
#
# Usage: gen-catalog.test.sh [--prove-teeth]   Exit: 0 all held · 1 regression · 2 harness error (no SUT/python3).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
KIT="$(cd "$HERE/../.." && pwd)"                       # research-sdd/
SUT="$KIT/templates/gen-catalog.py"                   # the seed + discriminator mirror
TOOLS_COPY="$KIT/../tools/gen-catalog.py"             # repo-specialized copy (parity target)
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 not on PATH (gen-catalog.py is a python script)" >&2; exit 2; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

# gen <script> <dir> : run <script> so its ROOT (script.parent.parent) is <dir>; CATALOG.md lands in <dir>.
# gen-catalog.py resolves ROOT = Path(__file__).resolve().parent.parent, so the script must live in <dir>/tools/.
gen(){ local s="$1" d="$2"; mkdir -p "$d/tools"; cp "$s" "$d/tools/gen-catalog.py"; python3 "$d/tools/gen-catalog.py" >/dev/null 2>&1; }
# py_set <dir> : filenames gen-catalog.py actually cataloged (the `[fname]` link column of CATALOG.md).
py_set(){ grep -oE '\[[^]]+\.md\]' "$1/CATALOG.md" 2>/dev/null | tr -d '[]' | sort -u; }
# grep_set <dir> : filenames the toolbelt's STRICT discriminator selects — VERBATIM the grep used by
# verify-state.sh:101, research-sdd-status.sh --sync-state, and research-sdd-archive.sh. Kept identical on
# purpose: if this grep and gen-catalog.py's BLOCK_RE ever pick different sets, case 7 goes RED.
grep_set(){ find "$1" -maxdepth 1 -type f -name '*.md' 2>/dev/null \
  | grep -E '/[^/]+-(block|bloque)[0-9]+(-[[:alnum:]_-]+)?\.md$' | sed 's#.*/##' | sort -u; }
# nums_in_order <dir> : the block-number column of CATALOG.md, in emitted row order (to pin the numeric sort).
nums_in_order(){ grep -oE '^\| [0-9]+ ' "$1/CATALOG.md" | grep -oE '[0-9]+' | tr '\n' ' '; }

echo "== gen-catalog.test.sh (SUT: $(basename "$SUT")) =="

# ---- GOLDEN corpus: mixed EN/ES, mixed suffix, plus the four non-conforming decoys ----------------------
# Real block names are lowercase; this corpus stays lowercase so it is a faithful cross-check fixture (case 7).
G="$TMP/golden"; mkdir -p "$G"
printf '# Block 1 — First block\nbody\n'        > "$G/proj-block1.md"        # EN, no suffix
printf '# Bloque 2 — Segundo bloque\nbody\n'    > "$G/proj-bloque2.md"       # ES, no suffix
printf '# Bloque 10 — Decimo\nbody\n'           > "$G/proj-bloque10.md"      # two-digit → numeric-sort probe
printf '# Random heading no match\nbody\n'      > "$G/proj-bloque3-infra.md" # -suffix + TITLE_RE fallback
printf 'no heading at all\nbody\n'              > "$G/proj-bloque4.md"       # no `# ` line → (untitled)
printf '# not a block\n'                        > "$G/blocked-notes.md"      # DECOY: substring 'block', no `-blockN`
printf '# x\n'                                  > "$G/bloque9.md"            # DECOY: no prefix before 'bloque'
printf '# x\n'                                  > "$G/README.md"             # DECOY: unrelated md
printf '# x\n'                                  > "$G/x-bloque-test-infra.md"  # DECOY: bloque with no digit
gen "$SUT" "$G"

# 1 — block COUNT: exactly the 5 conforming files, not the 9 on disk (decoys excluded from the total).
if grep -qE '^Total: \*\*5 blocks\*\*$' "$G/CATALOG.md"; then
  ok "golden: Total is 5 blocks (4 decoys excluded)"
else no "count: $(grep -E '^Total:' "$G/CATALOG.md" | head -1)"; fi

# 2 — NUMERIC sort: rows must be ordered 1,2,3,4,10 (numeric), NOT lexicographic 1,10,2,3,4.
if [ "$(nums_in_order "$G")" = "1 2 3 4 10 " ]; then
  ok "golden: rows sorted numerically (1 2 3 4 10, not lexicographic)"
else no "sort order: '$(nums_in_order "$G")' (want '1 2 3 4 10 ')"; fi

# 3 — number + title extraction (EN, no suffix): `# Block 1 — First block` → row `| 1 | ... | First block |`.
if grep -qF '| 1 | [proj-block1.md](proj-block1.md) | First block |' "$G/CATALOG.md"; then
  ok "golden: block 1 → number 1, title 'First block'"
else no "row 1: $(grep -F 'proj-block1.md' "$G/CATALOG.md" | head -1)"; fi

# 4 — two-digit number + ES title: `# Bloque 10 — Decimo` → `| 10 | ... | Decimo |` (num parsed from the NAME).
if grep -qF '| 10 | [proj-bloque10.md](proj-bloque10.md) | Decimo |' "$G/CATALOG.md"; then
  ok "golden: bloque 10 → number 10, title 'Decimo'"
else no "row 10: $(grep -F 'proj-bloque10.md' "$G/CATALOG.md" | head -1)"; fi

# 5 — EXCLUSIONS: none of the four non-conforming decoys may appear anywhere in CATALOG.md.
if ! grep -qE 'blocked-notes\.md|bloque9\.md|README\.md|x-bloque-test-infra\.md' "$G/CATALOG.md"; then
  ok "golden: decoys (blocked-notes / bare bloque9 / README / bloque-no-digit) all excluded"
else no "a decoy leaked: $(grep -oE 'blocked-notes\.md|bloque9\.md|README\.md|x-bloque-test-infra\.md' "$G/CATALOG.md" | head -1)"; fi

# 6 — TITLE fallback (raw heading): a first `# ` line that DOESN'T match TITLE_RE falls back to the raw
#     heading text (block_title returns line[2:].strip()), NOT '(untitled)'. Pins the REAL code path.
if grep -qF '| 3 | [proj-bloque3-infra.md](proj-bloque3-infra.md) | Random heading no match |' "$G/CATALOG.md"; then
  ok "title fallback: non-TITLE_RE '# ' heading → raw heading text"
else no "raw-fallback: $(grep -F 'proj-bloque3-infra.md' "$G/CATALOG.md" | head -1)"; fi

# 7 — TITLE fallback (untitled): a block with NO `# ` line at all → literal '(untitled)'.
if grep -qF '| 4 | [proj-bloque4.md](proj-bloque4.md) | (untitled) |' "$G/CATALOG.md"; then
  ok "title fallback: no '# ' heading → (untitled)"
else no "untitled-fallback: $(grep -F 'proj-bloque4.md' "$G/CATALOG.md" | head -1)"; fi

# 8 — CROSS-CHECK CONTRACT (the important one): on this shared fixture, the set gen-catalog.py catalogs MUST
#     equal the set the toolbelt's strict grep selects. This is the anti-drift lock: one definition of a
#     block, mechanized. If BLOCK_RE and the grep ever disagree (on realistic lowercase names), this is RED.
if diff <(py_set "$G") <(grep_set "$G") >/dev/null; then
  ok "cross-check: gen-catalog set == toolbelt grep set (one definition of a block)"
else no "cross-check DRIFT :: py=[$(py_set "$G" | tr '\n' ' ')] grep=[$(grep_set "$G" | tr '\n' ' ')]"; fi

# 9 — CASE AGREEMENT (reconciled): a MIXED-CASE `proj-Bloque7.md`. BLOCK_RE is case-sensitive (lowercase
#     keyword only) and the toolbelt grep was reconciled to match EXACTLY (`grep -E`, no `-i`), so BOTH now
#     EXCLUDE it — one definition of a block, including case. This pins the agreement in both directions:
#     re-adding `-i` to the grep (re-forking looser) OR `re.IGNORECASE` to BLOCK_RE would flip one set and
#     trip this test. The lowercase `proj-bloque1.md` must be kept by both so the sets are non-empty.
d="$TMP/divergence"; mkdir -p "$d"
printf '# Block 7 — cased\n' > "$d/proj-Bloque7.md"
printf '# Block 1 — lower\n' > "$d/proj-bloque1.md"   # a real lowercase block so both sets are non-empty
gen "$SUT" "$d"
if ! py_set "$d" | grep -q '^proj-Bloque7.md$' && ! grep_set "$d" | grep -q '^proj-Bloque7.md$' \
   && py_set "$d" | grep -q '^proj-bloque1.md$' && grep_set "$d" | grep -q '^proj-bloque1.md$'; then
  ok "case agreement: mixed-case block excluded by BOTH (BLOCK_RE + reconciled grep), lowercase kept by both"
else no "case drift: py=[$(py_set "$d" | tr '\n' ' ')] grep=[$(grep_set "$d" | tr '\n' ' ')] (both must DROP proj-Bloque7.md, KEEP proj-bloque1.md)"; fi

# 10 — PARITY GUARD: templates/gen-catalog.py and tools/gen-catalog.py are NOT byte-identical BY DESIGN — the
#      template is the generic prefix-aware seed, tools/ is corpus-specialized to `sdd-mental-model-bloqueN`.
#      So we do NOT force byte equality; instead we lock the ONE line that MUST stay shared (TITLE_RE, the
#      heading parser), so a title-format change made in one copy can't silently skip the other. BLOCK_RE is
#      intentionally allowed to differ. (If the tools/ copy is absent from a shipped kit, skip cleanly.)
if [ -f "$TOOLS_COPY" ]; then
  tpl_title="$(grep '^TITLE_RE = ' "$SUT")"; tools_title="$(grep '^TITLE_RE = ' "$TOOLS_COPY")"
  if [ -n "$tpl_title" ] && [ "$tpl_title" = "$tools_title" ]; then
    ok "parity: TITLE_RE identical across templates/ and tools/ copies"
  else no "parity: TITLE_RE differs — templates:[$tpl_title] tools:[$tools_title]"; fi
  # sanity: both copies still DEFINE a BLOCK_RE (catch an accidental deletion in either).
  if grep -q '^BLOCK_RE = ' "$SUT" && grep -q '^BLOCK_RE = ' "$TOOLS_COPY"; then
    ok "parity: both copies define a BLOCK_RE (divergence is intentional, presence is not)"
  else no "parity: a copy is missing its BLOCK_RE definition"; fi
else
  ok "parity: tools/ copy absent (shipped kit) → parity check skipped cleanly"
fi

# ================================ NEGATIVE CONTROLS — prove the checks have TEETH ==========================
if [ "${1:-}" = "--prove-teeth" ]; then
  # TEETH A — BLOCK_RE's prefix+dash requirement is what EXCLUDES a bare `bloque9.md` (case 5) and keeps the
  # cross-check honest. Build a mutant whose BLOCK_RE drops that requirement (prefix + leading dash made
  # optional); the bare `bloque9.md` MUST then leak into the catalog. If it does NOT, case 5's exclusion does
  # not actually depend on BLOCK_RE (theater). Mutant keeps the num requirement so `blocked-notes.md` still
  # stays out — isolating the prefix/dash guard specifically.
  echo "-- teeth: drop BLOCK_RE prefix+dash requirement; expect bare 'bloque9.md' to leak into the catalog --"
  md="$TMP/teethA"; mkdir -p "$md/tools"
  mutant="$md/tools/gen-catalog.py"
  python3 - "$SUT" "$mutant" <<'PY'
import sys, re
src, dst = sys.argv[1], sys.argv[2]
t = open(src, encoding="utf-8").read()
# Function replacement → returned verbatim (no backslash-escape processing on the replacement string).
repl = r'BLOCK_RE = re.compile(r"^(?P<prefix>.*)-?(?:block|bloque)(?P<num>\d+)(?:-[\w-]+)?\.md$")  # MUTANT: prefix/dash optional'
mut = re.sub(r'^BLOCK_RE = re\.compile.*$', lambda _m: repl, t, count=1, flags=re.M)
open(dst, "w", encoding="utf-8").write(mut)
PY
  if ! grep -q 'MUTANT: prefix/dash optional' "$mutant"; then
    no "teeth(A): could not build mutant (BLOCK_RE line not found — did the SUT change?)"
  else
    printf '# x\n' > "$md/bloque9.md"; printf '# Block 1 — real\n' > "$md/proj-bloque1.md"
    python3 "$mutant" >/dev/null 2>&1
    if py_set "$md" | grep -q '^bloque9.md$'; then
      ok "teeth(A): mutant catalogs bare 'bloque9.md' → case 5's exclusion pins the BLOCK_RE prefix+dash guard"
    else no "teeth(A): mutant did NOT leak bloque9.md — exclusion does not depend on BLOCK_RE (THEATER)"; fi
  fi

  # TEETH B — TITLE_RE is what turns `# Block 1 — First block` into the clean title 'First block' (cases 3/4).
  # Neuter TITLE_RE so it never matches; block_title MUST then fall back to the raw heading, so the golden
  # title 'First block' disappears (becomes 'Block 1 — First block'). If the title survives, cases 3/4 do not
  # actually depend on TITLE_RE (theater).
  echo "-- teeth: neuter TITLE_RE (never matches); expect the clean title 'First block' to fall back to raw --"
  mb="$TMP/teethB"; mkdir -p "$mb/tools"
  mutantB="$mb/tools/gen-catalog.py"
  python3 - "$SUT" "$mutantB" <<'PY'
import sys, re
src, dst = sys.argv[1], sys.argv[2]
t = open(src, encoding="utf-8").read()
mut = re.sub(r'^TITLE_RE = re\.compile.*$',
             r'TITLE_RE = re.compile(r"^ZZZ_NEVER_MATCHES_ZZZ$")  # MUTANT: TITLE_RE neutered',
             t, count=1, flags=re.M)
open(dst, "w", encoding="utf-8").write(mut)
PY
  if ! grep -q 'MUTANT: TITLE_RE neutered' "$mutantB"; then
    no "teeth(B): could not build mutant (TITLE_RE line not found — did the SUT change?)"
  else
    printf '# Block 1 — First block\nbody\n' > "$mb/proj-block1.md"
    python3 "$mutantB" >/dev/null 2>&1
    if ! grep -qF '| First block |' "$mb/CATALOG.md" && grep -qF 'Block 1 — First block' "$mb/CATALOG.md"; then
      ok "teeth(B): neutered TITLE_RE falls back to raw heading → cases 3/4 pin the TITLE_RE extraction"
    else no "teeth(B): clean title survived the neutered TITLE_RE — title assertions are THEATER"; fi
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
