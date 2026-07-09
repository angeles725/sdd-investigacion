#!/usr/bin/env bash
# research-sdd-archive.test.sh — RED-FIRST harness for research-sdd-archive.sh (SDD-borrow #4).
#
# The discriminating behaviour is the GATE: archive must REFUSE to close a corpus whose living mirror is
# inconsistent (verify-state FAIL — the premature-STOP bug) or whose source registry is broken
# (verify-sources FAIL), and must only do its SAFE deterministic bookkeeping (regenerate CATALOG, touch
# INDEX) once BOTH gates pass. --dry-run must mutate NOTHING. --prove-teeth neuters the gate in a mutant
# and asserts the STALE fixture then archives (exit 0) instead of refusing — proving the gate has teeth.
#
# Usage: research-sdd-archive.test.sh [--prove-teeth]   Exit: 0 all held · 1 regression.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../research-sdd-archive.sh"
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
TMP="$(mktemp -d)"; trap 'chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

# A consistent, gate-passing corpus: coverage ratio matches (no all-closed-but-pending desync), no
# preserved-source markers (so verify-sources is a clean no-op), one block on disk. gen-catalog.py is
# copied from the kit templates into <corpus>/tools/ so the CATALOG-regen step has something to run.
KIT="$(cd "$HERE/../.." && pwd)"
mkgood() {
  local corpus="$1"; mkdir -p "$corpus/tools"
  cp "$KIT/templates/gen-catalog.py" "$corpus/tools/gen-catalog.py"
  cat > "$corpus/RESEARCH-STATE.md" <<'EOF'
# T — Research State

## Coverage

- **Covered blocks**: 1 (B1)
- **Coverage metric**: 2 / 3 closed

## Gap-backlog (prioritized)

| Priority | Gap | Artifact type / source | Status |
|---|---|---|---|
| high | still-open gap | web | pending |

## Iteration history

| # | Date | Gap closed | Block | Delegated? · model tier | New gaps uncovered |
|---|---|---|---|---|---|
| 1 | 2026-07-07 | first gap | B1 | no · inline | 1 |

## Stop control

- **Open gaps — read-only investigable**: 1
EOF
  cat > "$corpus/t-block1.md" <<'EOF'
# Block 1 — the first thing
Body.
EOF
  : > "$corpus/INDEX.md"
}

echo "== research-sdd-archive.test.sh =="

# 1 — a consistent corpus archives cleanly (exit 0, reports archived)
d="$TMP/good"; mkgood "$d"
out="$(bash "$SUT" "$d" 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok "gate-passing corpus archives (exit 0)" || no "good corpus exit=$rc (want 0) :: $out"

# 2 — GATE (verify-state): coverage claims ALL closed while backlog still pending → REFUSE (exit 3)
d="$TMP/stale"; mkgood "$d"
# rewrite the coverage metric to the all-closed-but-pending desync (the premature-STOP bug)
sed -i 's#2 / 3 closed#3 / 3 closed#' "$d/RESEARCH-STATE.md"
out="$(bash "$SUT" "$d" 2>&1)"; rc=$?
[ "$rc" = 3 ] && ok "stale mirror REFUSED (exit 3)" || no "stale corpus exit=$rc (want 3) :: $out"

# 3 — a REFUSED archive must NOT have mutated (CATALOG.md must not appear on a stale corpus)
[ ! -f "$d/CATALOG.md" ] && ok "refused archive did not regenerate CATALOG" || no "refused archive still wrote CATALOG.md"

# 4 — GATE (verify-sources): a block cites [CERT-doc] but there is no sources/SOURCES.md → REFUSE (exit 3)
d="$TMP/nosrc"; mkgood "$d"
printf '\nThis leans on a datasheet [CERT-doc].\n' >> "$d/t-block1.md"
out="$(bash "$SUT" "$d" 2>&1)"; rc=$?
[ "$rc" = 3 ] && ok "missing SOURCES.md REFUSED (exit 3)" || no "no-registry corpus exit=$rc (want 3) :: $out"

# 5 — the mechanical step actually fires: CATALOG.md is (re)generated on a gate-passing corpus
d="$TMP/regen"; mkgood "$d"
bash "$SUT" "$d" >/dev/null 2>&1
if [ -f "$d/CATALOG.md" ] && grep -q 'the first thing' "$d/CATALOG.md"; then
  ok "CATALOG regenerated from blocks on a clean archive"
else no "CATALOG.md not regenerated (or missing the block title)"; fi

# 6 — --dry-run mutates NOTHING (no CATALOG.md created) yet still exits 0
d="$TMP/dry"; mkgood "$d"
bash "$SUT" "$d" --dry-run >/dev/null 2>&1; rc=$?
if [ "$rc" = 0 ] && [ ! -f "$d/CATALOG.md" ]; then ok "--dry-run exits 0 and writes no CATALOG"
else no "--dry-run rc=$rc / CATALOG present=$([ -f "$d/CATALOG.md" ] && echo yes || echo no)"; fi

