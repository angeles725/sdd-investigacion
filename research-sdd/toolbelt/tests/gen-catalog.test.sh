#!/usr/bin/env bash
# gen-catalog.test.sh — cross-checks between the Go catalog generator (`rsdd corpus catalog`) and the rest of the toolbelt.
#
# WHY THIS SHAPE: the catalog generator's block discriminator is LOAD-BEARING for the whole toolbelt. verify-state.sh,
# research-sdd-status.sh --sync-state and research-sdd-archive.sh all count "block files" with the SAME strict
# discriminator the generator defines — `<prefix>-(block|bloque)<N>[-suffix].md`, case-sensitive. A loose `*block*`
# glob once let decoys like `blocked-notes.md` inflate the count and fork the authority (two definitions of "a block").
#
# The generator was ported from Python (templates/gen-catalog.py) to Go in kit issue #2535. Everything that only
# exercises the generator itself (count, numeric sort, number and title extraction, title fallbacks, decoy exclusion,
# argv root, mutation controls) now lives in the Go tests of research-sdd/rsdd/internal/corpus/catalog, which replay
# the frozen Python generator's output byte for byte and run a seeded differential against it (see the package doc
# for the declared deviations). What stays here is what only the shell tree can see:
#   A  CROSS-CHECK  — on ONE fixture, the set the generator catalogs equals the set the toolbelt's strict `grep -E`
#                     selects (one definition of a block, mechanized);
#   B  CASE AGREEMENT — a mixed-case `proj-Bloque7.md` is excluded by BOTH, a lowercase block kept by both;
#   C  PARITY GUARD — the repo's corpus-specialized tools/gen-catalog.py shares its TITLE_RE with the Go command, so a
#                     title-format change in one cannot silently skip the other (BLOCK_RE may differ by design);
#   D  NO-ARG IS A USAGE ERROR — the Python generator's no-argument parent.parent mode does not exist in Go: the root
#                     is mandatory and nothing is written without it.
# --prove-teeth builds mutants of the comparison inputs (a generator that leaks a decoy, drops a block or leaks a cased
# name, and a TITLE_RE edit in a copy of the Go source) and requires each check to go red.
#
# Usage: gen-catalog.test.sh [--prove-teeth]   Exit: 0 all held · 1 regression · 2 harness error (no Go command).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
KIT="$(cd "$HERE/../.." && pwd)"  # LINT-CD-PHYSICAL-OK: test driver locating its SUT; tests run from the kit checkout, never through a rendered/symlinked toolbelt (kit issue #1024 round 5)
LIB="$KIT/toolbelt/lib/rsdd-exec.sh"
GOSRC="$KIT/rsdd/internal/corpus/catalog/match.go"     # holds the Go TITLE_RE
TOOLS_COPY="$KIT/../tools/gen-catalog.py"              # repo-specialized copy (parity target)
[ -f "$LIB" ] || { echo "FATAL: rsdd-exec.sh not found: $LIB" >&2; exit 2; }
[ -f "$GOSRC" ] || { echo "FATAL: Go catalog source not found: $GOSRC" >&2; exit 2; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

# gen <dir> : run the Go generator with <dir> as its root; CATALOG.md lands in <dir>. rsdd_exec replaces its process,
# hence the subshell. Output is discarded; callers judge the files (and gen_rc the exit code).
gen(){ ( . "$LIB" && rsdd_exec corpus catalog "$1" ) >/dev/null 2>&1; }
gen_rc(){ local rc=0; gen "$@" || rc=$?; return "$rc"; }
# The Go command must be runnable at all: a degraded environment (no binary, no Go toolchain) is a harness error.
PROBE="$TMP/probe"; mkdir -p "$PROBE"
if ! gen "$PROBE" || [ ! -f "$PROBE/CATALOG.md" ]; then
  echo "FATAL: the Go command 'rsdd corpus catalog' is not runnable here (no rsdd binary and no Go toolchain, or a build failure)" >&2
  ( . "$LIB" && rsdd_exec corpus catalog "$PROBE" ) 2>&1 | tail -3 >&2
  exit 2
fi
# cat_set <dir> : filenames the generator actually cataloged (the `[fname]` link column of CATALOG.md).
cat_set(){ grep -oE '\[[^]]+\.md\]' "$1/CATALOG.md" 2>/dev/null | tr -d '[]' | sort -u; }
# grep_set <dir> : filenames the toolbelt's STRICT discriminator selects — VERBATIM the grep used by
# verify-state.sh:101, research-sdd-status.sh --sync-state, and research-sdd-archive.sh. Kept identical on
# purpose: if this grep and the generator's pattern ever pick different sets, case A goes RED.
grep_set(){ find "$1" -maxdepth 1 -type f -name '*.md' 2>/dev/null \
  | grep -E '/[^/]+-(block|bloque)[0-9]+(-[[:alnum:]_-]+)?\.md$' | sed 's#.*/##' | sort -u; }

echo "== gen-catalog.test.sh (SUT: rsdd corpus catalog) =="

# ---- GOLDEN corpus: mixed EN/ES, mixed suffix, plus the four non-conforming decoys ----------------------
# Real block names are lowercase; this corpus stays lowercase so it is a faithful cross-check fixture.
G="$TMP/golden"; mkdir -p "$G"
printf '# Block 1 — First block\nbody\n'        > "$G/proj-block1.md"
printf '# Bloque 2 — Segundo bloque\nbody\n'    > "$G/proj-bloque2.md"
printf '# Bloque 10 — Decimo\nbody\n'           > "$G/proj-bloque10.md"
printf '# Random heading no match\nbody\n'      > "$G/proj-bloque3-infra.md"
printf 'no heading at all\nbody\n'              > "$G/proj-bloque4.md"
printf '# not a block\n'                        > "$G/blocked-notes.md"      # DECOY: substring 'block', no `-blockN`
printf '# x\n'                                  > "$G/bloque9.md"            # DECOY: no prefix before 'bloque'
printf '# x\n'                                  > "$G/README.md"             # DECOY: unrelated md
printf '# x\n'                                  > "$G/x-bloque-test-infra.md"  # DECOY: bloque with no digit
gen "$G"

# A — CROSS-CHECK CONTRACT: on this shared fixture, the set the generator catalogs MUST equal the set the toolbelt's
#     strict grep selects. This is the anti-drift lock: one definition of a block, mechanized.
cross_check(){ diff <(cat_set "$1") <(grep_set "$1") >/dev/null; }
if [ "$(cat_set "$G" | wc -l)" -eq 5 ] && cross_check "$G"; then
  ok "A cross-check: generator set == toolbelt grep set (one definition of a block, 5 blocks, 4 decoys out)"
else no "A cross-check DRIFT :: gen=[$(cat_set "$G" | tr '\n' ' ')] grep=[$(grep_set "$G" | tr '\n' ' ')]"; fi

# B — CASE AGREEMENT: a MIXED-CASE `proj-Bloque7.md`. The generator's pattern is case-sensitive (lowercase keyword
#     only) and the toolbelt grep matches EXACTLY (`grep -E`, no `-i`), so BOTH EXCLUDE it. Pins the agreement in both
#     directions: re-adding `-i` to the grep OR a case-insensitive pattern in the generator flips one set.
d="$TMP/divergence"; mkdir -p "$d"
printf '# Block 7 — cased\n' > "$d/proj-Bloque7.md"
printf '# Block 1 — lower\n' > "$d/proj-bloque1.md"   # a real lowercase block so both sets are non-empty
gen "$d"
case_agreement(){
  ! grep -q '^proj-Bloque7.md$' <<<"$(cat_set "$1")" && ! grep -q '^proj-Bloque7.md$' <<<"$(grep_set "$1")" \
    && grep -q '^proj-bloque1.md$' <<<"$(cat_set "$1")" && grep -q '^proj-bloque1.md$' <<<"$(grep_set "$1")"
}
if case_agreement "$d"; then
  ok "B case agreement: mixed-case block excluded by BOTH, lowercase kept by both"
else no "B case drift: gen=[$(cat_set "$d" | tr '\n' ' ')] grep=[$(grep_set "$d" | tr '\n' ' ')] (both must DROP proj-Bloque7.md, KEEP proj-bloque1.md)"; fi

# C — PARITY GUARD: the Go command and tools/gen-catalog.py are NOT the same generator BY DESIGN — Go is the generic
#     prefix-aware kit generator, tools/ is corpus-specialized to `sdd-mental-model-bloqueN`. We do NOT force the
#     patterns equal; we lock the ONE that MUST stay shared (TITLE_RE, the heading parser). The Go pattern is the
#     Python one with `\s` spelled as a Unicode class constant and `\d` as `\p{Nd}`, so both are normalised to the
#     Python spelling before comparing. (If the tools/ copy is absent from a shipped kit, skip cleanly.)
go_title_re(){ grep -F 'titleRE = regexp.MustCompile(' "$1" | sed -e 's/^[^`]*`//' -e 's/`)[[:space:]]*$//' \
  -e 's/\[` + pySpace + `\]/\\s/g' -e 's/\\p{Nd}/\\d/g'; }
py_title_re(){ grep '^TITLE_RE = ' "$1" | sed -e 's/^TITLE_RE = re\.compile(r"//' -e 's/")[[:space:]]*$//'; }
title_parity(){ local g p; g="$(go_title_re "$1")"; p="$(py_title_re "$2")"; [ -n "$g" ] && [ "$g" = "$p" ]; }
if [ -f "$TOOLS_COPY" ]; then
  if title_parity "$GOSRC" "$TOOLS_COPY"; then
    ok "C parity: TITLE_RE identical across the Go command and tools/gen-catalog.py"
  else no "C parity: TITLE_RE differs — go:[$(go_title_re "$GOSRC")] tools:[$(py_title_re "$TOOLS_COPY")]"; fi
  if grep -q '^BLOCK_RE = ' "$TOOLS_COPY" && grep -q 'blockRE = regexp.MustCompile(' "$GOSRC"; then
    ok "C parity: both define a block pattern (divergence is intentional, presence is not)"
  else no "C parity: a copy is missing its block pattern definition"; fi
else
  ok "C parity: tools/ copy absent (shipped kit) → parity check skipped cleanly"
fi

# D — NO-ARG IS A USAGE ERROR (Go has no parent.parent mode): exit 2, nothing written in the working directory.
nd="$TMP/noarg"; mkdir -p "$nd"; printf '# Block 1 — x\n' > "$nd/proj-block1.md"
rc=0; ( cd "$nd" && . "$LIB" && rsdd_exec corpus catalog ) >/dev/null 2>&1 || rc=$?
rc_empty=0; ( cd "$nd" && . "$LIB" && rsdd_exec corpus catalog "" ) >/dev/null 2>&1 || rc_empty=$?
if [ "$rc" = 2 ] && [ "$rc_empty" = 2 ] && [ ! -f "$nd/CATALOG.md" ]; then
  ok "D no argument / empty argument → usage error (exit 2), nothing written"
else no "D no-arg: rc=$rc rc(empty)=$rc_empty catalog=$([ -f "$nd/CATALOG.md" ] && echo WRITTEN || echo none) (want 2, 2, none)"; fi

# ================================ NEGATIVE CONTROLS — prove the checks have TEETH ==========================
if [ "${1:-}" = "--prove-teeth" ]; then
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  mutant_bootstrap mutant_sed || exit 2
  # The comparison checks A/B read the generator through RSDD_BIN, so a MUTANT generator is a small wrapper that runs
  # the real command and then tampers with the CATALOG.md it wrote. The real binary is resolved once.
  REAL="$( . "$LIB" && _rsdd_exec_resolve && printf '%s' "$_RSDD_EXEC_BIN" )"
  if [ -z "$REAL" ] || [ ! -x "$REAL" ]; then no "teeth: could not resolve the real rsdd binary"; else
    # mutant_gen <name> <tamper-command-using-$CAT>: writes an executable wrapper into $TMP/m-<name>/rsdd
    mutant_gen(){
      local md="$TMP/m-$1"; mkdir -p "$md"
      printf '#!/usr/bin/env bash\n"%s" "$@" || exit $?\nCAT="${@: -1}/CATALOG.md"\n%s\n' "$REAL" "$2" > "$md/rsdd"; chmod +x "$md/rsdd"
      printf '%s' "$md/rsdd"
    }
    gen_with(){ ( export RSDD_BIN="$1"; . "$LIB" && rsdd_exec corpus catalog "$2" ) >/dev/null 2>&1; }

    # TEETH A1 — a generator that LEAKS a decoy (bare `bloque9.md`) must trip the cross-check.
    echo "-- teeth: generator that leaks the decoy bloque9.md; expect check A to go red --"
    leak="$(mutant_gen leak "printf '| 9 | [bloque9.md](bloque9.md) | leaked |\\n' >> \"\$CAT\"")"
    tl="$TMP/teethA1"; cp -r "$G" "$tl"; rm -f "$tl/CATALOG.md"; gen_with "$leak" "$tl"
    if grep -q '^bloque9.md$' <<<"$(cat_set "$tl")" && ! cross_check "$tl"; then
      ok "teeth(A1): a leaked decoy makes the cross-check go red"
    else no "teeth(A1): leaked decoy did NOT trip the cross-check — check A is THEATER"; fi

    # TEETH A2 — a generator that DROPS a real block must trip the cross-check too.
    echo "-- teeth: generator that drops the block proj-bloque10.md; expect check A to go red --"
    drop="$(mutant_gen drop "sed -i '/proj-bloque10.md/d' \"\$CAT\"")"
    td="$TMP/teethA2"; cp -r "$G" "$td"; rm -f "$td/CATALOG.md"; gen_with "$drop" "$td"
    if ! grep -q '^proj-bloque10.md$' <<<"$(cat_set "$td")" && ! cross_check "$td"; then
      ok "teeth(A2): a dropped block makes the cross-check go red"
    else no "teeth(A2): dropped block did NOT trip the cross-check — check A is THEATER"; fi

    # TEETH B — a generator that is case-INSENSITIVE (lists the cased name) must trip the case agreement.
    echo "-- teeth: generator that catalogs the mixed-case proj-Bloque7.md; expect check B to go red --"
    cased="$(mutant_gen cased "printf '| 7 | [proj-Bloque7.md](proj-Bloque7.md) | cased |\\n' >> \"\$CAT\"")"
    tb="$TMP/teethB"; cp -r "$d" "$tb"; rm -f "$tb/CATALOG.md"; gen_with "$cased" "$tb"
    if grep -q '^proj-Bloque7.md$' <<<"$(cat_set "$tb")" && ! case_agreement "$tb"; then
      ok "teeth(B): a case-insensitive generator makes the case agreement go red"
    else no "teeth(B): cased name did NOT trip the case agreement — check B is THEATER"; fi
  fi

  # TEETH C — editing the Go TITLE_RE (a copy of the source) must make the parity guard go red.
  echo "-- teeth: edit TITLE_RE in a copy of the Go source; expect check C to go red --"
  mc="$TMP/teethC"; mkdir -p "$mc"
  if ! MUTANT_SYNTAX=none mutant_sed "$GOSRC" "$mc/match.go" '/titleRE = regexp/s/\\p{Nd}+/\\p{Nd}*/'; then
    no "teeth(C): could not build the mutant (the titleRE line changed shape — did the SUT change?)"
  elif [ -f "$TOOLS_COPY" ] && ! title_parity "$mc/match.go" "$TOOLS_COPY"; then
    ok "teeth(C): an edited TITLE_RE trips the parity guard"
  else no "teeth(C): edited TITLE_RE did NOT trip the parity guard — check C is THEATER"; fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
