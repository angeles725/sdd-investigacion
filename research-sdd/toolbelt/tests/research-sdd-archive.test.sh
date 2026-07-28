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
# preserved-source markers (so verify-sources is a clean no-op), one block on disk. eje #2: NO per-target
# gen-catalog.py copy is seeded — a corpus without one has research-sdd-archive.sh drive the KIT generator
# over the corpus root (the default authority; no drift). A target MAY still ship a bespoke local copy that
# wins — that prefer-local path is pinned separately in case 5b.
mkgood() {
  local corpus="$1"; mkdir -p "$corpus"
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
  # Seed the research-state.v1 envelope so the corpus passes verify-state's new envelope gate (else the
  # archive's verify-state gate REFUSES on the missing envelope). --sync-state derives from this same corpus.
  bash "$HERE/../research-sdd-status.sh" "$corpus" --sync-state >/dev/null 2>&1
}

# mkgood_git <corpus> <retro-git-date> <block-git-date> <retro-mtime> <block-mtime> : a hermetic git
# corpus like mkgood (same RESEARCH-STATE/INDEX/one-block shape), but the retro and block files' git
# FIRST-COMMIT dates and file mtimes are INDEPENDENTLY controlled: GIT_AUTHOR_DATE/GIT_COMMITTER_DATE make
# git history deterministic and hermetically fakeable (contra a stale claim once in this file — the sibling
# stage-retro.test.sh already builds hermetic git repos this way via its `mkrepo` helper), and `touch -d`
# sets an independent mtime. This lets a case set the git dates and mtimes to say OPPOSITE things, proving
# the MISSING-RETRO detector reads the git-added date (rsdd_added_epoch), not mtime.
mkgood_git() {
  local corpus="$1" rdate="$2" bdate="$3" rmtime="$4" bmtime="$5"
  mkdir -p "$corpus"
  git -C "$corpus" init -q -b main
  git -C "$corpus" config user.email t@example.com
  git -C "$corpus" config user.name tester
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
  : > "$corpus/INDEX.md"
  git -C "$corpus" add -A
  GIT_AUTHOR_DATE="2026-01-01T00:00:00" GIT_COMMITTER_DATE="2026-01-01T00:00:00" \
    git -C "$corpus" commit -q -m baseline
  mkdir -p "$corpus/retros"
  printf '# retro\n' > "$corpus/retros/2026-retro-focus.md"
  git -C "$corpus" add -A
  GIT_AUTHOR_DATE="$rdate" GIT_COMMITTER_DATE="$rdate" git -C "$corpus" commit -q -m "add retro"
  touch -d "$rmtime" "$corpus/retros/2026-retro-focus.md"
  cat > "$corpus/t-block1.md" <<'EOF'
# Block 1 — the first thing
Body.
EOF
  git -C "$corpus" add -A
  GIT_AUTHOR_DATE="$bdate" GIT_COMMITTER_DATE="$bdate" git -C "$corpus" commit -q -m "add block1"
  touch -d "$bmtime" "$corpus/t-block1.md"
  bash "$HERE/../research-sdd-status.sh" "$corpus" --sync-state >/dev/null 2>&1
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
out="$(bash "$SUT" "$d" 2>&1)"
if [ -f "$d/CATALOG.md" ] && grep -q 'the first thing' "$d/CATALOG.md"; then
  ok "CATALOG regenerated from blocks on a clean archive"
else no "CATALOG.md not regenerated (or missing the block title)"; fi
# 5a — with NO local copy, the KIT generator is used (default authority, no drift).
grep -q 'via kit generator' <<<"$out" && ok "no local copy → regen via kit generator" \
  || no "expected 'via kit generator' in report :: $(grep -i catalog <<<"$out" | head -1)"

# 5b — PREFER-LOCAL: a target with a BESPOKE tools/gen-catalog.py (mature corpora ship one to catalog
# corpus-specific structures the generic can't express) WINS over the kit generator. Proven with a local
# generator that writes a DISTINCTIVE marker the kit generator never would — if archive used the kit generic
# instead, the marker is absent and the report says 'kit generator'. This pins the regression fix with teeth.
d="$TMP/preferlocal"; mkgood "$d"; mkdir -p "$d/tools"
cat > "$d/tools/gen-catalog.py" <<'PY'
import sys
from pathlib import Path
ROOT = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent
(ROOT / "CATALOG.md").write_text("BESPOKE-LOCAL-GENERATOR-RAN\n", encoding="utf-8")
PY
out="$(bash "$SUT" "$d" 2>&1)"
if grep -q 'BESPOKE-LOCAL-GENERATOR-RAN' "$d/CATALOG.md" 2>/dev/null && grep -q 'via local generator' <<<"$out"; then
  ok "local tools/gen-catalog.py WINS over the kit generator (regression fix)"
else no "prefer-local failed :: catalog=$(head -1 "$d/CATALOG.md" 2>/dev/null) :: $(grep -i catalog <<<"$out" | head -1)"; fi

# 5c — SYMLINKED local copy (JD both-confirmed): a tools/gen-catalog.py that is a SYMLINK to the shared kit
# generator must still write CATALOG.md into the CORPUS, not the symlink target's own tree. Before the fix,
# archive invoked it no-arg and Path(__file__).resolve() followed the symlink, so ROOT=parent.parent landed
# on the target's tree (CATALOG written there + false success). The fix passes argv=corpus, honored by an
# argv-aware generator. Teeth: the symlink target lives elsewhere, so a no-arg resolve writes THERE, not here.
d="$TMP/symlinkgen"; mkgood "$d"; mkdir -p "$d/tools" "$TMP/fakekit"
cat > "$TMP/fakekit/gen-catalog.py" <<'PY'
import sys
from pathlib import Path
ROOT = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 and sys.argv[1] else Path(__file__).resolve().parent.parent
(ROOT / "CATALOG.md").write_text("SYMLINKED-GEN-RAN\n", encoding="utf-8")
PY
ln -s "$TMP/fakekit/gen-catalog.py" "$d/tools/gen-catalog.py"
rm -f "$TMP/CATALOG.md"   # the WRONG location a no-arg resolve would target (parent.parent of fakekit)
out="$(bash "$SUT" "$d" 2>&1)"
if grep -q 'SYMLINKED-GEN-RAN' "$d/CATALOG.md" 2>/dev/null && [ ! -f "$TMP/CATALOG.md" ]; then
  ok "symlinked local generator writes CATALOG into the corpus, not the symlink target's tree"
else no "symlink-gen: corpus-catalog=$([ -f "$d/CATALOG.md" ] && echo yes || echo NO) wrong-loc=$([ -f "$TMP/CATALOG.md" ] && echo WRITTEN || echo clean)"; fi

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
grep -qiE 'collapse|iteration.history' <<<"$out" && ok "history over threshold is flagged as a follow-up" || no "history-collapse follow-up not surfaced"

# 10 — the close checklist surfaces the §18 retro follow-up
d="$TMP/checklist"; mkgood "$d"
out="$(bash "$SUT" "$d" 2>&1)"
grep -qiE 'retro' <<<"$out" && ok "checklist surfaces the §18 retro follow-up" || no "retro follow-up not surfaced"

# 10a — a codegen/ deliverable surfaces the §19 PARITY follow-up (verify-parity is a targeted (deliverable,
#       block) check, not a corpus-wide gate, so archive REMINDS rather than auto-gates). No codegen/ → silent.
d="$TMP/parity-reminder"; mkgood "$d"; mkdir -p "$d/codegen"
out="$(bash "$SUT" "$d" 2>&1)"
grep -qiE 'PARITY.*verify-parity' <<<"$out" && ok "codegen/ deliverable surfaces the §19 parity follow-up" || no "parity follow-up not surfaced with codegen/"
d="$TMP/no-codegen"; mkgood "$d"
out="$(bash "$SUT" "$d" 2>&1)"
grep -qiE 'PARITY.*verify-parity' <<<"$out" && no "parity follow-up surfaced WITHOUT codegen/ (should be silent)" || ok "no codegen/ → no parity follow-up (silent)"

# 10b — a codegen/ deliverable also emits a LOUD stderr WARN (advisory, not a hard refuse) that verify-parity
#       was NOT run — so a shipped deliverable can't close green with deliverable↔block parity unchecked. Exit stays 0.
d="$TMP/parity-warn"; mkgood "$d"; mkdir -p "$d/codegen"
err="$(bash "$SUT" "$d" 2>&1 1>/dev/null)"; rc=$?
grep -qiE 'WARN:.*deliverable.*verify-parity' <<<"$err" && ok "codegen/ deliverable emits a loud stderr WARN" || no "no loud stderr WARN with codegen/ :: $(head -1 <<<"$err")"
[ "$rc" = 0 ] && ok "codegen/ WARN keeps exit 0 (advisory, not a refuse)" || no "codegen/ WARN flipped exit to $rc (want 0)"
d="$TMP/no-codegen-warn"; mkgood "$d"
err="$(bash "$SUT" "$d" 2>&1 1>/dev/null)"
grep -qiE 'WARN:.*deliverable.*verify-parity' <<<"$err" && no "parity WARN emitted WITHOUT codegen/ (should be silent)" || ok "no codegen/ → no parity WARN (silent)"

# 11 — bad usage (no target dir) → exit 2
bash "$SUT" >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok "no args → exit 2" || no "no-args exit=$rc (want 2)"

# 12 — an unreadable subtree within the target must NOT crash the tool (was: set -e + find|sort|head aborted
#      silently with exit 1 before the banner). The tool should degrade and still archive.
d="$TMP/lockedtree"; mkgood "$d"; mkdir -p "$d/lockeddir"; chmod 000 "$d/lockeddir"
out="$(bash "$SUT" "$d" 2>&1)"; rc=$?
chmod 0755 "$d/lockeddir" 2>/dev/null
if [ "$rc" = 0 ] && grep -q 'research-sdd-archive:' <<<"$out"; then
  ok "unreadable subtree degrades — banner prints, exit 0 (no silent set -e abort)"
else no "unreadable subtree: exit=$rc / banner=$(grep -c 'research-sdd-archive:' <<<"$out") :: $out"; fi

# 13 — a MISSING/broken gate linter must fail CLOSED and be reported DISTINCTLY (not as a stale-mirror FAIL).
d="$TMP/brokenlinter"; mkgood "$d"
tb="$TMP/tb"; mkdir -p "$tb/lib"
cp "$SUT" "$tb/research-sdd-archive.sh"
cp "$HERE/../verify-sources.sh" "$tb/verify-sources.sh"   # present + passing
cp "$HERE/../lib/retro-status.sh" "$tb/lib/retro-status.sh"  # required helper
cp "$HERE/../lib/state-files.sh"  "$tb/lib/state-files.sh"   # required helper (uf-gate loop)
cp "$HERE/../scan-secrets.sh"     "$tb/scan-secrets.sh"       # required helper (gate)
# verify-state.sh deliberately NOT copied → the gate call resolves to a missing file (rc 127)
out="$(bash "$tb/research-sdd-archive.sh" "$d" 2>&1)"; rc=$?
if [ "$rc" = 3 ] && grep -qi 'did not run' <<<"$out" && [ ! -f "$d/CATALOG.md" ]; then
  ok "missing linter → fail-closed (exit 3), reported as 'did not run', no mutation"
else no "broken linter: exit=$rc / 'did not run'=$(grep -ci 'did not run' <<<"$out") / catalog=$([ -f "$d/CATALOG.md" ] && echo yes || echo no)"; fi

# 14 — the blocks-on-disk mirror fact uses gen-catalog's strict discriminator: a `blocked-notes.md` decoy
#      must NOT inflate the count (was: loose `*block*.md` glob counted it).
d="$TMP/decoy"; mkgood "$d"; printf '# not a block\n' > "$d/blocked-notes.md"
# verify-state's covered_blocks uses the loose *block*.md glob (which DOES match 'blocked-notes.md'), so the
# envelope must be re-seeded to that count or the gate REFUSES; the archive's 'blocks on disk' mirror below
# still uses gen-catalog's STRICT discriminator (which ignores the decoy → 1), which is what this pins.
bash "$HERE/../research-sdd-status.sh" "$d" --sync-state >/dev/null 2>&1
out="$(bash "$SUT" "$d" 2>&1)"
grep -qE 'blocks on disk : 1( |$|·)' <<<"$out" && ok "strict block count ignores 'blocked-notes.md' decoy" \
  || no "block count inflated by decoy :: $(grep 'blocks on disk' <<<"$out")"

# 15 — a failing INDEX touch must DEGRADE (honest report), never abort mid-consolidate (was: set -e killed it
#      after CATALOG regen, dropping the whole checklist). Skipped as no-op under root (touch always succeeds).
d="$TMP/rotouch"; mkgood "$d"; chmod 000 "$d/INDEX.md"
out="$(bash "$SUT" "$d" 2>&1)"; rc=$?
chmod 0644 "$d/INDEX.md" 2>/dev/null
if [ "$rc" = 0 ] && grep -q 'archived' <<<"$out"; then
  ok "failing INDEX touch degrades — checklist still prints, exit 0 (no mid-abort)"
else no "touch-fail abort: exit=$rc did not reach 'archived.' :: $out"; fi

# 16 — GATE (scan-secrets): a high-confidence secret VALUE leaked into an authored block → REFUSE (exit 3).
#      The fixture is plain mkgood (passes verify-state AND verify-sources) plus one leaked AWS key, so this
#      isolates the scan-secrets gate: before the wiring the corpus archives clean at exit 0; the gate must
#      flip it to a fail-closed exit 3 and print a scan-secrets FAIL line.
d="$TMP/secret"; mkgood "$d"
printf '\nLeaked on deploy: AKIAIOSFODNN7EXAMPLE\n' >> "$d/t-block1.md"
out="$(bash "$SUT" "$d" 2>&1)"; rc=$?
if [ "$rc" = 3 ] && grep -qiE 'scan-secrets .*FAIL' <<<"$out"; then
  ok "leaked secret VALUE REFUSED (exit 3, scan-secrets FAIL)"
else no "secret corpus exit=$rc (want 3) / scan-secrets FAIL=$(grep -ciE 'scan-secrets .*FAIL' <<<"$out") :: $out"; fi

# 17 — CONTROL: the SAME fixture WITHOUT the secret must NOT refuse on scan-secrets (gate passes → exit 0).
d="$TMP/nosecret"; mkgood "$d"
out="$(bash "$SUT" "$d" 2>&1)"; rc=$?
if [ "$rc" = 0 ] && grep -qE 'scan-secrets .*: ok' <<<"$out"; then
  ok "secret-free corpus passes the scan-secrets gate (exit 0)"
else no "clean corpus exit=$rc (want 0) / scan-secrets ok=$(grep -cE 'scan-secrets .*: ok' <<<"$out") :: $out"; fi

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

# 20 — MISSING-RETRO detector (Feature #25a, §18): a corpus with blocks on disk but NO retro under retros/
#      surfaces a LOUD advisory WARN (feedback for THIS run may be lost) — exit stays 0 (advisory, like the
#      codegen/ parity WARN), and it NEVER auto-generates a retro (propose-never-apply). mkgood has one block;
#      the archive detector is immediate (no grace window) so the WARN fires as soon as the corpus advances.
d="$TMP/missingretro"; mkgood "$d"
err="$(bash "$SUT" "$d" 2>&1 1>/dev/null)"; rc=$?
if [ "$rc" = 0 ] && grep -qiE 'retro .*may be' <<<"$err" && grep -qi 'MISSING-RETRO' <<<"$err"; then
  ok "blocks + no retro → MISSING-RETRO WARN (advisory, exit 0)"
else no "no MISSING-RETRO WARN with blocks+no retro :: rc=$rc :: $(head -2 <<<"$err")"; fi

# 20a — an OLD retro (mtime older than the newest block) still counts as 'corpus advanced past the retro' →
#       WARN. TMP is not a git repo, so the advancement signal is the block mtime (git commit epoch is 0).
#       The archive detector fires immediately when the block is newer than the newest retro.
d="$TMP/oldretro"; mkgood "$d"; mkdir -p "$d/retros"
: > "$d/retros/2020-01-01-focus.md"; touch -d '2020-01-01' "$d/retros/2020-01-01-focus.md"
out="$(bash "$SUT" "$d" 2>&1)"; rc=$?
if [ "$rc" = 0 ] && grep -qi 'MISSING-RETRO' <<<"$out"; then
  ok "blocks newer than an OLD retro → MISSING-RETRO WARN"
else no "old-retro corpus did not WARN :: rc=$rc :: $(grep -i retro <<<"$out" | head -2)"; fi

# 20b — NEGATIVE CONTROL: a retro NEWER than every block (run just closed with its retro) must NOT WARN — the
#       detector fires only on genuine advancement past the newest retro.
d="$TMP/freshretro"; mkgood "$d"; mkdir -p "$d/retros"
: > "$d/retros/2030-01-01-focus.md"; touch -d '2030-01-01' "$d/retros/2030-01-01-focus.md"
out="$(bash "$SUT" "$d" 2>&1)"; rc=$?
if [ "$rc" = 0 ] && ! grep -qi 'MISSING-RETRO' <<<"$out"; then
  ok "retro newer than blocks → no MISSING-RETRO WARN (negative control)"
else no "fresh-retro corpus WARNed spuriously :: rc=$rc :: $(grep -i retro <<<"$out" | head -2)"; fi

# 20c — EXCLUDED-ONLY RETROS (B2): a corpus with blocks AND a §18-excluded retro (carrying
#       '<!-- kit-retro: exclude -->') is still effectively retro-free from the §18 perspective.
#       The MISSING-RETRO WARN must still fire (the excluded retro must NOT suppress it), and
#       the 'retros: N' mirror fact must count 0 (excluded files are not §18 kit retros).
#       RED before wiring retro_is_excluded in archive.sh: the old find-pipe-wc counted the
#       excluded file, reporting retros:1 and suppressing MISSING-RETRO. The archive detector
#       fires immediately (no grace window): blocks > 0 && retros == 0.
d="$TMP/excluded-retro"; mkgood "$d"; mkdir -p "$d/retros"
printf '<!-- kit-retro: exclude -->\n# client retro — not §18\n' > "$d/retros/client.md"
touch "$d/retros/client.md"   # FRESH mtime — would suppress MISSING-RETRO if counted as a real retro
out="$(bash "$SUT" "$d" 2>&1)"; rc=$?
if [ "$rc" = 0 ] \
   && grep -qi 'MISSING-RETRO' <<<"$out" \
   && grep -qE 'retros: 0( |$|\·|\·)' <<<"$out"; then
  ok "20c excluded-only retro → retros:0 + MISSING-RETRO WARN still fires (B2 wiring)"
else no "20c excluded-retro: rc=$rc retros=$(grep 'retros:' <<<"$out" | head -1) :: $(grep -i retro <<<"$out" | head -2)"; fi

# 21 — GIT-ADDED-DATE path, exercised for real (Feature #25a): block git-added AFTER retro, but mtimes say
#      the OPPOSITE (retro mtime later than block mtime). A detector reading mtime instead of the git date
#      would stay silent; reading the git date correctly WARNs despite the misleading mtimes.
d="$TMP/git-warn"
mkgood_git "$d" "2026-01-10T00:00:00" "2026-03-01T00:00:00" "2030-01-01" "2020-01-01"
out="$(bash "$SUT" "$d" 2>&1)"; rc=$?
if [ "$rc" = 0 ] && grep -qi 'MISSING-RETRO' <<<"$out"; then
  ok "21 git-added-date: block added after retro (mtime says opposite) → WARN (git date wins)"
else
  no "21 git-added-date: block added after retro (mtime says opposite) → WARN (git date wins)" "rc=$rc :: $(grep -i retro <<<"$out" | head -2)"
fi

# 21a — NEGATIVE CONTROL for 21: git dates reversed (retro added AFTER block), mtimes again say the
#       opposite (block mtime later than retro mtime) → must NOT warn — the negative direction is also
#       driven by the git date, not a mtime coincidence.
d="$TMP/git-nowarn"
mkgood_git "$d" "2026-03-01T00:00:00" "2026-01-10T00:00:00" "2020-01-01" "2030-01-01"
out="$(bash "$SUT" "$d" 2>&1)"; rc=$?
if [ "$rc" = 0 ] && ! grep -qi 'MISSING-RETRO' <<<"$out"; then
  ok "21a git-added-date: retro added after block (mtime says opposite) → no WARN (git date wins)"
else
  no "21a git-added-date: retro added after block (mtime says opposite) → no WARN (git date wins)" "rc=$rc :: $(grep -i retro <<<"$out" | head -2)"
fi

# 21b — FIX-1 REGRESSION PIN (relative-target invocation): the SAME fixture as case 21 (block genuinely
#       added after retro by git date), invoked with a RELATIVE target from cwd=$TMP. Before the
#       relative-path absolutize fix, `target`/`corpus` stayed relative, `git -C "$corpus" log -- "$rf"`
#       double-resolved and never matched, EVERY file silently fell back to mtime, and the misleading
#       mtimes (case 21's fixture: retro mtime LATER than block mtime) would flip the verdict to "no WARN"
#       — exactly backwards. This must still WARN under a relative invocation.
d="$TMP/git-warn-rel"
mkgood_git "$d" "2026-01-10T00:00:00" "2026-03-01T00:00:00" "2030-01-01" "2020-01-01"
out="$(cd "$TMP" && bash "$SUT" "$(basename "$d")" 2>&1)"; rc=$?
if [ "$rc" = 0 ] && grep -qi 'MISSING-RETRO' <<<"$out"; then
  ok "21b RELATIVE target still resolves git dates correctly → WARN (FIX-1 regression pin)"
else
  no "21b RELATIVE target still resolves git dates correctly → WARN (FIX-1 regression pin)" "rc=$rc :: $(grep -i retro <<<"$out" | head -2)"
fi

# mkrun_git <corpus> <together|split> — a hermetic 2-block git corpus. baseline + retro commit (OLD dates),
# then the run's two blocks committed NEWER than the retro (so the since-retro window sees them). `together`
# lands B1+B2 in ONE commit (the ONE-BLOCK-PER-COMMIT violation); `split` gives each its own commit (clean).
mkrun_git() {
  local corpus="$1" mode="$2"
  mkdir -p "$corpus"
  git -C "$corpus" init -q -b main
  git -C "$corpus" config user.email t@example.com; git -C "$corpus" config user.name tester
  cat > "$corpus/RESEARCH-STATE.md" <<'EOF'
# T — Research State

## Coverage

- **Covered blocks**: 2 (B1, B2)
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
  : > "$corpus/INDEX.md"
  git -C "$corpus" add -A
  GIT_AUTHOR_DATE="2026-01-01T00:00:00" GIT_COMMITTER_DATE="2026-01-01T00:00:00" git -C "$corpus" commit -q -m baseline
  mkdir -p "$corpus/retros"; printf '# retro\n' > "$corpus/retros/2026-retro-focus.md"
  git -C "$corpus" add -A
  GIT_AUTHOR_DATE="2026-02-01T00:00:00" GIT_COMMITTER_DATE="2026-02-01T00:00:00" git -C "$corpus" commit -q -m "add retro"
  printf '# Block 1\nBody.\n' > "$corpus/t-block1.md"
  printf '# Block 2\nBody.\n' > "$corpus/t-block2.md"
  if [ "$mode" = together ]; then
    git -C "$corpus" add -A
    GIT_AUTHOR_DATE="2026-03-01T00:00:00" GIT_COMMITTER_DATE="2026-03-01T00:00:00" git -C "$corpus" commit -q -m "B1+B2 (violation)"
  else
    git -C "$corpus" add t-block1.md
    GIT_AUTHOR_DATE="2026-03-01T00:00:00" GIT_COMMITTER_DATE="2026-03-01T00:00:00" git -C "$corpus" commit -q -m "B1"
    git -C "$corpus" add t-block2.md
    GIT_AUTHOR_DATE="2026-03-02T00:00:00" GIT_COMMITTER_DATE="2026-03-02T00:00:00" git -C "$corpus" commit -q -m "B2"
  fi
  bash "$HERE/../research-sdd-status.sh" "$corpus" --sync-state >/dev/null 2>&1
}

# 22 — ONE-BLOCK-PER-COMMIT detector (retro delta): a commit that lands 2+ block files in THIS run (newer
#      than the newest retro) → advisory WARN + checklist follow-up, exit STILL 0 (never rewrites history).
d="$TMP/one-block-violation"; mkrun_git "$d" together
out="$(bash "$SUT" "$d" 2>&1)"; rc=$?
if [ "$rc" = 0 ] && grep -qi 'ONE-BLOCK-PER-COMMIT' <<<"$out"; then
  ok "commit landing 2 block files → ONE-BLOCK-PER-COMMIT WARN, exit still 0"
else no "one-block-violation: rc=$rc :: $(grep -iE 'one-block|block' <<<"$out" | head -1)"; fi

# 23 — CONTROL: the SAME two blocks, each in its OWN commit → NO ONE-BLOCK-PER-COMMIT WARN (exit 0). Pins the
#      detector on the per-commit block-file COUNT, not merely on "2 blocks exist in the run".
d="$TMP/one-block-clean"; mkrun_git "$d" split
out="$(bash "$SUT" "$d" 2>&1)"; rc=$?
if [ "$rc" = 0 ] && ! grep -qi 'ONE-BLOCK-PER-COMMIT' <<<"$out"; then
  ok "one block per commit (2 commits) → no ONE-BLOCK-PER-COMMIT WARN, exit 0"
else no "one-block-clean: rc=$rc :: $(grep -i 'one-block' <<<"$out" | head -1)"; fi

# mkrun_git_backlink <corpus> — a hermetic git corpus for the ONE-BLOCK-PER-COMMIT × §14 reconciliation:
# baseline + retro (OLD dates), then B1 in its OWN commit, then ONE iteration commit that ADDS B2 (a new
# block) AND MODIFIES B1 to add the §14 reciprocal 'corrected in B2' backlink — the exact shape the sibling
# verify-corrections feature now mandates in the same iteration. Both run-commits are newer than the retro.
mkrun_git_backlink() {
  local corpus="$1"
  mkdir -p "$corpus"
  git -C "$corpus" init -q -b main
  git -C "$corpus" config user.email t@example.com; git -C "$corpus" config user.name tester
  cat > "$corpus/RESEARCH-STATE.md" <<'EOF'
# T — Research State

## Coverage

- **Covered blocks**: 2 (B1, B2)
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
  : > "$corpus/INDEX.md"
  git -C "$corpus" add -A
  GIT_AUTHOR_DATE="2026-01-01T00:00:00" GIT_COMMITTER_DATE="2026-01-01T00:00:00" git -C "$corpus" commit -q -m baseline
  mkdir -p "$corpus/retros"; printf '# retro\n' > "$corpus/retros/2026-retro-focus.md"
  git -C "$corpus" add -A
  GIT_AUTHOR_DATE="2026-02-01T00:00:00" GIT_COMMITTER_DATE="2026-02-01T00:00:00" git -C "$corpus" commit -q -m "add retro"
  printf '# Block 1\nOriginal claim.\n' > "$corpus/t-block1.md"
  git -C "$corpus" add t-block1.md
  GIT_AUTHOR_DATE="2026-02-15T00:00:00" GIT_COMMITTER_DATE="2026-02-15T00:00:00" git -C "$corpus" commit -q -m "B1"
  # Iteration N+1: ADD B2 (new) AND MODIFY B1 to add the §14 backlink — one commit.
  printf '# Block 2\nRefines [Block 1] §1.\n' > "$corpus/t-block2.md"
  printf '# Block 1\nOriginal claim.\n\n> Note: corrected in B2.\n' > "$corpus/t-block1.md"
  git -C "$corpus" add -A
  GIT_AUTHOR_DATE="2026-03-01T00:00:00" GIT_COMMITTER_DATE="2026-03-01T00:00:00" git -C "$corpus" commit -q -m "B2 + §14 backlink into B1"
  bash "$HERE/../research-sdd-status.sh" "$corpus" --sync-state >/dev/null 2>&1
}

# 23a — ONE-BLOCK-PER-COMMIT × §14 reconciliation (retro delta): a single iteration that ADDS one new block
#       AND MODIFIES an existing block to add the §14 'corrected in BN' backlink must NOT trip the detector.
#       The detector counts only ADDED block files (git --diff-filter=A), so a backlink edit to an EXISTING
#       block is not a second "new block". RED before the fix: --name-only counted the modified B1 too, so the
#       B2-adding commit showed 2 block files → false ONE-BLOCK-PER-COMMIT WARN.
d="$TMP/one-block-backlink"; mkrun_git_backlink "$d"
out="$(bash "$SUT" "$d" 2>&1)"; rc=$?
if [ "$rc" = 0 ] && ! grep -qi 'ONE-BLOCK-PER-COMMIT' <<<"$out"; then
  ok "add 1 NEW block + modify 1 existing (§14 backlink) → no ONE-BLOCK-PER-COMMIT WARN (counts ADDED only)"
else no "one-block-backlink: rc=$rc :: $(grep -iE 'one-block|block' <<<"$out" | head -1)"; fi

# 24 — Retro FORMAT LINT — bare-text review-status marker → advisory WARN (exit stays 0).
#      A retro whose first line is a heading (not an HTML comment) and which carries 'review-status:'
#      as BARE TEXT is invisible to the sweep (retro_review_status returns empty) but NOT caught at
#      archive time. The lint must WARN, name the offending file, and keep exit 0 (advisory).
d="$TMP/format-lint-bare"; mkgood "$d"; mkdir -p "$d/retros"
cat > "$d/retros/2026-07-25-bad-format.md" <<'EOF'
# Retro §18 — some-target · focus · 2026-07-25

review-status: pending

Run summary: bad format.
EOF
out="$(bash "$SUT" "$d" 2>&1)"; rc=$?
if [ "$rc" = 0 ] \
   && grep -qi 'WARN.*2026-07-25-bad-format' <<<"$out" \
   && grep -qi 'bare text\|bare-text\|malform\|wrap.*<!--\|not.*HTML' <<<"$out"; then
  ok "24 bare-text review-status → format-lint WARN, exit 0 (advisory)"
else
  no "24 bare-text review-status → format-lint WARN, exit 0" "rc=$rc :: $(grep -i 'warn\|format\|bare' <<<"$out" | head -2)"
fi

# 24a — Retro FORMAT LINT — no marker at all → advisory WARN (exit stays 0).
#       A retro with NO review-status marker at all (created before the template seeded it)
#       must also be flagged. Exit stays 0 (advisory).
d="$TMP/format-lint-absent"; mkgood "$d"; mkdir -p "$d/retros"
cat > "$d/retros/2026-07-25-no-marker.md" <<'EOF'
# Retro §18 — some-target · focus · 2026-07-25

Run summary: completely absent marker.
EOF
out="$(bash "$SUT" "$d" 2>&1)"; rc=$?
if [ "$rc" = 0 ] \
   && grep -qi 'WARN.*2026-07-25-no-marker' <<<"$out"; then
  ok "24a absent review-status marker → format-lint WARN, exit 0 (advisory)"
else
  no "24a absent review-status marker → format-lint WARN, exit 0" "rc=$rc :: $(grep -i 'warn\|format\|marker' <<<"$out" | head -2)"
fi

# 24b — Retro FORMAT LINT — well-formed marker → NO warning. A correctly formed
#       '<!-- review-status: pending -->' on line 1 must NOT trigger the lint.
d="$TMP/format-lint-ok"; mkgood "$d"; mkdir -p "$d/retros"
cat > "$d/retros/2026-07-25-good-format.md" <<'EOF'
<!-- review-status: pending -->
# Retro §18 — some-target · focus · 2026-07-25

Run summary: correct format.
EOF
out="$(bash "$SUT" "$d" 2>&1)"; rc=$?
if [ "$rc" = 0 ] \
   && ! grep -qi 'WARN.*2026-07-25-good-format' <<<"$out"; then
  ok "24b well-formed marker → no format-lint WARN (negative control)"
else
  no "24b well-formed marker → no format-lint WARN (negative control)" "rc=$rc :: $(grep -i 'warn.*good-format' <<<"$out" | head -1)"
fi

# 25 — RETRO FORMAT LINT excludes index files. A 'RETROS-INDEX.md' (or any '*index*.md') under
#      retros/ is a generated table of contents, not a §18 retro — the lint must NOT warn about
#      a missing review-status marker in it. After adding '-not -iname '*index*.md'' to the find
#      predicate, the file is excluded. RED before the fix: the index triggers
#      "no review-status marker" WARN for every close.
d="$TMP/lint-index"; mkgood "$d"; mkdir -p "$d/retros"
printf '# Retros index\n\n| # | file |\n|---|---|\n| 1 | r1.md |\n' > "$d/retros/RETROS-INDEX.md"
out="$(bash "$SUT" "$d" 2>&1)"; rc=$?
if [ "$rc" = 0 ] && ! grep -qiE 'WARN.*RETROS-INDEX' <<<"$out"; then
  ok "25 RETROS-INDEX.md in retros/ → excluded from format lint (no WARN)"
else
  no "25 RETROS-INDEX.md in retros/ → excluded from format lint (no WARN)" "rc=$rc :: $(grep -iE 'warn.*index|index.*warn' <<<"$out" | head -1)"
fi

# ======================== undocumented_findings gate (C2 §18 retro delta) ==========================
# The archive refuses to close while undocumented_findings > 0 regardless of verify-state's WARN
# threshold (>3). This is stricter: any non-zero count means findings exist only in memory with no
# block, and closing while undocumented is exactly the failure mode C2 was written to eliminate.

# mkmulti <corpus> — two-focus corpus (RESEARCH-STATE-alpha.md + RESEARCH-STATE-beta.md),
# NO flat RESEARCH-STATE.md. Both focus state files are fully valid (pass verify-state after
# --sync-state). Each focus has one block on disk. Seeding: --sync-state derives covered_blocks,
# investigable_open, etc. from the real state text, so the envelope is always correct.
mkmulti() {
  local d="$1"; mkdir -p "$d"
  cat > "$d/RESEARCH-STATE-alpha.md" <<'EOF'
# Alpha — Research State
> Active focus.

## Coverage

- **Covered blocks**: 1 (alpha-block1)
- **Coverage metric**: 1 / 1 closed

## Gap-backlog (prioritized)

| Priority | Gap | Artifact type / source | Status |
|---|---|---|---|

## Iteration history

| # | Date | Gap closed | Block | Delegated? · model tier | New gaps uncovered |
|---|---|---|---|---|---|
| 1 | 2026-07-27 | first gap | alpha-block1 | no · inline | 0 |

## Stop control

- **Open gaps — read-only investigable**: 0
EOF
  cat > "$d/RESEARCH-STATE-beta.md" <<'EOF'
# Beta — Research State
> Active focus.

## Coverage

- **Covered blocks**: 1 (beta-block1)
- **Coverage metric**: 1 / 1 closed

## Gap-backlog (prioritized)

| Priority | Gap | Artifact type / source | Status |
|---|---|---|---|

## Iteration history

| # | Date | Gap closed | Block | Delegated? · model tier | New gaps uncovered |
|---|---|---|---|---|---|
| 1 | 2026-07-27 | first gap | beta-block1 | no · inline | 0 |

## Stop control

- **Open gaps — read-only investigable**: 0
EOF
  printf '# Alpha Block 1\nBody.\n' > "$d/alpha-block1.md"
  printf '# Beta Block 1\nBody.\n'  > "$d/beta-block1.md"
  : > "$d/INDEX.md"
  # Seed research-state.v1 envelope in both focuses so verify-state passes.
  bash "$HERE/../research-sdd-status.sh" "$d" --sync-state >/dev/null 2>&1
}

# 26 — undocumented_findings: 0 → archive passes (positive control; field present and clean).
# mkgood + --sync-state seeds the field to 0; replace it explicitly to make the intent clear.
d="$TMP/uf-ok"; mkgood "$d"
awk '/^undocumented_findings:/{$0="undocumented_findings: 0"} {print}' "$d/RESEARCH-STATE.md" > "$d/RS.tmp" && mv "$d/RS.tmp" "$d/RESEARCH-STATE.md"
out="$(bash "$SUT" "$d" 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok "26 undocumented_findings=0 → archive passes (exit 0)" || no "26 uf=0: exit=$rc (want 0) :: $out"

# 27 — undocumented_findings: 1 → REFUSED (exit 3); even a single unblocked finding must stop the close.
# Replace the seeded field value (0 → 1). Inject-before-marker would create a duplicate and the archive
# reads the first occurrence (0), so we REPLACE the existing line instead.
d="$TMP/uf-refuse"; mkgood "$d"
awk '/^undocumented_findings:/{$0="undocumented_findings: 1"} {print}' "$d/RESEARCH-STATE.md" > "$d/RS.tmp" && mv "$d/RS.tmp" "$d/RESEARCH-STATE.md"
out="$(bash "$SUT" "$d" 2>&1)"; rc=$?
[ "$rc" = 3 ] && grep -qi 'undocumented_findings' <<<"$out" \
  && ok "27 undocumented_findings=1 → REFUSED (exit 3, undocumented_findings in report)" \
  || no "27 uf=1: exit=$rc (want 3) / mention=$(grep -ci 'undocumented_findings' <<<"$out") :: $out"

# 28 — no undocumented_findings field (legacy corpus) → archive passes (field absent is treated as 0).
# Strip the field seeded by --sync-state to simulate a corpus written before this field existed.
d="$TMP/uf-absent"; mkgood "$d"
awk '!/^undocumented_findings:/' "$d/RESEARCH-STATE.md" > "$d/RS.tmp" && mv "$d/RS.tmp" "$d/RESEARCH-STATE.md"
out="$(bash "$SUT" "$d" 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok "28 no undocumented_findings field → archive passes (absent = 0, exit 0)" \
  || no "28 uf-absent: exit=$rc (want 0) :: $out"

# ======================== MULTI-FOCUS undocumented_findings gate (family fix) ==================
# The bug: line 90 hardcoded "$corpus/RESEARCH-STATE.md"; in a multi-focus corpus that file does
# not exist, so awk returns empty, ${_uf_val:-0} = "0", the gate silently passes, and the archive
# closes even when a focus has undocumented_findings > 0. The fix iterates ALL RESEARCH-STATE*.md
# files in the corpus. Tests 29-32 cover the four relevant cases; test 30 is the RED case that
# exposes the bug on the unfixed SUT.

# 29 — MULTI-FOCUS, both focuses UF=0 → archive passes (positive control).
d="$TMP/mf-uf-ok"; mkmulti "$d"
out="$(bash "$SUT" "$d" 2>&1)"; rc=$?
[ "$rc" = 0 ] \
  && ok "29 multi-focus UF=0 in both focuses → archive passes (exit 0)" \
  || no "29 mf uf=0: exit=$rc (want 0) :: $out"

# 30 — MULTI-FOCUS, alpha focus has UF=1 → REFUSED (exit 3). RED on unfixed SUT.
# The old hardcoded path ($corpus/RESEARCH-STATE.md) does not exist in a pure multi-focus
# corpus → awk returns empty → gate passes silently → archive exits 0 instead of 3.
d="$TMP/mf-uf-refuse"; mkmulti "$d"
awk '/^undocumented_findings:/{$0="undocumented_findings: 1"} {print}' \
  "$d/RESEARCH-STATE-alpha.md" > "$d/RS.tmp" && mv "$d/RS.tmp" "$d/RESEARCH-STATE-alpha.md"
out="$(bash "$SUT" "$d" 2>&1)"; rc=$?
[ "$rc" = 3 ] && grep -qi 'undocumented_findings' <<<"$out" \
  && ok "30 multi-focus UF=1 in alpha → REFUSED (exit 3, undocumented_findings in report)" \
  || no "30 mf uf=1 alpha: exit=$rc (want 3) / mention=$(grep -ci 'undocumented_findings' <<<"$out") :: $out"

# 31 — MULTI-FOCUS, beta focus has UF=2 → REFUSED (exit 3).
d="$TMP/mf-uf-beta"; mkmulti "$d"
awk '/^undocumented_findings:/{$0="undocumented_findings: 2"} {print}' \
  "$d/RESEARCH-STATE-beta.md" > "$d/RS.tmp" && mv "$d/RS.tmp" "$d/RESEARCH-STATE-beta.md"
out="$(bash "$SUT" "$d" 2>&1)"; rc=$?
[ "$rc" = 3 ] && grep -qi 'undocumented_findings' <<<"$out" \
  && ok "31 multi-focus UF=2 in beta → REFUSED (exit 3)" \
  || no "31 mf uf=2 beta: exit=$rc (want 3) :: $out"

# 32 — MULTI-FOCUS, UF absent in both focuses → archive passes (absent = 0, legacy compat).
d="$TMP/mf-uf-absent"; mkmulti "$d"
awk '!/^undocumented_findings:/' "$d/RESEARCH-STATE-alpha.md" > "$d/RS.tmp" && mv "$d/RS.tmp" "$d/RESEARCH-STATE-alpha.md"
awk '!/^undocumented_findings:/' "$d/RESEARCH-STATE-beta.md"  > "$d/RS.tmp" && mv "$d/RS.tmp" "$d/RESEARCH-STATE-beta.md"
out="$(bash "$SUT" "$d" 2>&1)"; rc=$?
[ "$rc" = 0 ] \
  && ok "32 multi-focus UF absent in all → archive passes (absent = 0, exit 0)" \
  || no "32 mf uf-absent: exit=$rc (want 0) :: $out"

# 33 — UF gate must FAIL CLOSED when the state-file enumeration yields NOTHING.
# The loop reads from `list_state_files "$corpus"`, whose find swallows its own errors. If the
# enumeration comes back empty (unreadable corpus dir, a find that died, a future refactor that
# renames the state file), the while body never runs, gate_rc stays 0, and the archive closes
# WITHOUT having inspected a single state file — the exact silent-pass shape this gate exists to
# prevent, one layer up. A corpus is only reachable here because line 70 already found a state
# file, so an empty enumeration is an impossible state, and an impossible state must be loud.
# Simulated with a stub library so the assertion does not depend on filesystem permissions.
d="$TMP/uf-empty-enum"; mkgood "$d"
awk '/^undocumented_findings:/{$0="undocumented_findings: 1"} {print}' "$d/RESEARCH-STATE.md" > "$d/RS.tmp" && mv "$d/RS.tmp" "$d/RESEARCH-STATE.md"
tbE="$TMP/tb-empty-enum"; mkdir -p "$tbE/lib"
cp "$SUT" "$tbE/research-sdd-archive.sh"
cp "$HERE/../verify-state.sh"     "$tbE/verify-state.sh"
cp "$HERE/../verify-sources.sh"   "$tbE/verify-sources.sh"
cp "$HERE/../scan-secrets.sh"     "$tbE/scan-secrets.sh"
cp "$HERE/../lib/retro-status.sh" "$tbE/lib/retro-status.sh"
cp "$HERE/../lib/focus-prefix.sh" "$tbE/lib/focus-prefix.sh"
# STUB: enumeration returns nothing, as a permission-denied find would.
printf '%s\n' '# shellcheck disable=SC2148' 'list_state_files() { return 0; }' > "$tbE/lib/state-files.sh"
out="$(bash "$tbE/research-sdd-archive.sh" "$d" 2>&1)"; rc=$?
if [ "$rc" = 3 ] && grep -qiE 'undocumented_findings.*(no state file|could not|enumerat)' <<<"$out"; then
  ok "33 empty state-file enumeration → REFUSED (exit 3), reported distinctly — gate cannot silently no-op"
else
  no "33 empty enum: exit=$rc (want 3) / distinct report=$(grep -ciE 'undocumented_findings.*(no state file|could not|enumerat)' <<<"$out") :: $out"
fi

# 34 — UF gate must FAIL CLOSED when list_state_files emits paths that do NOT exist on disk.
# The counter incremented BEFORE the -f guard means "lines the enumerator returned", not
# "files actually inspected". If every returned path fails -f, _uf_sf_count is non-zero but
# ZERO state files were read — the empty-inspection guard stays silent while the archive
# closes having inspected nothing. Moving the increment AFTER -f makes the counter mean
# "files actually inspected", which is strictly stronger and catches this window too.
d="$TMP/uf-noexist-paths"; mkgood "$d"
tbNE="$TMP/tb-noexist"; mkdir -p "$tbNE/lib"
cp "$SUT" "$tbNE/research-sdd-archive.sh"
cp "$HERE/../verify-state.sh"     "$tbNE/verify-state.sh"
cp "$HERE/../verify-sources.sh"   "$tbNE/verify-sources.sh"
cp "$HERE/../scan-secrets.sh"     "$tbNE/scan-secrets.sh"
cp "$HERE/../lib/retro-status.sh" "$tbNE/lib/retro-status.sh"
cp "$HERE/../lib/focus-prefix.sh" "$tbNE/lib/focus-prefix.sh"
# STUB: enumeration returns two paths that do not exist — simulates paths that vanished
# between the find scan and the inspection loop, or a broken enumerator outputting garbage.
printf '%s\n' '# shellcheck disable=SC2148' \
  "list_state_files() { printf '%s\n' \"$d/DOES-NOT-EXIST-1.md\" \"$d/DOES-NOT-EXIST-2.md\"; }" \
  > "$tbNE/lib/state-files.sh"
out="$(bash "$tbNE/research-sdd-archive.sh" "$d" 2>&1)"; rc=$?
if [ "$rc" = 3 ] && grep -qiE 'undocumented_findings.*(no state file|could not|enumerat)' <<<"$out"; then
  ok "34 all enumerated paths absent → REFUSED (exit 3, enumeration problem reported) — counter counts inspected, not enumerated"
else
  no "34 non-existent paths: exit=$rc (want 3) / distinct report=$(grep -ciE 'undocumented_findings.*(no state file|could not|enumerat)' <<<"$out") :: $out"
fi

# ======================== SPLIT-LAYOUT undocumented_findings gate ====================================
# mkmulti places both state files FLAT in one directory ($dir/RESEARCH-STATE-alpha.md and
# $dir/RESEARCH-STATE-beta.md). For that geometry corpus == target, so list_state_files "$corpus"
# and list_state_files "$target" are identical — tests 29-32 passed while the scope bug was present.
# The FAILING GEOMETRY is a SPLIT layout: each focus in its own sibling subdirectory
# ($dir/alpha/RESEARCH-STATE.md, $dir/beta/RESEARCH-STATE.md). There corpus = $dir/alpha (the
# first-found state directory), so scoping to "$corpus" only enumerates alpha and never sees beta.
# Case 35 is the RED case that exposes the bug on the unfixed SUT.

# mksplit <dir> — split-layout two-focus corpus: alpha and beta focuses in SIBLING SUBDIRECTORIES
# rather than flat in one dir. Both focus directories are individually gate-clean (alpha passes
# verify-state, verify-sources, and scan-secrets when called with the focus dir). UF is 0 in both
# after --sync-state; callers that need UF>0 in a focus set it after calling mksplit.
mksplit() {
  local d="$1"
  mkdir -p "$d/alpha" "$d/beta"
  # --- alpha focus ---
  cat > "$d/alpha/RESEARCH-STATE.md" <<'EOF'
# Alpha — Research State
> Active focus.

## Coverage

- **Covered blocks**: 1 (alpha-block1)
- **Coverage metric**: 1 / 1 closed

## Gap-backlog (prioritized)

| Priority | Gap | Artifact type / source | Status |
|---|---|---|---|

## Iteration history

| # | Date | Gap closed | Block | Delegated? · model tier | New gaps uncovered |
|---|---|---|---|---|---|
| 1 | 2026-07-28 | first gap | alpha-block1 | no · inline | 0 |

## Stop control

- **Open gaps — read-only investigable**: 0
EOF
  printf '# Alpha Block 1\nBody.\n' > "$d/alpha/alpha-block1.md"
  : > "$d/alpha/INDEX.md"
  bash "$HERE/../research-sdd-status.sh" "$d/alpha" --sync-state >/dev/null 2>&1
  # --- beta focus ---
  cat > "$d/beta/RESEARCH-STATE.md" <<'EOF'
# Beta — Research State
> Active focus.

## Coverage

- **Covered blocks**: 1 (beta-block1)
- **Coverage metric**: 1 / 1 closed

## Gap-backlog (prioritized)

| Priority | Gap | Artifact type / source | Status |
|---|---|---|---|

## Iteration history

| # | Date | Gap closed | Block | Delegated? · model tier | New gaps uncovered |
|---|---|---|---|---|---|
| 1 | 2026-07-28 | first gap | beta-block1 | no · inline | 0 |

## Stop control

- **Open gaps — read-only investigable**: 0
EOF
  printf '# Beta Block 1\nBody.\n' > "$d/beta/beta-block1.md"
  : > "$d/beta/INDEX.md"
  bash "$HERE/../research-sdd-status.sh" "$d/beta" --sync-state >/dev/null 2>&1
}

# 35 — SPLIT LAYOUT: UF=1 in a NON-FIRST sibling focus must REFUSE (exit 3). RED on unfixed SUT.
# corpus = $d/alpha (first-found state dir via alphabetical sort + head -1), so
# list_state_files "$corpus" only enumerates alpha and never inspects beta's UF=1 debt → exit 0.
# The fix scopes the uf-gate to "$target" so ALL sibling focus directories are covered.
# Guard: the report must name undocumented_findings (not merely exit 3 for some other gate reason).
d="$TMP/split-uf"; mksplit "$d"
awk '/^undocumented_findings:/{$0="undocumented_findings: 1"} {print}' \
  "$d/beta/RESEARCH-STATE.md" > "$d/RS.tmp" && mv "$d/RS.tmp" "$d/beta/RESEARCH-STATE.md"
out="$(bash "$SUT" "$d" 2>&1)"; rc=$?
[ "$rc" = 3 ] && grep -qi 'undocumented_findings' <<<"$out" \
  && ok "35 split-layout: UF=1 in sibling subdir (beta) → REFUSED (exit 3, undocumented_findings in report)" \
  || no "35 split-layout: exit=$rc (want 3) / mention=$(grep -ci 'undocumented_findings' <<<"$out") :: $out"

# NEGATIVE CONTROL — neuter the gate in a mutant; the STALE fixture must then archive (exit 0) not refuse.
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: neuter the gate in a mutant, expect the stale fixture to archive instead of refusing --"
  mutant="$TMP/archive.MUTANT.sh"
  # force the gate to always pass by making the refusal condition unreachable
  sed 's/gate_rc=1/gate_rc=0/g' "$SUT" > "$mutant"
  cp "$HERE/../verify-state.sh" "$TMP/verify-state.sh"
  cp "$HERE/../verify-sources.sh" "$TMP/verify-sources.sh"
  cp "$HERE/../scan-secrets.sh" "$TMP/scan-secrets.sh"
  mkdir -p "$TMP/lib"
  cp "$HERE/../lib/retro-status.sh" "$TMP/lib/retro-status.sh"   # archive.sh sources this from $(dirname $0)/lib/
  cp "$HERE/../lib/focus-prefix.sh" "$TMP/lib/focus-prefix.sh"   # verify-state.sh sources this from $(dirname $0)/lib/
  cp "$HERE/../lib/state-files.sh"  "$TMP/lib/state-files.sh"    # archive.sh sources this for uf-gate iteration
  d="$TMP/teeth"; mkgood "$d"; sed -i 's#2 / 3 closed#3 / 3 closed#' "$d/RESEARCH-STATE.md"
  bash "$mutant" "$d" >/dev/null 2>&1; mrc=$?
  if [ "$mrc" = 0 ]; then ok "teeth: gate-neutered mutant archives a stale corpus → gate test has teeth"
  else no "teeth: mutant exit=$mrc — gate not exercised (THEATER)"; fi

  echo "-- teeth: revert the ADDED-only filter (drop --diff-filter=A) so a backlink-edit counts; expect a WARN --"
  amutant="$TMP/archive.ADDMUTANT.sh"
  sed 's/show --diff-filter=A --name-only/show --name-only/' "$SUT" > "$amutant"
  if ! grep -q 'show --diff-filter=A --name-only' "$SUT"; then
    no "teeth: ADDED-only filter line not found in SUT (did the fix change shape?)"
  else
    d="$TMP/teeth-backlink"; mkrun_git_backlink "$d"
    out="$(bash "$amutant" "$d" 2>&1)"; arc=$?
    if [ "$arc" = 0 ] && grep -qi 'ONE-BLOCK-PER-COMMIT' <<<"$out"; then
      ok "teeth: name-only mutant WARNs on the add-1+modify-1 iteration → case 23a has teeth"
    else no "teeth: add-mutant rc=$arc / no WARN — case 23a does NOT depend on --diff-filter=A (THEATER)"; fi
  fi

  echo "-- teeth: uf-gate — neuter ONLY the undocumented_findings refuse; uf=1 corpus must then archive --"
  mutantUF="$TMP/archive.UFMUTANT.sh"
  sed 's/gate_rc=1  # uf-gate-refuse/gate_rc=0  # MUTANT-uf-gate/' "$SUT" > "$mutantUF"
  cp "$HERE/../verify-state.sh" "$TMP/verify-state.sh"
  cp "$HERE/../verify-sources.sh" "$TMP/verify-sources.sh"
  cp "$HERE/../scan-secrets.sh" "$TMP/scan-secrets.sh"
  mkdir -p "$TMP/lib"
  cp "$HERE/../lib/retro-status.sh" "$TMP/lib/retro-status.sh"
  cp "$HERE/../lib/focus-prefix.sh" "$TMP/lib/focus-prefix.sh"
  cp "$HERE/../lib/state-files.sh"  "$TMP/lib/state-files.sh"
  d="$TMP/uf-teeth-gate"; mkgood "$d"
  awk '/^undocumented_findings:/{$0="undocumented_findings: 1"} {print}' "$d/RESEARCH-STATE.md" > "$d/RS.tmp" && mv "$d/RS.tmp" "$d/RESEARCH-STATE.md"
  if ! grep -q 'MUTANT-uf-gate' "$mutantUF"; then
    no "teeth(uf): could not build uf mutant (uf-gate-refuse marker not found — did the SUT change?)"
  else
    bash "$mutantUF" "$d" >/dev/null 2>&1; ufmrc=$?
    if [ "$ufmrc" = 0 ]; then
      ok "teeth(uf): uf gate neutered → uf=1 corpus archives (exit 0) — uf refuse is load-bearing"
    else no "teeth(uf): mutant exit=$ufmrc (want 0) — uf gate may not depend on gate_rc=1 # uf-gate-refuse (THEATER)"; fi
  fi

  echo "-- teeth(uf-split): revert uf-gate scope from \$target to \$corpus; split-layout UF=1 must then archive --"
  # The uf-gate line after the fix is: done < <(list_state_files "$target")
  # Reverting to "$corpus" reproduces the bug: corpus = first-focus dir, sibling focuses are skipped.
  # A missed sed is DETECTED rather than passing vacuously: the replacement appends a marker comment,
  # and we grep for it before running the mutant — if the grep fails, the sed did not find the line.
  mutantSplit="$TMP/archive.SPLITMUTANT.sh"
  sed 's/list_state_files "\$target")/list_state_files "\$corpus")  # MUTANT-uf-split/' "$SUT" > "$mutantSplit"
  cp "$HERE/../verify-state.sh" "$TMP/verify-state.sh"
  cp "$HERE/../verify-sources.sh" "$TMP/verify-sources.sh"
  cp "$HERE/../scan-secrets.sh" "$TMP/scan-secrets.sh"
  mkdir -p "$TMP/lib"
  cp "$HERE/../lib/retro-status.sh" "$TMP/lib/retro-status.sh"
  cp "$HERE/../lib/focus-prefix.sh" "$TMP/lib/focus-prefix.sh"
  cp "$HERE/../lib/state-files.sh"  "$TMP/lib/state-files.sh"
  d="$TMP/split-teeth"; mksplit "$d"
  awk '/^undocumented_findings:/{$0="undocumented_findings: 1"} {print}' \
    "$d/beta/RESEARCH-STATE.md" > "$d/RS.tmp" && mv "$d/RS.tmp" "$d/beta/RESEARCH-STATE.md"
  if ! grep -q 'MUTANT-uf-split' "$mutantSplit"; then
    no "teeth(uf-split): could not build split mutant (uf-gate target-scope line not found — did the SUT change?)"
  else
    bash "$mutantSplit" "$d" >/dev/null 2>&1; splitmrc=$?
    if [ "$splitmrc" = 0 ]; then
      ok "teeth(uf-split): scope-reversion mutant → split-layout UF=1 archives (exit 0) — \$target scope is load-bearing"
    else no "teeth(uf-split): mutant exit=$splitmrc (want 0) — case 35 does NOT depend on \$target scope (THEATER)"; fi
  fi

  echo "-- teeth(mf-uf): multi-focus uf gate — UF=1 in one focus must refuse; neutered mutant must archive --"
  # The marker is 'uf-gate-refuse'; the same sed that neuters single-focus also neuters the loop body.
  mutantMFUF="$TMP/archive.MFUF-MUTANT.sh"
  sed 's/gate_rc=1  # uf-gate-refuse/gate_rc=0  # MUTANT-uf-gate-mf/' "$SUT" > "$mutantMFUF"
  cp "$HERE/../verify-state.sh" "$TMP/verify-state.sh"
  cp "$HERE/../verify-sources.sh" "$TMP/verify-sources.sh"
  cp "$HERE/../scan-secrets.sh" "$TMP/scan-secrets.sh"
  mkdir -p "$TMP/lib"
  cp "$HERE/../lib/retro-status.sh" "$TMP/lib/retro-status.sh"
  cp "$HERE/../lib/focus-prefix.sh" "$TMP/lib/focus-prefix.sh"
  cp "$HERE/../lib/state-files.sh"  "$TMP/lib/state-files.sh"
  d="$TMP/mf-uf-teeth"; mkmulti "$d"
  awk '/^undocumented_findings:/{$0="undocumented_findings: 1"} {print}' \
    "$d/RESEARCH-STATE-alpha.md" > "$d/RS.tmp" && mv "$d/RS.tmp" "$d/RESEARCH-STATE-alpha.md"
  if ! grep -q 'MUTANT-uf-gate-mf' "$mutantMFUF"; then
    no "teeth(mf-uf): could not build mf-uf mutant (uf-gate-refuse marker not found — did the SUT change?)"
  else
    bash "$mutantMFUF" "$d" >/dev/null 2>&1; mfufmrc=$?
    if [ "$mfufmrc" = 0 ]; then
      ok "teeth(mf-uf): mf uf gate neutered → UF=1 in alpha-focus archives (exit 0) — mf uf refuse is load-bearing"
    else no "teeth(mf-uf): mutant exit=$mfufmrc (want 0) — mf uf gate may not depend on uf-gate-refuse marker (THEATER)"; fi
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
