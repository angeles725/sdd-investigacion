#!/usr/bin/env bash
# migrate-backlogs.test.sh — companion suite for migrate-backlogs.sh (kit #1543).
#
# The tool is PROPOSE-ONLY: it prints the mechanical §8b migration as a unified diff per file and a typed
# MANUAL line for everything non-mechanical, and never writes to the target. Cases assert each transform,
# each MANUAL reason, the typed absent/empty states (CLAUDE.md §7), a byte-identical target tree, and that
# applying the proposal leaves nothing mechanical to propose (idempotence). --prove-teeth builds mutants
# (including one that WRITES to the target) and requires each to be caught.
#
# Usage: migrate-backlogs.test.sh [--prove-teeth]   Exit: 0 all held · 1 regression.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../migrate-backlogs.sh"
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
command -v patch >/dev/null 2>&1 || { echo "FATAL: patch not found" >&2; exit 2; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
echo "== migrate-backlogs.test.sh =="

# tree_sum DIR — path + content digest of every file under DIR (target must be byte-identical after a run)
# A missing hash tool is a LOUD failure (never a silent empty digest that makes before == after trivially).
SHATOOL=""
for _c in sha1sum shasum sha256sum; do command -v "$_c" >/dev/null 2>&1 && { SHATOOL="$_c"; break; }; done
if [ -z "$SHATOOL" ]; then
  echo "  FAIL  no sha1sum/shasum/sha256sum on PATH — the propose-never-apply tree check cannot run (SKIP counted as FAIL)"
  echo "== 0 passed · 1 failed =="; exit 1
fi
tree_sum() { (cd "$1" && find . -type f -print0 | sort -z | xargs -0 "$SHATOOL"; find . -print | sort); }

# mkcorpus DIR
mkcorpus() {
  local d="$1"; mkdir -p "$d"
  cat > "$d/FOCUSES.md" <<'E'
# Focuses

| Focus | Status | State |
|---|---|---|
| alpha | closed (4/4) | RESEARCH-STATE-alpha.md |
| beta | active | RESEARCH-STATE-beta.md |
| gamma | weirdo | RESEARCH-STATE-gamma.md |
| delta | document | RESEARCH-STATE-delta.md |
E
  cat > "$d/RESEARCH-STATE-alpha.md" <<'E'
# Alpha — Research State

## Gap backlog

| Priority | Gap | Artifact type / source | Status |
|---|---|---|---|
| critical | G1 | web | open |
| MED | G2 | web | queued (note) |
| low (deferred) | G3 | web | pending |
| high (cross-vibra) | G4 | web | pending |
| SES2 | G5 | web | pending |
| — | G6 | web | open |
| high | G7 | web | covered B1 |
| **HIGH** | G8 | web | **open** |
| high | G9 | web | folded |
| high | G10 | web | pending |

## Stop control

- done
E
  cat > "$d/RESEARCH-STATE-beta.md" <<'E'
# Beta — Research State

## Gap-backlog (prioritized)

| Priority | Gap | Artifact type / source | Status |
|---|---|---|---|
| high | B1 | web | pending |
| low | B2 | web | ✅ B3 |
E
  printf '# Gamma — Research State\n\nno backlog here\n' > "$d/RESEARCH-STATE-gamma.md"
  printf '# Delta — Research State\n\noutline only\n' > "$d/RESEARCH-STATE-delta.md"
}

corpus="$TMP/corpus"; mkcorpus "$corpus"
before="$(tree_sum "$corpus")"
out="$(bash "$SUT" "$corpus" 2>"$TMP/err")"; rc=$?
after="$(tree_sum "$corpus")"

[ "$rc" = 0 ] && ok "1 exit 0 on a corpus with proposals (findings are not failures)" || no "1 rc=$rc"
[ "$before" = "$after" ] && ok "2 target tree byte-identical before/after (propose-never-apply)" || no "2 the target was modified"
has() { grep -qF -- "$1" <<<"$out"; }
has '+## Gap-backlog' && has '-## Gap backlog' && ok "3 near-miss heading renamed to ## Gap-backlog" || no "3 heading rename missing"
has '+| high | G1 | web | pending |' && ok "4a critical->high and open->pending" || no "4a"
has '+| medium | G2 | web | pending (note) |' && ok "4b MED->medium, queued->pending" || no "4b"
has '+| deferred | G3 | web | pending |' && ok "4c low (deferred)->deferred" || no "4c"
has '+| high | G4 | web | pending (cross-vibra) |' && ok "4d qualifier moved to Status decoration" || no "4d"
has '+| high | G8 | web | **pending** |' && ok "4e **HIGH**->high, **open**->**pending**" || no "4e"
grep -q '^MANUAL alpha unknown-priority rows=1 first-line=' <<<"$out" && ok "5a unknown priority SES2 -> MANUAL (not guessed)" || no "5a"
grep -q '^MANUAL alpha emdash-open-row rows=1 ' <<<"$out" && ok "5b open em-dash row -> MANUAL" || no "5b"
grep -q '^MANUAL alpha bare-closure-word rows=1 ' <<<"$out" && ok "5c bare 'covered' -> MANUAL" || no "5c"
grep -q '^MANUAL alpha unknown-status-token rows=1 ' <<<"$out" && ok "5d 'folded' -> MANUAL" || no "5d"
has '-| alpha | closed (4/4) | RESEARCH-STATE-alpha.md |' && has '+| alpha | stopped (4/4) | RESEARCH-STATE-alpha.md |' && ok "6a FOCUSES closed->stopped, decoration kept" || no "6a"
grep -q '^MANUAL FOCUSES unknown-focus-status rows=1 ' <<<"$out" && ok "6b unknown FOCUSES token -> MANUAL" || no "6b"
grep -q '^ok beta: nothing to migrate' <<<"$out" && ok "7 clean focus reported ok (no-match is distinguishable)" || no "7"
has '+| Priority | Gap | Artifact type / source | Status |' && grep -q '^MANUAL gamma empty-backlog-skeleton ' <<<"$out" && ok "8a backlog-less focus -> skeleton diff + MANUAL" || no "8a"
! grep -q 'delta' <<<"$(grep -E '^(PROPOSE|MANUAL)' <<<"$out")" && ok "8b document-mode focus gets no skeleton" || no "8b document focus was proposed"
grep -q '^migrate-backlogs: 5 file(s) inspected · 3 with a mechanical proposal · ' <<<"$out" && ok "9 closing summary names the populations inspected" || no "9 summary: [$(tail -1 <<<"$out")]"

# 10. idempotence: applying the proposal to a COPY leaves no mechanical proposal, only the same MANUAL items
cp -r "$corpus" "$TMP/applied"
( cd "$TMP/applied" && grep -v '^PROPOSE\|^MANUAL\|^ok \|^migrate-backlogs:' <<<"$out" | sed "s#^--- a/#--- #; s#^+++ b/#+++ #" | patch -p0 -s ) >/dev/null 2>&1
out2="$(bash "$SUT" "$TMP/applied" 2>/dev/null)"
resid="$(grep '^PROPOSE' <<<"$out2" | tr '\n' ' ')"
if [ -z "$resid" ] && grep -q '^## Gap-backlog' "$TMP/applied/RESEARCH-STATE-alpha.md" && grep -q '| high | G1 | web | pending |' "$TMP/applied/RESEARCH-STATE-alpha.md"; then
  ok "10 the diff applies cleanly to a copy and leaves nothing mechanical to propose"
else no "10 residual proposals: [$resid]"; fi
grep -q '^MANUAL alpha unknown-priority' <<<"$out2" && ok "10b MANUAL items survive the mechanical apply" || no "10b"

# 11. typed absent/empty states
mkdir -p "$TMP/emptydir"
o="$(bash "$SUT" "$TMP/emptydir" 2>&1)"; r=$?
[ "$r" = 0 ] && grep -q '^absent-input: no RESEARCH-STATE' <<<"$o" && grep -q '^migrate-backlogs: 0 file(s) inspected' <<<"$o" && ok "11a corpus without state files -> typed absent-input + 0-file summary" || no "11a [$o] rc=$r"
mkdir -p "$TMP/emptyfile"; : > "$TMP/emptyfile/RESEARCH-STATE-x.md"
o="$(bash "$SUT" "$TMP/emptyfile" 2>&1)"
grep -q '^empty-input: x ' <<<"$o" && ok "11b 0-byte state file -> typed empty-input" || no "11b [$o]"
bash "$SUT" "$TMP/nonexistent" >/dev/null 2>&1; r1=$?; bash "$SUT" >/dev/null 2>&1; r2=$?; bash "$SUT" a b >/dev/null 2>&1; r3=$?
[ "$r1" = 2 ] && [ "$r2" = 2 ] && [ "$r3" = 2 ] && ok "11c absent target / no arg / extra arg -> exit 2" || no "11c rc: $r1 $r2 $r3"

# 12. list edges: a rewritable row FIRST, MIDDLE and LAST of a table, and a single-row table
mkdir -p "$TMP/edges"
cat > "$TMP/edges/RESEARCH-STATE-e.md" <<'E'
# E

## Gap-backlog
| Priority | Gap | Type | Status |
|---|---|---|---|
| critical | E1 | web | pending |
| high | E2 | web | pending |
| high | E3 | web | open |
E
cat > "$TMP/edges/RESEARCH-STATE-f.md" <<'E'
# F

## Gap-backlog
| Priority | Gap | Type | Status |
|---|---|---|---|
| med | F1 | web | pending |
E
o="$(bash "$SUT" "$TMP/edges" 2>/dev/null)"
grep -qF '+| high | E1 | web | pending |' <<<"$o" && grep -qF '+| high | E3 | web | pending |' <<<"$o" && grep -qF '+| medium | F1 | web | pending |' <<<"$o" && ok "12 first/last/single-row edges rewritten" || no "12 edges: $o"

# 13. 5-column (Pr. | ID | Gap | Artifact | Status) shape: status is the LAST cell
mkdir -p "$TMP/five"
cat > "$TMP/five/RESEARCH-STATE-v.md" <<'E'
# V

## Gap-backlog
| Pr. | ID | Gap | Artifact | Status |
|---|---|---|---|---|
| high (x) | V1 | text | doc | open |
E
o="$(bash "$SUT" "$TMP/five" 2>/dev/null)"
grep -qF '+| high | V1 | text | doc | pending (x) |' <<<"$o" && ok "13 5-column table: Status read from the last cell" || no "13 [$o]"

# 14. a backlog-like heading over a NON-priority table: typed MANUAL, and no skeleton is stacked beside it
mkdir -p "$TMP/matrix"
printf '# M\n\n## Backlog\n\n| Area | Covered |\n|---|---|\n| a | yes |\n' > "$TMP/matrix/RESEARCH-STATE-m.md"
o="$(bash "$SUT" "$TMP/matrix" 2>/dev/null)"
if grep -q '^MANUAL m non-priority-backlog-table ' <<<"$o" && ! grep -q '^PROPOSE' <<<"$o"; then ok "14 non-priority backlog table -> MANUAL, no skeleton"; else no "14 [$o]"; fi

# 15. document-focus skip is an EXACT table parse (substring / regex-metachar / notes-cell overmatch)
mkdir -p "$TMP/doc"
cat > "$TMP/doc/FOCUSES.md" <<'E'
# Focuses

| Focus | Status | State | Notes |
|---|---|---|---|
| delta | document | RESEARCH-STATE-delta.md | outline |
| ta | active | RESEARCH-STATE-ta.md | plain |
| abc | document | RESEARCH-STATE-abc.md | outline |
| a.c | active | RESEARCH-STATE-a.c.md | plain |
| zed | active | RESEARCH-STATE-zed.md | documented elsewhere |
| real | **document** (outline) | RESEARCH-STATE-real.md | outline |
E
for f in delta ta abc a.c zed real; do printf '# %s\n\nno backlog\n' "$f" > "$TMP/doc/RESEARCH-STATE-$f.md"; done
o="$(bash "$SUT" "$TMP/doc" 2>/dev/null)"
for f in ta a.c zed; do grep -q "^MANUAL $f empty-backlog-skeleton " <<<"$o" && ok "15 $f is NOT skipped (no substring/regex/notes overmatch)" || no "15 $f wrongly skipped as document"; done
for f in delta abc real; do grep -q "^MANUAL $f " <<<"$o" && no "15 $f (a real document focus) got a skeleton" || ok "15 $f skipped as a real document focus"; done

# 16. never duplicate the canonical heading; at most one rename per file
mkdir -p "$TMP/dup"
cat > "$TMP/dup/RESEARCH-STATE-a.md" <<'E'
# A

## Gap-backlog
| Priority | Gap | Type | Status |
|---|---|---|---|
| high | A1 | web | pending |

## Backlog
| Priority | Gap | Type | Status |
|---|---|---|---|
| high | A2 | web | pending |
E
cat > "$TMP/dup/RESEARCH-STATE-b.md" <<'E'
# B

## Backlog
| Priority | Gap | Type | Status |
|---|---|---|---|
| high | B1 | web | pending |

## Gap backlog
| Priority | Gap | Type | Status |
|---|---|---|---|
| high | B2 | web | pending |
E
o="$(bash "$SUT" "$TMP/dup" 2>/dev/null)"
grep -q '^MANUAL a multiple-backlog-sections rows=1 ' <<<"$o" && ! grep -q '^PROPOSE a ' <<<"$o" && ok "16a canonical present -> second backlog section is MANUAL, not renamed" || no "16a [$o]"
[ "$(grep -c '^+## Gap-backlog$' <<<"$o")" = 1 ] && grep -q '^MANUAL b multiple-backlog-sections rows=1 ' <<<"$o" && ok "16b two near-miss sections -> exactly one rename + one MANUAL" || no "16b [$o]"

# 17. a Priority-led table OUTSIDE backlog-named sections must not suppress the empty-backlog proposal
mkdir -p "$TMP/cq"
printf '# Q\n\n## Campaign queue\n\n| Priority | Name | State |\n|---|---|---|\n| high | x | pending |\n' > "$TMP/cq/RESEARCH-STATE-q.md"
o="$(bash "$SUT" "$TMP/cq" 2>/dev/null)"
grep -q '^MANUAL q empty-backlog-skeleton ' <<<"$o" && ok "17 priority-led campaign-queue table does not hide a missing backlog" || no "17 [$o]"

# 18. invoked directly (executable bit), not via bash
if [ -x "$SUT" ]; then
  o="$("$SUT" "$corpus" 2>/dev/null)"; r=$?
  [ "$r" = 0 ] && grep -q '^migrate-backlogs: 5 file(s) inspected' <<<"$o" && ok "18 runs when invoked directly (executable)" || no "18 direct invocation rc=$r"
else no "18 migrate-backlogs.sh is not executable"; fi

# 19. only the documented heading variants are rename candidates; other *backlog* headings are MANUAL
mkdir -p "$TMP/hd"
printf '# R\n\n## Retro backlog\n\n| Priority | Gap | Type | Status |\n|---|---|---|---|\n| high | R1 | web | pending |\n' > "$TMP/hd/RESEARCH-STATE-r.md"
printf '# K\n\n## Kit backlog (notes)\n\n| Priority | Gap | Type | Status |\n|---|---|---|---|\n| high | K1 | web | pending |\n' > "$TMP/hd/RESEARCH-STATE-k.md"
o="$(bash "$SUT" "$TMP/hd" 2>/dev/null)"
if grep -q '^MANUAL r unrecognised-backlog-heading ' <<<"$o" && grep -q '^MANUAL k unrecognised-backlog-heading ' <<<"$o" && ! grep -q '^PROPOSE' <<<"$o"; then
  ok "19 'Retro backlog' / 'Kit backlog' -> MANUAL unrecognised-backlog-heading (no rename, no skeleton)"
else no "19 [$o]"; fi

# 20. an unsupported table width is ONE typed reason per table, not one malformed-row per row
mkdir -p "$TMP/wide"
printf '# W\n\n## Gap-backlog\n| Priority | A | B | C | D | E |\n|---|---|---|---|---|---|\n| high | 1 | 2 | 3 | 4 | open |\n| low | 1 | 2 | 3 | 4 | open |\n| low | 1 | 2 | 3 | 4 | open |\n' > "$TMP/wide/RESEARCH-STATE-w.md"
o="$(bash "$SUT" "$TMP/wide" 2>/dev/null)"
if grep -q '^MANUAL w unsupported-table-width cols=6 rows=1 ' <<<"$o" && ! grep -q 'malformed-row' <<<"$o"; then ok "20 unsupported width -> one typed unsupported-table-width cols=N"; else no "20 [$o]"; fi

# 21. only the focus REGISTRY table in FOCUSES.md is transformed
mkdir -p "$TMP/reg"
cat > "$TMP/reg/FOCUSES.md" <<'E'
# Focuses

| Item | Status |
|---|---|
| side-note | closed |

| Focus | Status | State |
|---|---|---|
| main | closed | RESEARCH-STATE-main.md |
E
printf '# M\n\n## Gap-backlog\n| Priority | Gap | Type | Status |\n|---|---|---|---|\n| high | M1 | web | pending |\n' > "$TMP/reg/RESEARCH-STATE-main.md"
o="$(bash "$SUT" "$TMP/reg" 2>/dev/null)"
if grep -qF '+| main | stopped | RESEARCH-STATE-main.md |' <<<"$o" && ! grep -qF '+| side-note | stopped |' <<<"$o" && ! grep -q 'unknown-focus-status' <<<"$o"; then ok "21 registry table transformed, sibling table untouched"; else no "21 [$o]"; fi

# 22. a failed state-file scan is DEGRADED (exit 1), never absent-input
mkdir -p "$TMP/degr/lib" "$TMP/degr/corpus"
cp "$SUT" "$TMP/degr/migrate-backlogs.sh"
printf 'list_state_files() { return 3; }\n' > "$TMP/degr/lib/state-files.sh"
printf '# S\n' > "$TMP/degr/corpus/RESEARCH-STATE-s.md"
o="$(bash "$TMP/degr/migrate-backlogs.sh" "$TMP/degr/corpus" 2>&1)"; r=$?
if [ "$r" = 1 ] && grep -q '^degraded: migrate-backlogs: scanning' <<<"$o" && ! grep -q '^absent-input' <<<"$o"; then ok "22 helper failure -> typed degraded + exit 1 (not absent-input)"; else no "22 rc=$r [$o]"; fi

# 23. backtick-decorated registry header is recognised by BOTH the transform and the document-skip (one shared definition)
mkdir -p "$TMP/bt"
cat > "$TMP/bt/FOCUSES.md" <<'E'
# Focuses

| `Focus` | `Status` | State |
|---|---|---|
| main | closed | RESEARCH-STATE-main.md |
| outline | document | RESEARCH-STATE-outline.md |
E
printf '# M\n\n## Gap-backlog\n| Priority | Gap | Type | Status |\n|---|---|---|---|\n| high | M1 | web | pending |\n' > "$TMP/bt/RESEARCH-STATE-main.md"
printf '# O\n\nno backlog\n' > "$TMP/bt/RESEARCH-STATE-outline.md"
o="$(bash "$SUT" "$TMP/bt" 2>/dev/null)"
if grep -qF '+| main | stopped | RESEARCH-STATE-main.md |' <<<"$o" && ! grep -q '^MANUAL outline ' <<<"$o"; then ok "23 backtick-quoted Status/Focus header: transform AND document-skip both see the registry"; else no "23 [$o]"; fi

# 24. diff status: 2 -> typed degraded + exit 1; 0 -> no PROPOSE and not counted
mkdir -p "$TMP/shim2" "$TMP/shim0"
printf '#!/bin/sh\necho diff-shim-trouble >&2\nexit 2\n' > "$TMP/shim2/diff"; chmod +x "$TMP/shim2/diff"
printf '#!/bin/sh\nexit 0\n' > "$TMP/shim0/diff"; chmod +x "$TMP/shim0/diff"
o="$(PATH="$TMP/shim2:$PATH" bash "$SUT" "$corpus" 2>&1)"; r=$?
if [ "$r" = 1 ] && grep -q '^degraded: migrate-backlogs: diff failed (status 2)' <<<"$o" && ! grep -q '^PROPOSE' <<<"$o"; then ok "24a diff status 2 -> degraded + exit 1, no PROPOSE printed"; else no "24a rc=$r [$o]"; fi
o="$(PATH="$TMP/shim0:$PATH" bash "$SUT" "$corpus" 2>&1)"; r=$?
if [ "$r" = 0 ] && ! grep -q '^PROPOSE' <<<"$o" && grep -q ' 0 with a mechanical proposal ' <<<"$o"; then ok "24b diff status 0 -> no PROPOSE, not counted"; else no "24b rc=$r [$o]"; fi

# ---- Teeth ------------------------------------------------------------------
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: mutation controls for migrate-backlogs.sh --"
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  TB="$HERE/.."
  MT="$TMP/mt"; mkdir -p "$MT"
  mk_tree() { local t="$MT/$1"; rm -rf "$t"; mkdir -p "$t"; cp -r "$TB/lib" "$t/lib"; printf '%s' "$t"; }
  # tooth NAME SEDEXPR CHECK-DESC GREP-PATTERN: mutant must LOSE the pattern the good run emits
  lose() {
    local name="$1" expr="$2" pat="$3" t o
    t="$(mk_tree "$name")"
    if ! mutant_sed "$SUT" "$t/migrate-backlogs.sh" "$expr" >/dev/null 2>&1; then no "teeth $name: mutant could not be built (pattern absent / refused)"; return; fi
    o="$(bash "$t/migrate-backlogs.sh" "$corpus" 2>/dev/null)"
    if grep -qF -- "$pat" <<<"$o"; then no "teeth $name: mutant still emits [$pat] — THEATER"; else ok "teeth $name: mutant loses [$pat]"; fi
  }
  lose A 's/if (q == "critical") return "high"/if (q == "criticalX") return "high"/' '+| high | G1 | web | pending |'
  lose B 's/ltok == "open" || ltok == "queued"/ltok == "openX"/' '+| medium | G2 | web | pending (note) |'
  lose C 's/else if (isbl\[cur\] \&\& hdr\[cur\])/else if (0)/' '-## Gap backlog'
  lose D 's/lt == "closed" || lt == "reabierto"/lt == "closedX"/' '+| alpha | stopped (4/4) | RESEARCH-STATE-alpha.md |'
  lose E 's/manual("unknown-priority", FNR); print line; next }$/print line; next }/' 'MANUAL alpha unknown-priority'
  lose F 's/b == "low (deferred)"/b == "low (deferredX)"/' '+| deferred | G3 | web | pending |'
  # G: a mutant that WRITES the proposal back into the target — the byte-identical assertion (case 2) must catch it
  t="$(mk_tree G)"
  if mutant_sed "$SUT" "$t/migrate-backlogs.sh" 's|^  local changed=0$|  cp "$out" "$f"; local changed=0|' >/dev/null 2>&1; then
    rm -rf "$TMP/gcorpus"; mkcorpus "$TMP/gcorpus"; gb="$(tree_sum "$TMP/gcorpus")"
    bash "$t/migrate-backlogs.sh" "$TMP/gcorpus" >/dev/null 2>&1
    [ "$gb" = "$(tree_sum "$TMP/gcorpus")" ] && no "teeth G: writing mutant left the tree identical — THEATER (case 2 cannot catch a write)" || ok "teeth G: a mutant that writes the target is caught by the tree-identity check"
  else no "teeth G: mutant could not be built"; fi
  # H: summary line dropped -> case 9 must go red
  lose H 's/^echo "migrate-backlogs: \$n_files file(s) inspected.*$/:/' 'migrate-backlogs: 5 file(s) inspected'
  # J: the non-priority-table branch removed -> case 14 must go red (a skeleton gets stacked beside the matrix)
  t="$(mk_tree J)"
  if mutant_sed "$SUT" "$t/migrate-backlogs.sh" 's/!anyhdr \&\& anybl) manual/!anyhdr \&\& 0) manual/' >/dev/null 2>&1; then
    o="$(bash "$t/migrate-backlogs.sh" "$TMP/matrix" 2>/dev/null)"
    grep -q '^MANUAL m non-priority-backlog-table' <<<"$o" && no "teeth J: mutant still typed — THEATER" || ok "teeth J: branch removed -> case 14 has teeth"
  else no "teeth J: mutant could not be built"; fi
  # K: document-focus match loosened to a substring -> case 15 (ta / zed / a.c) must go red
  t="$(mk_tree K)"
  if mutant_sed "$SUT" "$t/migrate-backlogs.sh" 's/hit = (bare(a\[1\]) == lab)/hit = (index(bare(a[1]), lab) > 0)/' >/dev/null 2>&1; then
    o="$(bash "$t/migrate-backlogs.sh" "$TMP/doc" 2>/dev/null)"
    grep -q '^MANUAL ta empty-backlog-skeleton' <<<"$o" && no "teeth K: substring mutant still exact — THEATER" || ok "teeth K: substring match -> case 15 has teeth"
  else no "teeth K: mutant could not be built"; fi
  # L: duplicate-canonical guard removed -> case 16a must go red
  t="$(mk_tree L)"
  if mutant_sed "$SUT" "$t/migrate-backlogs.sh" 's/if (anycanon || renamed) manual/if (0) manual/' >/dev/null 2>&1; then
    o="$(bash "$t/migrate-backlogs.sh" "$TMP/dup" 2>/dev/null)"
    grep -q '^MANUAL a multiple-backlog-sections' <<<"$o" && no "teeth L: guard removed but still MANUAL — THEATER" || ok "teeth L: guard removed -> case 16 has teeth"
  else no "teeth L: mutant could not be built"; fi
  # M: anyhdr made file-global again -> case 17 must go red
  t="$(mk_tree M)"
  if mutant_sed "$SUT" "$t/migrate-backlogs.sh" 's/if (isbl\[cur\] || canon\[cur\]) anyhdr = 1/anyhdr = 1/' >/dev/null 2>&1; then
    o="$(bash "$t/migrate-backlogs.sh" "$TMP/cq" 2>/dev/null)"
    grep -q '^MANUAL q empty-backlog-skeleton' <<<"$o" && no "teeth M: file-global mutant still proposes — THEATER" || ok "teeth M: file-global anyhdr -> case 17 has teeth"
  else no "teeth M: mutant could not be built"; fi
  # N: any *backlog* heading becomes a rename candidate -> case 19 must go red
  t="$(mk_tree N)"
  if mutant_sed "$SUT" "$t/migrate-backlogs.sh" 's/isbl\[cur\] = (!canon\[cur\] \&\& recog(h))/isbl[cur] = (!canon[cur] \&\& tolower(h) ~ \/backlog\/)/' >/dev/null 2>&1; then
    o="$(bash "$t/migrate-backlogs.sh" "$TMP/hd" 2>/dev/null)"
    grep -q '^MANUAL r unrecognised-backlog-heading' <<<"$o" && no "teeth N: loosened mutant still MANUAL — THEATER" || ok "teeth N: heading overmatch -> case 19 has teeth"
  else no "teeth N: mutant could not be built"; fi
  # O: width reason dropped (rows fall back to per-row malformed) -> case 20 must go red
  t="$(mk_tree O)"
  if mutant_sed "$SUT" "$t/migrate-backlogs.sh" 's/    if (width < 0) manual("unsupported-table-width cols=" nc, FNR)/    :/' >/dev/null 2>&1; then
    o="$(bash "$t/migrate-backlogs.sh" "$TMP/wide" 2>/dev/null)"
    grep -q 'unsupported-table-width' <<<"$o" && no "teeth O: mutant still typed — THEATER" || ok "teeth O: width reason dropped -> case 20 has teeth"
  else no "teeth O: mutant could not be built"; fi
  # P: every FOCUSES table treated as the registry -> case 21 must go red
  t="$(mk_tree P)"
  if mutant_sed "$SUT" "$t/migrate-backlogs.sh" 's/return (scol > 0 \&\& hasslug)/return (scol > 0)/' >/dev/null 2>&1; then
    o="$(bash "$t/migrate-backlogs.sh" "$TMP/reg" 2>/dev/null)"
    grep -qF '+| side-note | stopped |' <<<"$o" && ok "teeth P: any Status table transformed -> case 21 has teeth" || no "teeth P: mutant still leaves the sibling table alone — THEATER"
  else no "teeth P: mutant could not be built"; fi
  # Q: scan status ignored -> case 22 must go red
  t="$(mk_tree Q)"
  if mutant_sed "$SUT" "$t/migrate-backlogs.sh" 's/^\[ "\$_scan_rc" = 0 \] || .*$/:/' >/dev/null 2>&1; then
    cp "$TMP/degr/lib/state-files.sh" "$t/lib/state-files.sh"
    o="$(bash "$t/migrate-backlogs.sh" "$TMP/degr/corpus" 2>&1)"; r=$?
    { [ "$r" = 1 ] && grep -q '^degraded:' <<<"$o"; } && no "teeth Q: mutant still degraded — THEATER" || ok "teeth Q: scan status ignored -> case 22 has teeth"
  else no "teeth Q: mutant could not be built"; fi
  # R: diff status ignored (every non-zero treated as a proposal) -> case 24a must go red
  t="$(mk_tree R)"
  if mutant_sed "$SUT" "$t/migrate-backlogs.sh" 's/^    \*) echo "degraded: migrate-backlogs: diff failed.*$/    *) changed=1 ;;/' >/dev/null 2>&1; then
    o="$(PATH="$TMP/shim2:$PATH" bash "$t/migrate-backlogs.sh" "$corpus" 2>&1)"; r=$?
    [ "$r" = 1 ] && no "teeth R: mutant still degraded — THEATER" || ok "teeth R: diff status ignored -> case 24a has teeth"
  else no "teeth R: mutant could not be built"; fi
  # S: the shared registry detection loses backtick stripping -> case 23 must go red (one edit hits both programs)
  t="$(mk_tree S)"
  if mutant_sed "$SUT" "$t/migrate-backlogs.sh" 's/ gsub(\/`\/, "", s);//' >/dev/null 2>&1; then
    o="$(bash "$t/migrate-backlogs.sh" "$TMP/bt" 2>/dev/null)"
    grep -qF '+| main | stopped |' <<<"$o" && no "teeth S: mutant still sees the backtick header — THEATER" || ok "teeth S: backtick strip removed -> case 23 has teeth"
  else no "teeth S: mutant could not be built"; fi
  # I: the absent-input typed line silenced
  t="$(mk_tree I)"
  if mutant_sed "$SUT" "$t/migrate-backlogs.sh" 's/^  echo "absent-input: no RESEARCH-STATE.*$/  :/' >/dev/null 2>&1; then
    o="$(bash "$t/migrate-backlogs.sh" "$TMP/emptydir" 2>&1)"
    grep -q '^absent-input: no RESEARCH-STATE' <<<"$o" && no "teeth I: mutant still typed — THEATER" || ok "teeth I: absent-input silenced -> case 11a has teeth"
  else no "teeth I: mutant could not be built"; fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
