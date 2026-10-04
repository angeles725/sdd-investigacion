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
tree_sum() { (cd "$1" && find . -type f -print0 | sort -z | xargs -0 sha1sum 2>/dev/null; find . -print | sort); }

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
  # I: the absent-input typed line silenced
  t="$(mk_tree I)"
  if mutant_sed "$SUT" "$t/migrate-backlogs.sh" 's/^  echo "absent-input: no RESEARCH-STATE.*$/  :/' >/dev/null 2>&1; then
    o="$(bash "$t/migrate-backlogs.sh" "$TMP/emptydir" 2>&1)"
    grep -q '^absent-input: no RESEARCH-STATE' <<<"$o" && no "teeth I: mutant still typed — THEATER" || ok "teeth I: absent-input silenced -> case 11a has teeth"
  else no "teeth I: mutant could not be built"; fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