# 7 — no RESEARCH-STATE → nothing to archive → exit 2 (bad target for this tool)
d="$TMP/empty"; mkdir -p "$d"
bash "$SUT" "$d" >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok "no RESEARCH-STATE → exit 2" || no "empty target exit=$rc (want 2)"

# 8 — nested corpus (state under corpus/) resolves and archives
d="$TMP/nested"; mkgood "$d/corpus"; : > "$d/app.html"
bash "$SUT" "$d" >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && [ -f "$d/corpus/CATALOG.md" ] && ok "nested corpus/ resolves and archives" || no "nested corpus exit=$rc / catalog=$([ -f "$d/corpus/CATALOG.md" ] && echo yes || echo no)"

# 9 — iteration-history over the §8 collapse threshold (>25 rows) is FLAGGED as a follow-up
d="$TMP/bighist"; mkgood "$d"
{ for i in $(seq 2 30); do echo "| $i | 2026-07-07 | gap $i | B$i | no · inline | 0 |"; done; } >> "$d/RESEARCH-STATE.md"
out="$(bash "$SUT" "$d" 2>&1)"
printf '%s' "$out" | grep -qiE 'collapse|iteration.history' && ok "history over threshold is flagged as a follow-up" || no "history-collapse follow-up not surfaced"

# 10 — the close checklist surfaces the §18 retro follow-up
d="$TMP/checklist"; mkgood "$d"
out="$(bash "$SUT" "$d" 2>&1)"
printf '%s' "$out" | grep -qiE 'retro' && ok "checklist surfaces the §18 retro follow-up" || no "retro follow-up not surfaced"

# 11 — bad usage (no target dir) → exit 2
bash "$SUT" >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok "no args → exit 2" || no "no-args exit=$rc (want 2)"

# 12 — an unreadable subtree within the target must NOT crash the tool (was: set -e + find|sort|head aborted
#      silently with exit 1 before the banner). The tool should degrade and still archive.
d="$TMP/lockedtree"; mkgood "$d"; mkdir -p "$d/lockeddir"; chmod 000 "$d/lockeddir"
out="$(bash "$SUT" "$d" 2>&1)"; rc=$?
chmod 0755 "$d/lockeddir" 2>/dev/null
if [ "$rc" = 0 ] && printf '%s' "$out" | grep -q 'research-sdd-archive:'; then
  ok "unreadable subtree degrades — banner prints, exit 0 (no silent set -e abort)"
else no "unreadable subtree: exit=$rc / banner=$(printf '%s' "$out" | grep -c 'research-sdd-archive:') :: $out"; fi

# 13 — a MISSING/broken gate linter must fail CLOSED and be reported DISTINCTLY (not as a stale-mirror FAIL).
d="$TMP/brokenlinter"; mkgood "$d"
tb="$TMP/tb"; mkdir -p "$tb"
cp "$SUT" "$tb/research-sdd-archive.sh"
cp "$HERE/../verify-sources.sh" "$tb/verify-sources.sh"   # present + passing
# verify-state.sh deliberately NOT copied → the gate call resolves to a missing file (rc 127)
out="$(bash "$tb/research-sdd-archive.sh" "$d" 2>&1)"; rc=$?
if [ "$rc" = 3 ] && printf '%s' "$out" | grep -qi 'did not run' && [ ! -f "$d/CATALOG.md" ]; then
  ok "missing linter → fail-closed (exit 3), reported as 'did not run', no mutation"
else no "broken linter: exit=$rc / 'did not run'=$(printf '%s' "$out" | grep -ci 'did not run') / catalog=$([ -f "$d/CATALOG.md" ] && echo yes || echo no)"; fi

# 14 — the blocks-on-disk mirror fact uses gen-catalog's strict discriminator: a `blocked-notes.md` decoy
#      must NOT inflate the count (was: loose `*block*.md` glob counted it).
d="$TMP/decoy"; mkgood "$d"; printf '# not a block\n' > "$d/blocked-notes.md"
out="$(bash "$SUT" "$d" 2>&1)"
printf '%s' "$out" | grep -qE 'blocks on disk : 1( |$|·)' && ok "strict block count ignores 'blocked-notes.md' decoy" \
  || no "block count inflated by decoy :: $(printf '%s' "$out" | grep 'blocks on disk')"

# 15 — a failing INDEX touch must DEGRADE (honest report), never abort mid-consolidate (was: set -e killed it
#      after CATALOG regen, dropping the whole checklist). Skipped as no-op under root (touch always succeeds).
d="$TMP/rotouch"; mkgood "$d"; chmod 000 "$d/INDEX.md"
out="$(bash "$SUT" "$d" 2>&1)"; rc=$?
chmod 0644 "$d/INDEX.md" 2>/dev/null
if [ "$rc" = 0 ] && printf '%s' "$out" | grep -q 'archived'; then
  ok "failing INDEX touch degrades — checklist still prints, exit 0 (no mid-abort)"
else no "touch-fail abort: exit=$rc did not reach 'archived.' :: $out"; fi

# 16 — GATE (scan-secrets): a high-confidence secret VALUE leaked into an authored block → REFUSE (exit 3).
#      The fixture is plain mkgood (passes verify-state AND verify-sources) plus one leaked AWS key, so this
#      isolates the scan-secrets gate: before the wiring the corpus archives clean at exit 0; the gate must
#      flip it to a fail-closed exit 3 and print a scan-secrets FAIL line.
d="$TMP/secret"; mkgood "$d"
printf '\nLeaked on deploy: AKIAIOSFODNN7EXAMPLE\n' >> "$d/t-block1.md"
out="$(bash "$SUT" "$d" 2>&1)"; rc=$?
if [ "$rc" = 3 ] && printf '%s' "$out" | grep -qiE 'scan-secrets .*FAIL'; then
  ok "leaked secret VALUE REFUSED (exit 3, scan-secrets FAIL)"
else no "secret corpus exit=$rc (want 3) / scan-secrets FAIL=$(printf '%s' "$out" | grep -ciE 'scan-secrets .*FAIL') :: $out"; fi

# 17 — CONTROL: the SAME fixture WITHOUT the secret must NOT refuse on scan-secrets (gate passes → exit 0).
d="$TMP/nosecret"; mkgood "$d"
out="$(bash "$SUT" "$d" 2>&1)"; rc=$?
if [ "$rc" = 0 ] && printf '%s' "$out" | grep -qE 'scan-secrets .*: ok'; then
  ok "secret-free corpus passes the scan-secrets gate (exit 0)"
else no "clean corpus exit=$rc (want 0) / scan-secrets ok=$(printf '%s' "$out" | grep -cE 'scan-secrets .*: ok') :: $out"; fi

# 18 — TEMPLATE is not real state: a dir holding ONLY the kit `RESEARCH-STATE.template.md` (placeholders +
#      the CHECK-3 doc example, pending backlog) must be treated as NO state to archive → exit 2, and must
#      NOT run the gate against the template. The state-resolving find must exclude `*.template.md`. RED
#      before the fix: the template was resolved as the state file; its placeholder desync tripped
#      verify-state and archive REFUSED (exit 3) instead of reporting nothing to archive (exit 2).
d="$TMP/tmplonly"; mkdir -p "$d"
cat > "$d/RESEARCH-STATE.template.md" <<'EOF'
# <SUBJECT> — Research State

## Coverage

- **Coverage metric**: 16 / 16 closed  (e.g. 16/16 then 26/26)

## Gap-backlog (prioritized)

| Priority | Gap | Artifact type / source | Status |
|---|---|---|---|
| high | <research question> | web | pending |

## Stop control

- **Open gaps — read-only investigable**: 1
EOF
bash "$SUT" "$d" >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok "template-only → exit 2 (*.template.md excluded, nothing to archive)" || no "template-only exit=$rc (want 2 — template must not resolve as state)"

# 19 — POSITIVE CONTROL: a gate-passing corpus with a RESEARCH-STATE.template.md alongside its real
#      RESEARCH-STATE.md still archives cleanly (exit 0) — the real state is used, the template ignored.
#      Pins that the exclusion does not drop real state.
d="$TMP/real-plus-template"; mkgood "$d"
cat > "$d/RESEARCH-STATE.template.md" <<'EOF'
# <SUBJECT> — Research State
- **Coverage metric**: 16 / 16 closed  (e.g. 16/16 then 26/26)
| high | <placeholder> | web | pending |
EOF
bash "$SUT" "$d" >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && ok "real state + template coexist → archives via the real state (exit 0)" || no "real-plus-template exit=$rc (want 0)"

# NEGATIVE CONTROL — neuter the gate in a mutant; the STALE fixture must then archive (exit 0) not refuse.
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: neuter the gate in a mutant, expect the stale fixture to archive instead of refusing --"
  mutant="$TMP/archive.MUTANT.sh"
  # force the gate to always pass by making the refusal condition unreachable
  sed 's/gate_rc=1/gate_rc=0/g' "$SUT" > "$mutant"
  cp "$HERE/../verify-state.sh" "$TMP/verify-state.sh"
  cp "$HERE/../verify-sources.sh" "$TMP/verify-sources.sh"
  cp "$HERE/../scan-secrets.sh" "$TMP/scan-secrets.sh"
  d="$TMP/teeth"; mkgood "$d"; sed -i 's#2 / 3 closed#3 / 3 closed#' "$d/RESEARCH-STATE.md"
  bash "$mutant" "$d" >/dev/null 2>&1; mrc=$?
  if [ "$mrc" = 0 ]; then ok "teeth: gate-neutered mutant archives a stale corpus → gate test has teeth"
  else no "teeth: mutant exit=$mrc — gate not exercised (THEATER)"; fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
