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
# skip() counts toward NEITHER pass nor fail — a skip is not a pass. The "  SKIP  " prefix (two
# spaces, SKIP, two spaces) matches run-all.sh's per-test skip convention (see decompile-native.test.sh,
# extract-pdf.test.sh), so the aggregate's total_skipped counter picks it up instead of silently
# folding it into either count.
skip(){ printf '  SKIP  %s\n' "$1"; }

# _dubious_ownership_reproduces <fixture-dir> — probes whether GIT_TEST_ASSUME_DIFFERENT_OWNER=1
# actually makes `git -C <dir> rev-parse --show-toplevel` fail with a "dubious ownership" message on
# THIS host, before any test or mutant relies on it. CI evidence (run 35969674928): on a GitHub-hosted
# runner (git 2.55.0, actions/checkout adding safe.directory for the checkout path only — not a
# wildcard, and not this fixture's path) the env var did not reproduce the failure — exit 0, no error
# at all. The cause was not pinned down further (older/newer git build quirk, some other
# safe.directory interaction, or a runner identity where the ownership check never fires); rather than
# guess, this probes the ACTUAL fixture, live, every run.
_dubious_ownership_reproduces() {
  local d="$1" err rc
  err="$(GIT_TEST_ASSUME_DIFFERENT_OWNER=1 git -C "$d" rev-parse --show-toplevel 2>&1 1>/dev/null)"; rc=$?
  [ "$rc" -ne 0 ] && <<<"$err" grep -qi 'dubious ownership'
}

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
  # Seed a fresh close-retro so the MISSING-RETRO gate (D6) is silent for cases that represent a closed run.
  add_close_retro "$corpus"
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
  # --sync-state seeds the research-state.v1 envelope into the already-committed RESEARCH-STATE.md,
  # so the tree is DELIBERATELY left dirty here — this is the real PROMPT-LOOP close flow (sync-state,
  # then run archive; the corpus commit is a checklist step AFTER archive, not a precondition), and
  # archive.sh's scan-secrets gate (#970 F1) must pass a dirty-but-secret-free tree unaided.
  bash "$HERE/../research-sdd-status.sh" "$corpus" --sync-state >/dev/null 2>&1
}

# add_close_retro <corpus> — seed a fresh close-retro with a far-future mtime into <corpus>/retros/
# so the MISSING-RETRO gate (D6) is silent for test fixtures that represent a closed run (retro present).
# For non-git corpora rsdd_added_epoch falls back to file mtime; the future date ensures the retro's
# mtime epoch exceeds any current-time block mtime. For git fixtures, use a git commit instead.
add_close_retro() {
  local c="$1"; mkdir -p "$c/retros"
  printf '<!-- review-status: pending -->\n# Close retro — test fixture\n' > "$c/retros/2099-01-01-close.md"
  touch -d '2099-01-01' "$c/retros/2099-01-01-close.md"
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
cp "$HERE/../lib/block-files.sh"  "$tb/lib/block-files.sh"   # required helper (block discriminator)
cp "$HERE/../lib/focus-prefix.sh" "$tb/lib/focus-prefix.sh"  # required helper (--focus scope of the §14 gate)
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
#      (Round 2: the old fixture was `chmod 000 INDEX.md`; an unreadable in-scope *.md is now a typed DEGRADED
#      refusal of the secrets gate, so the touch failure is simulated with a `touch` shim instead — INDEX.md stays readable.)
d="$TMP/rotouch"; mkgood "$d"
_real_touch="$(command -v touch)"; mkdir -p "$TMP/touchstub"
printf '#!/bin/bash\ncase "$*" in *INDEX.md*) exit 1;; esac\nexec "%s" "$@"\n' "$_real_touch" > "$TMP/touchstub/touch"; chmod +x "$TMP/touchstub/touch"
out="$(PATH="$TMP/touchstub:$PATH" bash "$SUT" "$d" 2>&1)"; rc=$?
if [ "$rc" = 0 ] && grep -q 'archived' <<<"$out" && grep -q 'could not touch INDEX.md' <<<"$out"; then
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

# mkgood_git_clean <corpus> — a hermetic, GIT-BACKED, gate-passing corpus (mirrors mkgood, but versioned).
# --sync-state runs BEFORE the single commit (unlike mkgood_git, which needs independent git-added dates
# per file for the MISSING-RETRO date math), so `git status --porcelain` is EMPTY once this returns —
# a deliberately-clean baseline for cases that test something OTHER than dirty-tree tolerance itself
# (17a/17b/17c/17d/17f below add their own dirty/untracked change on top of this clean baseline).
mkgood_git_clean() {
  local corpus="$1"; mkdir -p "$corpus"
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
  cat > "$corpus/t-block1.md" <<'EOF'
# Block 1 — the first thing
Body.
EOF
  : > "$corpus/INDEX.md"
  mkdir -p "$corpus/retros"
  printf '<!-- review-status: pending -->\n# Close retro — test fixture\n' > "$corpus/retros/2099-01-01-close.md"
  bash "$HERE/../research-sdd-status.sh" "$corpus" --sync-state >/dev/null 2>&1
  git -C "$corpus" add -A
  git -C "$corpus" commit -q -m "seed corpus"
}

# mkgood_git_presync <corpus> — like mkgood_git_clean, but commits BEFORE --sync-state runs (never
# after), so the corpus is fully committed WITHOUT the research-state.v1 envelope yet. Used by 17e: the
# caller runs --sync-state afterward, which rewrites the already-committed RESEARCH-STATE.md in place
# and leaves the tree genuinely dirty — the real PROMPT-LOOP sequence (sync-state, then archive; commit
# is a checklist step AFTER archive, never a precondition).
mkgood_git_presync() {
  local corpus="$1"; mkdir -p "$corpus"
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
  cat > "$corpus/t-block1.md" <<'EOF'
# Block 1 — the first thing
Body.
EOF
  : > "$corpus/INDEX.md"
  mkdir -p "$corpus/retros"
  printf '<!-- review-status: pending -->\n# Close retro — test fixture\n' > "$corpus/retros/2099-01-01-close.md"
  git -C "$corpus" add -A
  git -C "$corpus" commit -q -m "seed corpus (pre-sync)"
}

# 17a — GATE (scan-secrets, COMMITTED mode, #970 — follow-up to #955/#999): a GIT-backed corpus with
#       no secrets anywhere in its committed history, and a CLEAN working tree, must archive normally
#       (exit 0) via the --committed path (not the old working-tree-only scan).
d="$TMP/committed-clean"; mkgood_git_clean "$d"
out="$(bash "$SUT" "$d" 2>&1)"; rc=$?
if [ "$rc" = 0 ] && grep -qE 'scan-secrets .*: ok' <<<"$out"; then
  ok "17a committed-mode: clean git corpus (no secrets, clean tree) archives (exit 0, scan-secrets ok)"
else no "17a committed-mode clean: exit=$rc (want 0) :: $(grep -iE 'scan-secrets|refuse' <<<"$out" | head -3)"; fi

# 17b — GATE (scan-secrets, COMMITTED mode, #970): a secret committed in an EARLIER commit, then
#       REMOVED from HEAD via a later, clean commit (working tree matches HEAD — no secret on disk,
#       tree clean) is INVISIBLE to a working-tree scan of the corpus dir, but is STILL reachable via
#       `git push` (any clone gets the full history: scan-secrets.sh's own header names this exact
#       gap — "including secrets deleted from HEAD but still reachable in history"). Must REFUSE
#       (exit 3). RED before the fix: the OLD archive.sh scanned $corpus (working tree only, no git
#       history walk) and saw a clean directory with nothing on disk → archived clean (exit 0).
d="$TMP/committed-deleted-secret"; mkgood_git_clean "$d"
printf 'Leaked on deploy: AKIAIOSFODNN7EXAMPLE\n' > "$d/leaked-notes.md"
git -C "$d" add leaked-notes.md
git -C "$d" commit -q -m "add leaked-notes.md (secret)"
git -C "$d" rm -q leaked-notes.md
git -C "$d" commit -q -m "remove leaked-notes.md"
out="$(bash "$SUT" "$d" 2>&1)"; rc=$?
if [ "$rc" = 3 ] && grep -qiE 'scan-secrets .*FAIL' <<<"$out"; then
  ok "17b committed-mode: secret removed from HEAD via a clean commit, still reachable in history → REFUSED (exit 3)"
else no "17b committed-mode deleted-secret: exit=$rc (want 3) :: $(grep -iE 'scan-secrets|refuse' <<<"$out" | head -3)"; fi

# 17c — GATE (working-tree scan, #970 round 3 (a)): a secret that exists ONLY in an UNCOMMITTED file
#       is invisible to --committed (it reads committed git OBJECTS via `git cat-file`, never the
#       working tree) — so without SOME working-tree coverage this corpus would archive clean (exit 0)
#       even though the very next `git add && commit && push` would ship the secret. Caught here by the
#       PLAIN `scan-secrets.sh $corpus` call (a) — it reads the filesystem directly, so it needs no git
#       awareness at all to see an untracked file. Must REFUSE (exit 3), FAIL names the working tree
#       specifically (not a generic 'scan-secrets FAIL' that could equally mean a committed-history
#       leak — F5: don't overclaim).
d="$TMP/committed-uncommitted-secret"; mkgood_git_clean "$d"
printf 'Leaked on deploy: AKIAIOSFODNN7EXAMPLE\n' > "$d/uncommitted-notes.md"
out="$(bash "$SUT" "$d" 2>&1)"; rc=$?
if [ "$rc" = 3 ] && grep -qiE 'scan-secrets .*FAIL.*the working tree' <<<"$out"; then
  ok "17c committed-mode: secret only in an UNCOMMITTED file → REFUSED (exit 3), FAIL names the working tree"
else no "17c committed-mode uncommitted-secret: exit=$rc (want 3, FAIL naming the working tree) :: $(grep -iE 'scan-secrets|refuse' <<<"$out" | head -3)"; fi

# 17d — CONTROL for 17c, REVERSED from round 1 (#970 F1 — the maintainer's design call): a dirty tree
#       with NO secret content at all must now PASS (exit 0). Round 1 refused outright on ANY dirty
#       tree; that was dropped because the real PROMPT-LOOP close flow ALWAYS leaves the tree dirty at
#       this point (--sync-state rewrites RESEARCH-STATE.md; archive's own CONSOLIDATE step writes
#       CATALOG.md) — a refuse-on-dirty gate made every ordinary close refuse. Dirtiness alone must
#       never block; only an actual leak does.
d="$TMP/committed-uncommitted-nosecret"; mkgood_git_clean "$d"
printf 'just a scratch note, nothing sensitive\n' > "$d/scratch.md"
out="$(bash "$SUT" "$d" 2>&1)"; rc=$?
if [ "$rc" = 0 ] && grep -qE 'scan-secrets .*: ok' <<<"$out"; then
  ok "17d committed-mode: dirty tree with NO secret content → archives normally (exit 0, dirtiness alone never refuses)"
else no "17d committed-mode uncommitted-nosecret: exit=$rc (want 0) :: $(grep -iE 'scan-secrets|refuse' <<<"$out" | head -3)"; fi

# 17e — REAL-FLOW test (#970 F1, explicitly requested): the exact PROMPT-LOOP close sequence — a fully
#       committed, secret-free corpus; run --sync-state (rewrites RESEARCH-STATE.md, leaves it dirty,
#       uncommitted); run archive → must PASS. Then run archive AGAIN with CATALOG.md now sitting
#       untracked on disk (archive's own CONSOLIDATE step wrote it, nobody committed it yet) → must
#       STILL pass. This is the scenario round 1's dirty-tree refusal broke for every real close.
d="$TMP/realflow"; mkgood_git_presync "$d"
bash "$HERE/../research-sdd-status.sh" "$d" --sync-state >/dev/null 2>&1
_rf_status="$(git -C "$d" status --porcelain)"
[ -n "$_rf_status" ] \
  && ok "17e precondition: --sync-state left the tree dirty (real-flow fixture is meaningful)" \
  || no "17e precondition: tree unexpectedly clean after --sync-state — fixture does not exercise F1"
out1="$(bash "$SUT" "$d" 2>&1)"; rc1=$?
if [ "$rc1" = 0 ] && grep -qE 'scan-secrets .*: ok' <<<"$out1"; then
  ok "17e real-flow step 1: committed corpus + dirty --sync-state → archive passes (exit 0)"
else no "17e real-flow step 1: exit=$rc1 (want 0) :: $(grep -iE 'scan-secrets|refuse' <<<"$out1" | head -3)"; fi
[ -f "$d/CATALOG.md" ] \
  && ok "17e precondition: CATALOG.md exists and is untracked after step 1 (consolidate ran, nobody committed)" \
  || no "17e precondition: CATALOG.md missing after step 1 — consolidate did not run as expected"
out2="$(bash "$SUT" "$d" 2>&1)"; rc2=$?
if [ "$rc2" = 0 ] && grep -qE 'scan-secrets .*: ok' <<<"$out2"; then
  ok "17e real-flow step 2: archive AGAIN with CATALOG.md untracked → still passes (exit 0)"
else no "17e real-flow step 2: exit=$rc2 (want 0) :: $(grep -iE 'scan-secrets|refuse' <<<"$out2" | head -3)"; fi

# 17f — GATE (F2, untracked-files config — STILL relevant after round 3's mirror removal): an untracked
#       file holding a secret is HIDDEN from `git status --porcelain` entirely under a local
#       `status.showUntrackedFiles=no` config — kept as a regression pin even though the gate no longer
#       reads `git status` at all for this call: (a) is the PLAIN `scan-secrets.sh $corpus` filesystem
#       scan, which was never git-aware and so was never susceptible to this config in the first place.
#       Must REFUSE (exit 3) — this also proves the config can't be used to hide a secret from the gate.
d="$TMP/showuntracked-no"; mkgood_git_clean "$d"
git -C "$d" config status.showUntrackedFiles no
printf 'Leaked on deploy: AKIAIOSFODNN7EXAMPLE\n' > "$d/hidden-by-config.md"
_f2_status_plain="$(git -C "$d" status --porcelain)"
[ -z "$_f2_status_plain" ] \
  && ok "17f precondition: plain 'git status --porcelain' hides the untracked secret under this config (irrelevant to the gate, but confirms the config is doing what it claims)" \
  || no "17f precondition: plain status unexpectedly shows the untracked file — fixture does not exercise F2"
out="$(bash "$SUT" "$d" 2>&1)"; rc=$?
if [ "$rc" = 3 ] && grep -qiE 'scan-secrets .*FAIL.*the working tree' <<<"$out"; then
  ok "17f F2: untracked secret under status.showUntrackedFiles=no → still REFUSED (the plain filesystem scan never reads git status)"
else no "17f F2 showUntrackedFiles=no: exit=$rc (want 3) :: $(grep -iE 'scan-secrets|refuse' <<<"$out" | head -3)"; fi

# 17f-opus1 — REGRESSION PIN (Opus round-2 re-review finding #1): round 2's mirror re-implemented
#       scan-secrets.sh's non-committed-mode corpus-root NARROWING inside a PARTIAL snapshot (just the
#       dirty/untracked paths) — since the mirror often lacked the corpus's own top-level committed
#       block file, scanning it triggered narrowing down to whichever subdirectory HAD a block file
#       (here, focusA/), and an untracked notes.md sitting OUTSIDE that narrowed root passed silently.
#       Removed with the mirror (round 3): (a) is a PLAIN `scan-secrets.sh $corpus` call on the REAL
#       corpus directory (which — via mkgood_git_clean — already has its own top-level t-block1.md, so
#       scan-secrets.sh's narrowing never triggers), matching origin/main byte-for-byte. Must REFUSE.
d="$TMP/opus-f1-repro"; mkgood_git_clean "$d"
mkdir -p "$d/focusA"
printf '# fake nested block\nBody.\n' > "$d/focusA/a-block3.md"
printf 'Leaked on deploy: AKIAIOSFODNN7EXAMPLE\n' > "$d/notes.md"
out="$(bash "$SUT" "$d" 2>&1)"; rc=$?
if [ "$rc" = 3 ] && grep -qiE 'scan-secrets .*FAIL' <<<"$out"; then
  ok "17f-opus1: untracked notes.md secret alongside untracked focusA/a-block3.md → REFUSED (exit 3), matches origin/main"
else no "17f-opus1 regression: exit=$rc (want 3) :: $(grep -iE 'scan-secrets|refuse' <<<"$out" | head -3)"; fi

# 17f-opus2 — REGRESSION PIN (Opus finding #2): round 2's mirror staged ONLY the paths `git status`
#       reported, so a GITIGNORED file was never staged and never scanned — an undocumented regression
#       vs. origin/main, which scans the filesystem directly and has never cared about .gitignore.
#       Removed with the mirror: (a) reads $corpus off disk with plain `grep -r`, which does not
#       consult .gitignore at all. Must REFUSE.
d="$TMP/gitignored-env"; mkgood_git_clean "$d"
printf '*.env\n' > "$d/.gitignore"
git -C "$d" add .gitignore
git -C "$d" commit -q -m "add gitignore for *.env"
printf 'AWS_KEY=AKIAIOSFODNN7EXAMPLE\n' > "$d/secret.env"
_gi_status="$(git -C "$d" status --porcelain)"
[ -z "$_gi_status" ] \
  && ok "17f-opus2 precondition: secret.env is correctly gitignored (git status shows nothing)" \
  || no "17f-opus2 precondition: git status unexpectedly shows secret.env — fixture does not exercise the gitignore case :: $_gi_status"
out="$(bash "$SUT" "$d" 2>&1)"; rc=$?
if [ "$rc" = 3 ] && grep -qiE 'scan-secrets .*FAIL' <<<"$out"; then
  ok "17f-opus2: gitignored .env with a secret → still REFUSED (the plain filesystem scan does not consult .gitignore)"
else no "17f-opus2 regression: exit=$rc (want 3) :: $(grep -iE 'scan-secrets|refuse' <<<"$out" | head -3)"; fi

# 17f-opus4 — PARITY PIN (Opus finding #4, mirror removed): round 2's mirror followed symlinks via
#       `cp -p` — an untracked symlink pointing OUTSIDE the repo (e.g. into ~/.ssh) would have copied
#       real key material into a throwaway /tmp mirror. With the mirror gone, this pins that behaviour
#       now matches origin/main EXACTLY: `grep -r` (used by scan-secrets.sh, not `-R`) does not follow
#       symlinks, so a symlink to an out-of-repo secret is NOT scanned — same as it always was. This is
#       parity with origin/main, not a new guarantee; a link INTO a scanned tree still isn't dereferenced.
d="$TMP/symlink-outside"; mkgood_git_clean "$d"
mkdir -p "$TMP/outside-secret"
printf 'Leaked on deploy: AKIAIOSFODNN7EXAMPLE\n' > "$TMP/outside-secret/real.md"
ln -s "$TMP/outside-secret/real.md" "$d/link-to-outside.md"
out="$(bash "$SUT" "$d" 2>&1)"; rc=$?
if [ "$rc" = 0 ] && grep -qE 'scan-secrets .*: ok' <<<"$out"; then
  ok "17f-opus4: untracked symlink to an out-of-repo secret → NOT scanned (grep -r never follows symlinks), matches origin/main"
else no "17f-opus4 symlink: exit=$rc (want 0, matching origin/main's grep -r non-dereferencing behaviour) :: $(grep -iE 'scan-secrets|refuse' <<<"$out" | head -3)"; fi

# 17g — GATE (F3a): git present on PATH but STUBBED (always exits 127, no output) must NOT be silently
#       treated as "not a git repository" — the stub's `rev-parse --show-toplevel` failure carries no
#       "not a git repository" text, so it falls into the ambiguous-failure refuse, not the ungit
#       fallback. Loud ERROR, refuse (exit 3).
d="$TMP/gitstub"; mkgood_git_clean "$d"
mkdir -p "$TMP/stubbin"
cat > "$TMP/stubbin/git" <<'STUBEOF'
#!/usr/bin/env bash
exit 127
STUBEOF
chmod +x "$TMP/stubbin/git"
out="$(PATH="$TMP/stubbin:$PATH" bash "$SUT" "$d" 2>&1)"; rc=$?
if [ "$rc" = 3 ] && grep -qiE 'scan-secrets .*ERROR.*could not determine' <<<"$out" && ! grep -qi 'not a git repository' <<<"$out"; then
  ok "17g F3a: git present but stubbed (exit 127) → loud ERROR, refuse (exit 3) — never silently treated as non-git"
else no "17g F3a gitstub: exit=$rc :: $(grep -iE 'scan-secrets|error' <<<"$out" | head -3)"; fi

# 17h — GATE (F3b): "dubious ownership" — a REAL repo git refuses to operate on (CVE-2022-24765 guard).
#       GIT_TEST_ASSUME_DIFFERENT_OWNER=1 is git's own test-suite hook for reproducing this without
#       actually needing a second uid. Must NOT be silently treated as non-git. Loud ERROR, refuse.
#       PROBED first (not assumed): on a GitHub-hosted CI runner this env var did NOT reproduce the
#       failure (confirmed via run 35969674928 — git 2.55.0, same version as here, yet exit 0/no error).
#       A skip here is not a pass — case 17g (git-stub) and its teeth exercise the SAME sentinel
#       (scan-secrets-gate-git-probe-error) unconditionally, so F3 coverage does not depend on this host
#       supporting the env var.
d="$TMP/dubious"; mkgood_git_clean "$d"
if ! _dubious_ownership_reproduces "$d"; then
  skip "17h F3b: GIT_TEST_ASSUME_DIFFERENT_OWNER=1 did not reproduce 'dubious ownership' on this host ($(git --version 2>/dev/null)) — cannot exercise this path here; see 17g for unconditional F3 coverage"
else
  out="$(GIT_TEST_ASSUME_DIFFERENT_OWNER=1 bash "$SUT" "$d" 2>&1)"; rc=$?
  if [ "$rc" = 3 ] && grep -qiE 'scan-secrets .*ERROR.*could not determine' <<<"$out" && ! grep -qi 'not a git repository' <<<"$out"; then
    ok "17h F3b: dubious ownership (GIT_TEST_ASSUME_DIFFERENT_OWNER=1) → loud ERROR, refuse (exit 3) — never silently treated as non-git"
  else no "17h F3b dubious: exit=$rc :: $(grep -iE 'scan-secrets|error' <<<"$out" | head -3)"; fi
fi

# 17i — GATE (F3c): a malformed GLOBAL git config makes every git invocation fail before it can even
#       determine repo-ness. GIT_CONFIG_GLOBAL (git ≥2.32) redirects the "global" config file location
#       without touching the real $HOME/.gitconfig. Must NOT be silently treated as non-git.
d="$TMP/badconfig"; mkgood_git_clean "$d"
printf '[core\nthis is not valid config syntax at all !!!\n' > "$TMP/bad.gitconfig"
out="$(GIT_CONFIG_GLOBAL="$TMP/bad.gitconfig" bash "$SUT" "$d" 2>&1)"; rc=$?
if [ "$rc" = 3 ] && grep -qiE 'scan-secrets .*ERROR.*could not determine' <<<"$out" && ! grep -qi 'not a git repository' <<<"$out"; then
  ok "17i F3c: malformed global git config → loud ERROR, refuse (exit 3) — never silently treated as non-git"
else no "17i F3c badconfig: exit=$rc :: $(grep -iE 'scan-secrets|error' <<<"$out" | head -3)"; fi

# mk_nested_target <outer-dir> <nested-target-dir> — builds a git repo at <outer-dir> (committed
# baseline) with a gate-passing corpus at <nested-target-dir> UNDERNEATH it, but never git-inits the
# nested dir itself and never commits the corpus content — so `git rev-parse --show-toplevel` run from
# inside it resolves to <outer-dir>, exercising the F4/R3-R4 nested-target branch. The corpus content
# stays untracked relative to the outer repo, matching the realistic "dropped a corpus dir inside a
# bigger repo, nobody git-added it" shape.
mk_nested_target() {
  local outer="$1" nested="$2"
  mkdir -p "$outer"
  git -C "$outer" init -q -b main
  git -C "$outer" config user.email t@example.com
  git -C "$outer" config user.name tester
  printf '# outer repo\n' > "$outer/README.md"
  git -C "$outer" add -A
  git -C "$outer" commit -q -m "outer repo baseline"
  mkdir -p "$nested"
  cat > "$nested/RESEARCH-STATE.md" <<'EOF'
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
  cat > "$nested/t-block1.md" <<'EOF'
# Block 1 — the first thing
Body.
EOF
  : > "$nested/INDEX.md"
  mkdir -p "$nested/retros"
  printf '<!-- review-status: pending -->\n# Close retro — test fixture\n' > "$nested/retros/2099-01-01-close.md"
  bash "$HERE/../research-sdd-status.sh" "$nested" --sync-state >/dev/null 2>&1
}

# 17j — GATE (F4/R3-R4): a target with NO git repo of its own, nested inside a LARGER enclosing repo,
#       and no secrets anywhere → archives normally (exit 0), but with a loud WARN naming the enclosing
#       root (history was NOT scanned) — never the misleading "check git/awk/tr" generic-error message
#       a blind --committed call on a subdirectory would otherwise produce (MAJOR3 in scan-secrets.sh).
d_outer="$TMP/nested-outer"; d_nested="$d_outer/corpus-nested"
mk_nested_target "$d_outer" "$d_nested"
out="$(bash "$SUT" "$d_nested" 2>&1)"; rc=$?
if [ "$rc" = 0 ] && grep -qi 'WARN: history not scanned' <<<"$out" && grep -qF "$d_outer" <<<"$out" \
   && ! grep -qi 'check git/awk/tr' <<<"$out"; then
  ok "17j F4: nested target (no secret) → loud WARN naming the enclosing repo, archives (exit 0), never the misleading generic error"
else no "17j F4 nested: exit=$rc :: $(grep -iE 'WARN|scan-secrets|git/awk/tr' <<<"$out" | head -3)"; fi

# 17k — F4 NEGATIVE CONTROL: the SAME nested shape, but with a secret sitting in the corpus (on disk,
#       untracked relative to the outer repo) — the working-tree-only fallback (plain scan-secrets.sh
#       $corpus + the dirty/untracked delta scan) must still catch it. Must REFUSE (exit 3).
d_outer2="$TMP/nested-outer-secret"; d_nested2="$d_outer2/corpus-nested"
mk_nested_target "$d_outer2" "$d_nested2"
printf '\nLeaked on deploy: AKIAIOSFODNN7EXAMPLE\n' >> "$d_nested2/t-block1.md"
out="$(bash "$SUT" "$d_nested2" 2>&1)"; rc=$?
if [ "$rc" = 3 ] && grep -qi 'WARN: history not scanned' <<<"$out" && grep -qiE 'scan-secrets .*FAIL' <<<"$out" \
   && ! grep -qi 'check git/awk/tr' <<<"$out"; then
  ok "17k F4 negative: nested target WITH a secret → still REFUSED (exit 3), WARN still printed, never the misleading generic error"
else no "17k F4 nested-secret: exit=$rc :: $(grep -iE 'WARN|scan-secrets|git/awk/tr' <<<"$out" | head -3)"; fi

# --- T15a (kit issues #1015 + #1014): the secrets gate scans EXACTLY what the archive packages ------------------
# 17m — #1015: scan-secrets.sh's default mode narrows to the shallowest block directory, so a secret-bearing
#       notes.md OUTSIDE it was skipped although the archive packages it. The corpus root here holds
#       RESEARCH-STATE.md but its only block lives in blocks/ (the narrowing trigger). Must REFUSE; the same
#       fixture without the secret must archive (no false refusal). RED before the fix: archived (exit 0).
d="$TMP/narrow-notes"; mkgood "$d"; mkdir -p "$d/blocks"; mv "$d/t-block1.md" "$d/blocks/t-block1.md"
bash "$HERE/../research-sdd-status.sh" "$d" --sync-state >/dev/null 2>&1
bash "$SUT" "$d" --dry-run >/dev/null 2>&1; rc_c=$?
printf 'Leaked on deploy: AKIAIOSFODNN7EXAMPLE\n' > "$d/notes.md"
bash "$HERE/../scan-secrets.sh" "$d" >/dev/null 2>&1; _narrow_rc=$?
[ "$_narrow_rc" = 0 ] && ok "17m precondition: scan-secrets default mode narrows to blocks/ and misses notes.md (exit 0) — the fixture exercises #1015" \
  || no "17m precondition: default-mode scan exit=$_narrow_rc (want 0) — fixture does not exercise the narrowing"
out="$(bash "$SUT" "$d" 2>&1)"; rc=$?
if [ "$rc_c" = 0 ] && [ "$rc" = 3 ] && grep -qiE 'scan-secrets .*FAIL' <<<"$out"; then
  ok "17m #1015: secret in notes.md outside the shallowest block dir → REFUSED (exit 3); same corpus without it passes (exit 0)"
else no "17m #1015: with-secret exit=$rc (want 3) / without-secret exit=$rc_c (want 0) :: $(grep -iE 'scan-secrets' <<<"$out" | head -2)"; fi
unset rc_c _narrow_rc

# 17n — #1015 (no FALSE refusal): scan-secrets' own scope still applies to the packaging list — a secret in a
#       file the scanner never reads (a .txt) and one inside a vendored node_modules/ tree must not refuse.
d="$TMP/narrow-scope"; mkgood "$d"; mkdir -p "$d/node_modules/pkg"
printf 'AKIAIOSFODNN7EXAMPLE\n' > "$d/node_modules/pkg/readme.md"; printf 'AKIAIOSFODNN7EXAMPLE\n' > "$d/scratch.txt"
out="$(bash "$SUT" "$d" 2>&1)"; rc=$?
if [ "$rc" = 0 ] && grep -qE 'scan-secrets .*: ok' <<<"$out"; then
  ok "17n #1015: secret only in an out-of-scope .txt and a vendored node_modules/ file → no false refusal (exit 0)"
else no "17n scope: exit=$rc (want 0) :: $(grep -iE 'scan-secrets' <<<"$out" | head -2)"; fi

# 17o — #1014 item 1: a repo root reached THROUGH A SYMLINK must not read as "nested" (the archive's logical
#       `pwd` differs from git's physical --show-toplevel). Repo root with a history-only secret, archived via a
#       symlinked parent dir: the direct path refuses (17b) and so must the link path (no false "history not
#       scanned" WARN + exit 0). A clean repo reached through a link must not WARN either.
mkdir -p "$TMP/symparent/hs"; d="$TMP/symparent/hs"; mkgood_git_clean "$d"
printf 'Leaked on deploy: AKIAIOSFODNN7EXAMPLE\n' > "$d/leaked-notes.md"
git -C "$d" add leaked-notes.md; git -C "$d" commit -q -m "add leaked-notes.md (secret)"
git -C "$d" rm -q leaked-notes.md; git -C "$d" commit -q -m "remove leaked-notes.md"
ln -s "$TMP/symparent" "$TMP/symparent-link"
out="$(bash "$SUT" "$TMP/symparent-link/hs" 2>&1)"; rc=$?
if [ "$rc" = 3 ] && grep -qiE 'scan-secrets .*FAIL.*committed history' <<<"$out" && ! grep -qi 'history not scanned' <<<"$out"; then
  ok "17o #1014.1: symlinked repo root with a history-only secret → REFUSED (exit 3), no false nested WARN"
else no "17o symlinked root: exit=$rc (want 3, FAIL naming committed history, no nested WARN) :: $(grep -iE 'WARN|scan-secrets' <<<"$out" | head -3)"; fi
mkdir -p "$TMP/symclean/hs"; mkgood_git_clean "$TMP/symclean/hs"; ln -s "$TMP/symclean" "$TMP/symclean-link"
out="$(bash "$SUT" "$TMP/symclean-link/hs" 2>&1)"; rc=$?
if [ "$rc" = 0 ] && ! grep -qi 'history not scanned' <<<"$out" && grep -qE 'scan-secrets .*: ok$' <<<"$out"; then
  ok "17o #1014.1: clean repo through a symlinked root → plain 'ok' (history scanned, no nested WARN)"
else no "17o clean symlinked root: exit=$rc :: $(grep -iE 'WARN|scan-secrets' <<<"$out" | head -3)"; fi

# 17p — #1014 item 2: `git init` with NO commit (research-sdd-init.sh's shape; the corpus commit comes after
#       archive) must archive with a typed WARN and a working-tree scan — not refuse on "no commits". A secret in
#       the working tree of that unborn repo must still REFUSE.
d="$TMP/unborn"; mkgood "$d"; git -C "$d" init -q -b main
out="$(bash "$SUT" "$d" 2>&1)"; rc=$?
if [ "$rc" = 0 ] && grep -qF 'WARN: history not scanned — repository has no commits yet' <<<"$out" && grep -qE 'scan-secrets .*: ok .*no commits yet' <<<"$out"; then
  ok "17p #1014.2: repo with no commits → typed WARN + working-tree scan, archives (exit 0)"
else no "17p unborn repo: exit=$rc (want 0 with the no-commits WARN) :: $(grep -iE 'WARN|scan-secrets' <<<"$out" | head -3)"; fi
d="$TMP/unborn-secret"; mkgood "$d"; git -C "$d" init -q -b main; printf 'Leaked: AKIAIOSFODNN7EXAMPLE\n' > "$d/notes.md"
out="$(bash "$SUT" "$d" 2>&1)"; rc=$?
if [ "$rc" = 3 ] && grep -qiE 'scan-secrets .*FAIL.*the working tree' <<<"$out" && grep -qF 'no commits yet' <<<"$out"; then
  ok "17p #1014.2: unborn repo WITH a working-tree secret → still REFUSED (exit 3)"
else no "17p unborn secret: exit=$rc (want 3) :: $(grep -iE 'WARN|scan-secrets' <<<"$out" | head -3)"; fi

# 17q — fail-closed packaging list (#1015). A `find` shim answers ONLY the packaging-list invocation (the one
#       carrying `-prune -o -type f -print0`) and delegates everything else to the real find: (1) it fails →
#       the list cannot be computed → typed ERROR + REFUSE; (2) it prints nothing → EMPTY list → typed ERROR +
#       REFUSE (a scan that looked at nothing is not a pass); (3) it lists everything but reports "Permission
#       denied" for an unreadable subtree → tolerated, disclosed on the verdict line + stderr WARN, exit 0.
_real_find="$(command -v find)"; mkdir -p "$TMP/findstub-fail" "$TMP/findstub-empty" "$TMP/findstub-perm" "$TMP/findstub-other" "$TMP/findstub-silent"
for _m in fail empty perm other silent; do
  {
    printf '#!/bin/bash\n'
    printf 'case " $* " in *" -prune -o -type f -print0 "*)\n'
    case "$_m" in
      fail)  printf '  echo "find: simulated failure" >&2; exit 1;;\n';;
      empty) printf '  exit 0;;\n';;
      perm)  printf '  "%s" "$@"; echo "find: ./locked: Permission denied" >&2; exit 1;;\n' "$_real_find";;
      other) printf '  "%s" "$@"; echo "find: ./x: Input/output error" >&2; exit 1;;\n' "$_real_find";;
      silent) printf '  "%s" "$@"; exit 1;;\n' "$_real_find";;
    esac
    printf 'esac\nexec "%s" "$@"\n' "$_real_find"
  } > "$TMP/findstub-$_m/find"; chmod +x "$TMP/findstub-$_m/find"
done
d="$TMP/listfail"; mkgood "$d"
out="$(PATH="$TMP/findstub-fail:$PATH" bash "$SUT" "$d" 2>&1)"; rc=$?
if [ "$rc" = 3 ] && grep -qE 'scan-secrets +: ERROR — the packaging list could not be computed' <<<"$out"; then
  ok "17q packaging list cannot be computed → typed ERROR, REFUSED (exit 3) — fail closed"
else no "17q list failure: exit=$rc (want 3 + typed ERROR) :: $(grep -iE 'scan-secrets' <<<"$out" | head -2)"; fi
out="$(PATH="$TMP/findstub-empty:$PATH" bash "$SUT" "$d" 2>&1)"; rc=$?
if [ "$rc" = 3 ] && grep -qE 'scan-secrets +: ERROR — the packaging list is EMPTY' <<<"$out"; then
  ok "17q packaging list EMPTY → typed ERROR, REFUSED (exit 3) — a scan that looked at nothing is not a pass"
else no "17q empty list: exit=$rc (want 3 + typed ERROR) :: $(grep -iE 'scan-secrets' <<<"$out" | head -2)"; fi
out="$(PATH="$TMP/findstub-perm:$PATH" bash "$SUT" "$d" 2>&1)"; rc=$?
if [ "$rc" = 0 ] && grep -qE 'scan-secrets +: ok, 1 unreadable path\(s\) not scanned' <<<"$out" && grep -qF 'WARN: scan-secrets packaging list skipped 1 unreadable path(s)' <<<"$out"; then
  ok "17q unreadable subtree (Permission denied) → tolerated: disclosed on the verdict line + WARN, exit 0"
else no "17q partial list: exit=$rc :: $(grep -iE 'WARN|scan-secrets' <<<"$out" | head -3)"; fi
out="$(PATH="$TMP/findstub-other:$PATH" bash "$SUT" "$d" 2>&1)"; rc=$?
if [ "$rc" = 3 ] && grep -qE 'scan-secrets +: ERROR — the packaging list could not be computed' <<<"$out"; then
  ok "17q a find error that is NOT 'Permission denied' (even with a partial list) → list not computed, REFUSED (exit 3)"
else no "17q non-permission find error: exit=$rc (want 3 + typed ERROR) :: $(grep -iE 'scan-secrets' <<<"$out" | head -2)"; fi
d="$TMP/listfail-git"; mkgood_git_clean "$d"
out="$(PATH="$TMP/findstub-fail:$PATH" bash "$SUT" "$d" 2>&1)"; rc=$?
if [ "$rc" = 3 ] && grep -qE 'scan-secrets +: ERROR — the packaging list could not be computed' <<<"$out"; then
  ok "17q list failure on a repo-root target → typed ERROR, REFUSED (exit 3), not 'clean' on the history half alone"
else no "17q repo-root list failure: exit=$rc :: $(grep -iE 'scan-secrets' <<<"$out" | head -2)"; fi

# 17r — #1014 item 3 (output pins): the refusal hint block names the packaging-list command, and the nested
#       WARN names the enclosing repo (mutation controls for both live in --prove-teeth).
d="$TMP/hintfix"; mkgood_git_clean "$d"; printf 'Leaked: AKIAIOSFODNN7EXAMPLE\n' > "$d/notes.md"
out="$(bash "$SUT" "$d" 2>&1)"; rc=$?
if [ "$rc" = 3 ] && grep -qF -- '-print0 | ' <<<"$out" && grep -qF -- 'scan-secrets.sh --files-from -' <<<"$out" && grep -qF -- 'scan-secrets.sh --committed' <<<"$out"; then
  ok "17r refusal hint (repo root): names the packaging-list scan (--files-from) AND the --committed history scan"
else no "17r hint: exit=$rc :: $(grep -iE 'scan-secrets|print0' <<<"$out" | head -3)"; fi

# 17s — (round 2, R2) an unreadable DIRECTORY stays tolerated with the typed disclosure (git add cannot read it
#       either) — exercised with a REAL chmod-000 directory, no shim. Skipped under root.
if [ "$(id -u)" = 0 ]; then skip "17s/17t unreadable dir/file: running as root (chmod 000 does not block root)"
else
  d="$TMP/unreadable-dir"; mkgood "$d"; mkdir -p "$d/locked"; printf 'x\n' > "$d/locked/inner.md"; chmod 000 "$d/locked"
  out="$(bash "$SUT" "$d" 2>&1)"; rc=$?
  chmod 755 "$d/locked"
  if [ "$rc" = 0 ] && grep -qE 'scan-secrets +: ok, 1 unreadable path\(s\) not scanned' <<<"$out"; then
    ok "17s R2: real unreadable DIRECTORY → tolerated, disclosed on the verdict line (exit 0)"
  else no "17s unreadable dir: exit=$rc :: $(grep -iE 'WARN|scan-secrets' <<<"$out" | head -3)"; fi
  # 17t — an unreadable in-scope FILE is DEGRADED (exit 3), never `ok`: its content could hold the secret.
  d="$TMP/unreadable-file"; mkgood "$d"; printf 'Leaked: AKIAIOSFODNN7EXAMPLE\n' > "$d/notes.md"; chmod 000 "$d/notes.md"
  out="$(bash "$SUT" "$d" 2>&1)"; rc=$?
  chmod 644 "$d/notes.md"
  if [ "$rc" = 3 ] && grep -qE 'scan-secrets +: ERROR — scan-secrets.sh did not run cleanly \(exit 3\).*DEGRADED' <<<"$out" && ! grep -qE 'scan-secrets +: ok' <<<"$out"; then
    ok "17t R2: unreadable in-scope FILE → REFUSED (exit 3) as a typed DEGRADED ERROR, never ok"
  else no "17t unreadable file: exit=$rc (want 3) :: $(grep -iE 'WARN|scan-secrets' <<<"$out" | head -3)"; fi
fi

# 17u — (round 2) a find failure with an EMPTY stderr is NOT a tolerated permission error: the list's completeness
#       is unproven → not computable → REFUSED. (Tolerance needs a non-empty stderr that is ALL "Permission denied".)
d="$TMP/listsilent"; mkgood "$d"
out="$(PATH="$TMP/findstub-silent:$PATH" bash "$SUT" "$d" 2>&1)"; rc=$?
if [ "$rc" = 3 ] && grep -qE 'scan-secrets +: ERROR — the packaging list could not be computed' <<<"$out"; then
  ok "17u find exits non-zero with empty stderr → list not computed, REFUSED (exit 3)"
else no "17u silent find failure: exit=$rc (want 3 + typed ERROR) :: $(grep -iE 'scan-secrets' <<<"$out" | head -2)"; fi

# 17v — (round 2, R1) the refusal tells the operator how to resolve a secret-store refusal: move it OUTSIDE the
#       target directory (no override flag, no git-ignore filter). Hint paths are shell-quoted (%q): a target
#       whose path holds a space must print as a pasteable command.
d="$TMP/hint space"; mkgood_git_clean "$d"; printf 'Leaked: AKIAIOSFODNN7EXAMPLE\n' > "$d/secret.env"; printf 'secret.env\n' > "$d/.gitignore"
out="$(bash "$SUT" "$d" 2>&1)"; rc=$?
if [ "$rc" = 3 ] && grep -qF 'OUTSIDE the target directory' <<<"$out" && grep -qF 'hint\ space' <<<"$out" && ! grep -qF -- '--files-from - '"$TMP/hint space" <<<"$out"; then
  ok "17v R1: refusal on a gitignored secret store names the remedy (move it OUTSIDE the target); hint paths are %q-quoted"
else no "17v remedy/quoting: exit=$rc :: $(grep -iE 'OUTSIDE|files-from' <<<"$out" | head -3)"; fi
if grep -qF 'AKIAIOSFODNN7' <<<"$out"; then no "17v the refusal output echoes the secret VALUE"; else ok "17v the refusal output never carries the secret value"; fi


# 17w — (round 3, B) the remedy depends on WHERE the leak is: a working-tree leak → move the secret store OUTSIDE the
#       target; a history-only leak → the history must be REWRITTEN (editing the tree cannot help). 17v pins the first.
d="$TMP/committed-deleted-secret"
out="$(bash "$SUT" "$d" 2>&1)"; rc=$?
if [ "$rc" = 3 ] && grep -qF 'history must be rewritten' <<<"$out" && ! grep -qF 'OUTSIDE the target directory' <<<"$out"; then
  ok "17w B: history-only leak → rewrite-history remedy, NOT the move-outside-the-target line"
else no "17w history remedy: exit=$rc :: $(grep -iE 'rewrit|OUTSIDE' <<<"$out" | head -3)"; fi
d="$TMP/hint space"; out="$(bash "$SUT" "$d" 2>&1)"
if grep -qF 'OUTSIDE the target directory' <<<"$out" && ! grep -qF 'history must be rewritten' <<<"$out"; then
  ok "17w B: working-tree-only leak → move-outside line, NOT the history-rewrite line"
else no "17w working-tree remedy :: $(grep -iE 'rewrit|OUTSIDE' <<<"$out" | head -3)"; fi
d="$TMP/leak-both"; mkgood_git_clean "$d"; printf 'Leaked: AKIAIOSFODNN7EXAMPLE\n' > "$d/old.md"; git -C "$d" add old.md; git -C "$d" commit -q -m "add old.md (secret)"
printf 'Leaked: AKIAIOSFODNN7EXAMPLE\n' > "$d/notes.md"
out="$(bash "$SUT" "$d" 2>&1)"; rc=$?
if [ "$rc" = 3 ] && grep -qF 'history must be rewritten' <<<"$out" && grep -qF 'OUTSIDE the target directory' <<<"$out"; then
  ok "17w B: leak in BOTH the working tree and history → both remedies printed"
else no "17w both remedies: exit=$rc :: $(grep -iE 'rewrit|OUTSIDE' <<<"$out" | head -3)"; fi

# 17x — (round 3, C) an unresolvable physical target (cd -P fails; simulated through BASH_ENV) is a typed
#       `target unresolvable` hint, never a `find ''` command; the verdict line names the real message.
printf 'cd(){ if [ "${1:-}" = "-P" ]; then return 1; fi; builtin cd "$@"; }\n' > "$TMP/cdfail.env"
d="$TMP/unresolvable"; mkgood "$d"
out="$(BASH_ENV="$TMP/cdfail.env" bash "$SUT" "$d" 2>&1)"; rc=$?
if [ "$rc" = 3 ] && grep -qF 'the target directory could not be resolved physically' <<<"$out" && grep -qF 'target unresolvable' <<<"$out" && ! grep -qF "find '' " <<<"$out"; then
  ok "17x C: unresolvable physical target → typed ERROR + 'target unresolvable' hint, no empty find command"
else no "17x unresolvable target: exit=$rc :: $(grep -iE 'unresolv|resolved|find ' <<<"$out" | head -3)"; fi

# 17l (REMOVED, round 3): tested a corrupted `.git/index` making a dedicated `git status -z`
# enumeration fail. That enumeration no longer exists — round 3 removed the mirror it fed, and neither
# (a) `scan-secrets.sh $corpus` (a plain filesystem walk, no git) nor (b) `scan-secrets.sh --committed`
# (object-database reads: rev-list/diff-tree/cat-file, never the index) touch `git status` at all.
# Confirmed dead code, not merely unlikely: with the index corrupted this fixture archives cleanly
# (verified against this suite's own SUT, not asserted) because nothing in either scan needs the index.

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

# 20 — MISSING-RETRO gate (D6 promotion, §18): a corpus with blocks advanced past the newest §18 retro
#      must be REFUSED (exit 3, hard gate). mkgood now seeds a close-retro; we remove it to expose the gate.
d="$TMP/missingretro"; mkgood "$d"; rm -rf "$d/retros"
out="$(bash "$SUT" "$d" 2>&1)"; rc=$?
if [ "$rc" = 3 ] && grep -qiE 'MISSING-RETRO.*REFUSE' <<<"$out"; then
  ok "blocks + no retro → MISSING-RETRO gate REFUSED (exit 3)"
else no "no MISSING-RETRO gate with blocks+no retro :: rc=$rc :: $(head -2 <<<"$out")"; fi

# 20a — an OLD retro (mtime older than the newest block) → corpus advanced past it → REFUSED (exit 3).
#       TMP is not a git repo, so the advancement signal is the block mtime (git commit epoch is 0).
#       mkgood seeds a close-retro (2099); remove it and add only an old one (2020) to expose the gate.
d="$TMP/oldretro"; mkgood "$d"; rm -rf "$d/retros"; mkdir -p "$d/retros"
: > "$d/retros/2020-01-01-focus.md"; touch -d '2020-01-01' "$d/retros/2020-01-01-focus.md"
out="$(bash "$SUT" "$d" 2>&1)"; rc=$?
if [ "$rc" = 3 ] && grep -qi 'MISSING-RETRO' <<<"$out"; then
  ok "blocks newer than an OLD retro → MISSING-RETRO gate REFUSED (exit 3)"
else no "old-retro corpus did not REFUSE :: rc=$rc :: $(grep -i retro <<<"$out" | head -2)"; fi

# 20b — NEGATIVE CONTROL: a retro NEWER than every block (run just closed with its retro) must NOT REFUSE —
#       the gate fires only on genuine advancement past the newest retro. The mkgood close-retro (2099)
#       is already newer than any current block mtime, so this test does not remove it.
d="$TMP/freshretro"; mkgood "$d"
out="$(bash "$SUT" "$d" 2>&1)"; rc=$?
if [ "$rc" = 0 ] && ! grep -qi 'MISSING-RETRO' <<<"$out"; then
  ok "retro newer than blocks → no MISSING-RETRO REFUSE (negative control)"
else no "fresh-retro corpus REFUSED spuriously :: rc=$rc :: $(grep -i retro <<<"$out" | head -2)"; fi

# 20c — EXCLUDED-ONLY RETROS (B2): a corpus with blocks AND a §18-excluded retro (carrying
#       '<!-- kit-retro: exclude -->') is still effectively retro-free — the excluded retro must
#       NOT suppress the MISSING-RETRO gate. The corpus must be REFUSED (exit 3).
#       mkgood seeds a close-retro; remove it, then add only the excluded retro so the gate fires.
d="$TMP/excluded-retro"; mkgood "$d"; rm -rf "$d/retros"; mkdir -p "$d/retros"
printf '<!-- kit-retro: exclude -->\n# client retro — not §18\n' > "$d/retros/client.md"
touch "$d/retros/client.md"   # FRESH mtime — would suppress gate if counted as a qualifying retro
out="$(bash "$SUT" "$d" 2>&1)"; rc=$?
if [ "$rc" = 3 ] && grep -qi 'MISSING-RETRO' <<<"$out"; then
  ok "20c excluded-only retro → MISSING-RETRO gate REFUSED (exit 3) — excluded retro does not suppress gate"
else no "20c excluded-retro: rc=$rc :: $(grep -i retro <<<"$out" | head -2)"; fi

# 21 — GIT-ADDED-DATE path, exercised for real (Feature #25a): block git-added AFTER retro, but mtimes say
#      the OPPOSITE (retro mtime later than block mtime). The gate must read the git-added date → REFUSED (exit 3).
d="$TMP/git-warn"
mkgood_git "$d" "2026-01-10T00:00:00" "2026-03-01T00:00:00" "2030-01-01" "2020-01-01"
out="$(bash "$SUT" "$d" 2>&1)"; rc=$?
if [ "$rc" = 3 ] && grep -qi 'MISSING-RETRO' <<<"$out"; then
  ok "21 git-added-date: block added after retro (mtime says opposite) → REFUSED exit 3 (git date wins)"
else
  no "21 git-added-date: block added after retro (mtime says opposite) → REFUSED exit 3 (git date wins)" "rc=$rc :: $(grep -i retro <<<"$out" | head -2)"
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
#       added after retro by git date), invoked with a RELATIVE target from cwd=$TMP. The gate must still
#       REFUSE (exit 3) under a relative invocation — git date resolution must work correctly when the target
#       is passed as a relative path.
d="$TMP/git-warn-rel"
mkgood_git "$d" "2026-01-10T00:00:00" "2026-03-01T00:00:00" "2030-01-01" "2020-01-01"
out="$(cd "$TMP" && bash "$SUT" "$(basename "$d")" 2>&1)"; rc=$?
if [ "$rc" = 3 ] && grep -qi 'MISSING-RETRO' <<<"$out"; then
  ok "21b RELATIVE target resolves git dates correctly → REFUSED exit 3 (FIX-1 regression pin)"
else
  no "21b RELATIVE target resolves git dates correctly → REFUSED exit 3 (FIX-1 regression pin)" "rc=$rc :: $(grep -i retro <<<"$out" | head -2)"
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
  # PSA_PRE_ROW (kit #1887): when set, that data row is committed into the BASELINE state, i.e. it exists as of
  # the prior retro's commit and so belongs to an EARLIER run.
  if [ -n "${PSA_PRE_ROW:-}" ]; then
    printf '%s\n' "$PSA_PRE_ROW" > "$corpus/.pre-row"
    awk -v rowf="$corpus/.pre-row" 'BEGIN{getline row < rowf} {print} index($0,"| 1 | 2026-07-07")==1{print row}' "$corpus/RESEARCH-STATE.md" > "$corpus/RESEARCH-STATE.md.new" \
      && mv "$corpus/RESEARCH-STATE.md.new" "$corpus/RESEARCH-STATE.md"
    rm -f "$corpus/.pre-row"
  fi
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
  # Close retro (git commit AFTER blocks): satisfies MISSING-RETRO gate (D6). prior_retro_epoch
  # stays at the 2026-02-01 old retro — the OBPC window still spans the 2026-03-xx block commits.
  printf '<!-- review-status: pending -->\n# Close retro — git fixture\n' > "$corpus/retros/2026-close-retro.md"
  git -C "$corpus" add retros/2026-close-retro.md
  GIT_AUTHOR_DATE="2026-04-01T00:00:00" GIT_COMMITTER_DATE="2026-04-01T00:00:00" git -C "$corpus" commit -q -m "close retro"
  # deliberately dirty on return — see the comment in mkgood_git above (#970 F1 real-flow contract).
  bash "$HERE/../research-sdd-status.sh" "$corpus" --sync-state >/dev/null 2>&1
}

# mkvcorr <dir> — good corpus + block 2 declares "Corrects [Block 1]" while block 1 has no backlink.
mkvcorr() {
  mkgood "$1"
  printf '# Block 2 — correction\nCorrects [Block 1] §1.1 — the earlier claim was wrong.\n' > "$1/t-block2.md"
  bash "$HERE/../research-sdd-status.sh" "$1" --sync-state >/dev/null 2>&1   # keep the mirror consistent with 2 blocks
}

# mkvfocus <dir> <focus> — two-focus corpus (mkmulti) where <focus> gets a block 2 declaring "Corrects [Block 1]"
# with no backlink (a one-directional correction INSIDE that focus); the other focus stays clean.
mkvfocus() {
  mkmulti "$1"
  printf '# Block 2 — correction\nCorrects [Block 1] §1.1 — the earlier claim was wrong.\n' > "$1/$2-block2.md"
  bash "$HERE/../research-sdd-status.sh" "$1" --sync-state --focus "$2" >/dev/null 2>&1
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

# mkrun_git_psa <corpus> <marker> — the `together` corpus (B1+B2 in ONE commit) plus an iteration-history row
# whose cell records <marker> (e.g. 'method: per-section-agent · 2 sections').
mkrun_git_psa() {
  mkrun_git "$1" together
  # $3 = row date (default in-window); $4 = raw line to insert INSTEAD of a table row (prose/fence cases)
  if [ -n "${4:-}" ]; then printf '%s\n' "$4" > "$1/.psa-row"
  else printf '| 2 | %s | import | B1,B2 | no · inline · %s | 0 |\n' "${3:-2026-07-08}" "$2" > "$1/.psa-row"; fi
  awk -v rowf="$1/.psa-row" 'BEGIN{while ((getline row < rowf) > 0) rows=rows row "\n"} {L[NR]=$0; if ($0 ~ /^\| [0-9]+ \|/) last=NR} END{for(i=1;i<=NR;i++){print L[i]; if(i==last) printf "%s", rows}}' "$1/RESEARCH-STATE.md" > "$1/RESEARCH-STATE.md.new" \
    && mv "$1/RESEARCH-STATE.md.new" "$1/RESEARCH-STATE.md"
  rm -f "$1/.psa-row"
}

# 22a — COMMIT EXEMPTION (kit #1887): ONE import commit with 2 blocks + iteration history recording
#       `method: per-section-agent · 2 sections` → NO WARN, exit 0, and a visible exemption note.
d="$TMP/one-block-psa"; mkrun_git_psa "$d" 'method: per-section-agent · 2 sections'
out="$(bash "$SUT" "$d" 2>&1)"; rc=$?
if [ "$rc" = 0 ] && ! grep -qi 'WARN: ONE-BLOCK-PER-COMMIT' <<<"$out" && grep -qi 'exempt from ONE-BLOCK-PER-COMMIT' <<<"$out"; then
  ok "22a per-section-agent import commit (2 blocks, marker N=2) → exempt, no WARN, note printed"
else no "22a psa-exempt: rc=$rc :: $(grep -iE 'one-block' <<<"$out" | head -2)"; fi

# 22b — the marker must cover the commit: N=1 < 2 blocks in one commit → still WARNs (stale/short marker).
d="$TMP/one-block-psa-short"; mkrun_git_psa "$d" 'method: per-section-agent · 1 sections'
out="$(bash "$SUT" "$d" 2>&1)"; rc=$?
if [ "$rc" = 0 ] && grep -qi 'WARN: ONE-BLOCK-PER-COMMIT' <<<"$out"; then
  ok "22b marker N=1 < 2 blocks in one commit → ONE-BLOCK-PER-COMMIT WARN still fires"
else no "22b psa-short: rc=$rc :: $(grep -iE 'one-block' <<<"$out" | head -2)"; fi

# 22c — a sequential run (different method text) with a multi-block commit is NOT exempt.
d="$TMP/one-block-seq"; mkrun_git_psa "$d" 'method: sequential · 2 sections'
out="$(bash "$SUT" "$d" 2>&1)"; rc=$?
if [ "$rc" = 0 ] && grep -qi 'WARN: ONE-BLOCK-PER-COMMIT' <<<"$out"; then
  ok "22c non-per-section-agent method + multi-block commit → WARN still fires (exemption never covers sequential)"
else no "22c seq-not-exempt: rc=$rc :: $(grep -iE 'one-block' <<<"$out" | head -2)"; fi

# 22d — C1 (exact boundary): a STALE marker row that already existed AS OF the prior retro's commit (here even
#       dated the retro's own day, 2026-02-01), N=20, must not excuse a later multi-block commit → WARN fires.
d="$TMP/one-block-psa-stale"
PSA_PRE_ROW='| 2 | 2026-02-01 | old | B0 | no · inline · method: per-section-agent · 20 sections | 0 |' mkrun_git "$d" together
out="$(bash "$SUT" "$d" 2>&1)"; rc=$?
if [ "$rc" = 0 ] && grep -qi 'WARN: ONE-BLOCK-PER-COMMIT' <<<"$out" && ! grep -qi 'exempt from ONE-BLOCK' <<<"$out"; then
  ok "22d stale N=20 row present at the prior retro's commit → no exemption, WARN fires (C1)"
else no "22d psa-stale: rc=$rc :: $(grep -iE 'one-block' <<<"$out" | head -2)"; fi

# 22d2 — the current run's row dated the SAME DAY as the prior retro (2026-02-01) is still current: it was
#        added after the retro's commit, so the exact boundary exempts it (a day-floor would be ambiguous).
d="$TMP/one-block-psa-sameday"; mkrun_git_psa "$d" 'method: per-section-agent · 2 sections' 2026-02-01
out="$(bash "$SUT" "$d" 2>&1)"; rc=$?
if [ "$rc" = 0 ] && ! grep -qi 'WARN: ONE-BLOCK-PER-COMMIT' <<<"$out" && grep -qi 'exempt from ONE-BLOCK-PER-COMMIT' <<<"$out"; then
  ok "22d2 current-run row dated the retro's own day → exempt (exact boundary, no day-floor ambiguity)"
else no "22d2 psa-sameday: rc=$rc :: $(grep -iE 'one-block' <<<"$out" | head -2)"; fi

# 22d3 — a stale row at the retro's commit AND a smaller current-run row: only the current-run N counts.
d="$TMP/one-block-psa-both"
PSA_PRE_ROW='| 2 | 2026-02-01 | old | B0 | no · inline · method: per-section-agent · 20 sections | 0 |' mkrun_git_psa "$d" 'method: per-section-agent · 1 sections' 2026-07-08
out="$(bash "$SUT" "$d" 2>&1)"; rc=$?
if [ "$rc" = 0 ] && grep -qi 'WARN: ONE-BLOCK-PER-COMMIT' <<<"$out"; then
  ok "22d3 stale N=20 + current-run N=1 → N=1 governs, 2-block commit still WARNs"
else no "22d3 psa-both: rc=$rc :: $(grep -iE 'one-block' <<<"$out" | head -2)"; fi

# 22e — W2: the marker in a blockquote / fenced table row / non-numeric-first-cell row never exempts.
d="$TMP/one-block-psa-prose"; mkrun_git_psa "$d" "" "" '> e.g. method: per-section-agent · 40 sections'
out="$(bash "$SUT" "$d" 2>&1)"; rc=$?
if [ "$rc" = 0 ] && grep -qi 'WARN: ONE-BLOCK-PER-COMMIT' <<<"$out"; then
  ok "22e marker in a blockquote line → no exemption, WARN fires (W2)"
else no "22e psa-prose: rc=$rc :: $(grep -iE 'one-block' <<<"$out" | head -2)"; fi
d="$TMP/one-block-psa-fence"; mkrun_git_psa "$d" "" "" $'```\n| 2 | 2026-07-08 | x | B1,B2 | method: per-section-agent · 40 sections | 0 |\n```'
out="$(bash "$SUT" "$d" 2>&1)"; rc=$?
if [ "$rc" = 0 ] && grep -qi 'WARN: ONE-BLOCK-PER-COMMIT' <<<"$out"; then
  ok "22e2 marker in a fenced table row → no exemption, WARN fires (W2)"
else no "22e2 psa-fence: rc=$rc :: $(grep -iE 'one-block' <<<"$out" | head -2)"; fi
d="$TMP/one-block-psa-nonnum"; mkrun_git_psa "$d" "" "" '| n/a | 2026-07-08 | x | B1,B2 | method: per-section-agent · 40 sections | 0 |'
out="$(bash "$SUT" "$d" 2>&1)"; rc=$?
if [ "$rc" = 0 ] && grep -qi 'WARN: ONE-BLOCK-PER-COMMIT' <<<"$out"; then
  ok "22e3 row with a non-numeric first cell → no exemption, WARN fires (W2)"
else no "22e3 psa-nonnum: rc=$rc :: $(grep -iE 'one-block' <<<"$out" | head -2)"; fi

# 22e4 — W2: a pipe-less line whose first cell is numeric is not a table row (leading-pipe filter pinned alone).
d="$TMP/one-block-psa-nopipe"; mkrun_git_psa "$d" "" "" '2 | 2026-07-08 | x | B1,B2 | method: per-section-agent · 40 sections | 0'
out="$(bash "$SUT" "$d" 2>&1)"; rc=$?
if [ "$rc" = 0 ] && grep -qi 'WARN: ONE-BLOCK-PER-COMMIT' <<<"$out"; then
  ok "22e4 pipe-less numeric-first line → no exemption, WARN fires (W2)"
else no "22e4 psa-nopipe: rc=$rc :: $(grep -iE 'one-block' <<<"$out" | head -2)"; fi

# 22f — S4: the match is exact — an ASCII separator spelling is no marker.
d="$TMP/one-block-psa-spell"; mkrun_git_psa "$d" 'method: per-section-agent - 2 sections'
out="$(bash "$SUT" "$d" 2>&1)"; rc=$?
if [ "$rc" = 0 ] && grep -qi 'WARN: ONE-BLOCK-PER-COMMIT' <<<"$out"; then
  ok "22f inexact marker spelling (ASCII hyphen separator) → no exemption, WARN fires (S4)"
else no "22f psa-spell: rc=$rc :: $(grep -iE 'one-block' <<<"$out" | head -2)"; fi

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
  # Close retro (git commit AFTER blocks): satisfies MISSING-RETRO gate (D6).
  printf '<!-- review-status: pending -->\n# Close retro — git fixture\n' > "$corpus/retros/2026-close-retro.md"
  git -C "$corpus" add retros/2026-close-retro.md
  GIT_AUTHOR_DATE="2026-04-01T00:00:00" GIT_COMMITTER_DATE="2026-04-01T00:00:00" git -C "$corpus" commit -q -m "close retro"
  # deliberately dirty on return — see the comment in mkgood_git above (#970 F1 real-flow contract).
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

# mkrun_git_rename <corpus> — a hermetic git corpus for the ONE-BLOCK-PER-COMMIT × rename-detection
# reconciliation (RDD round 2, F4): baseline + retro (OLD dates), B1 in its OWN commit, then ONE
# iteration commit that RENAMES B1 (git mv, no content change) AND adds a genuinely NEW block B2.
# diff.renames=false is configured on the corpus — same config-dependence as retro-gate.sh's F1/#984
# rename bug: without forced rename detection, the mv shows as a plain D+A pair, and the renamed
# file's Added half is indistinguishable from a genuinely new block.
mkrun_git_rename() {
  local corpus="$1"
  mkdir -p "$corpus"
  git -C "$corpus" init -q -b main
  git -C "$corpus" config user.email t@example.com; git -C "$corpus" config user.name tester
  git -C "$corpus" config diff.renames false
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
  printf '# Block 1\nOriginal claim, long enough that a naive similarity heuristic still calls it a rename.\n' > "$corpus/t-block1.md"
  git -C "$corpus" add t-block1.md
  GIT_AUTHOR_DATE="2026-02-15T00:00:00" GIT_COMMITTER_DATE="2026-02-15T00:00:00" git -C "$corpus" commit -q -m "B1"
  # Iteration N+1: RENAME B1 (no content change) AND add a genuinely new B2 — one commit.
  git -C "$corpus" mv t-block1.md t-block1-renamed.md
  printf '# Block 2\nGenuinely new block.\n' > "$corpus/t-block2.md"
  git -C "$corpus" add -A
  GIT_AUTHOR_DATE="2026-03-01T00:00:00" GIT_COMMITTER_DATE="2026-03-01T00:00:00" git -C "$corpus" commit -q -m "rename B1 + add B2"
  # Close retro (git commit AFTER blocks): satisfies MISSING-RETRO gate (D6).
  printf '<!-- review-status: pending -->\n# Close retro — git fixture\n' > "$corpus/retros/2026-close-retro.md"
  git -C "$corpus" add retros/2026-close-retro.md
  GIT_AUTHOR_DATE="2026-04-01T00:00:00" GIT_COMMITTER_DATE="2026-04-01T00:00:00" git -C "$corpus" commit -q -m "close retro"
  # deliberately dirty on return — see the comment in mkgood_git above (#970 F1 real-flow contract).
  bash "$HERE/../research-sdd-status.sh" "$corpus" --sync-state >/dev/null 2>&1
}

# 23b — ONE-BLOCK-PER-COMMIT × rename detection (RDD round 2, F4): a commit that RENAMES an
#       existing block (no content change) and adds one genuinely new block must NOT trip the
#       detector, even on a corpus with diff.renames=false. Without -M forced on the detector's
#       `git show --diff-filter=A`, the renamed file's Added half (D+A, since diff.renames=false
#       disables rename detection) is indistinguishable from B2 — a false 2-block WARN. RED
#       before the fix: exactly this — see PR body for the RED run.
d="$TMP/one-block-rename"; mkrun_git_rename "$d"
out="$(bash "$SUT" "$d" 2>&1)"; rc=$?
if [ "$rc" = 0 ] && ! grep -qi 'ONE-BLOCK-PER-COMMIT' <<<"$out"; then
  ok "rename 1 block (diff.renames=false) + add 1 NEW block → no false ONE-BLOCK-PER-COMMIT WARN"
else no "one-block-rename: rc=$rc :: $(grep -iE 'one-block|block' <<<"$out" | head -1)"; fi

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
  # FIX 2 (issue #368): --sync-state on a multi-focus corpus now requires --focus; seed each in turn.
  bash "$HERE/../research-sdd-status.sh" "$d" --sync-state --focus alpha >/dev/null 2>&1
  bash "$HERE/../research-sdd-status.sh" "$d" --sync-state --focus beta  >/dev/null 2>&1
  # Seed a fresh close-retro so the MISSING-RETRO gate (D6) is silent.
  add_close_retro "$d"
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
cp "$HERE/../lib/block-files.sh"  "$tbE/lib/block-files.sh"   # required helper (block discriminator)
cp "$HERE/../lib/blocked-rows.sh" "$tbE/lib/blocked-rows.sh"
# STUB: enumeration returns nothing, as a permission-denied find would.
printf '%s\n' '# shellcheck disable=SC2148' ". \"$HERE/../lib/state-files.sh\"" 'list_state_files() { return 0; }' > "$tbE/lib/state-files.sh"
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
cp "$HERE/../lib/block-files.sh"  "$tbNE/lib/block-files.sh"  # required helper (block discriminator)
cp "$HERE/../lib/blocked-rows.sh" "$tbNE/lib/blocked-rows.sh"
# STUB: enumeration returns two paths that do not exist — simulates paths that vanished
# between the find scan and the inspection loop, or a broken enumerator outputting garbage.
printf '%s\n' '# shellcheck disable=SC2148' ". \"$HERE/../lib/state-files.sh\"" \
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
  # Seed fresh close-retros in both focuses so the MISSING-RETRO gate (D6) is silent.
  add_close_retro "$d/alpha"
  add_close_retro "$d/beta"
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

# 36 — RENAME TRADEOFF (accepted, --follow removed from rsdd_added_epoch() for performance, mirrors
#      sweep-retros.sh and sweep-audits.sh). A retro is CREATED at a deep-past date under one name,
#      then RENAMED in a later commit (AFTER the block was added). Without --follow, rsdd_added_epoch()
#      dates the retro from its RENAME commit (2026-02-01, after the block at 2026-01-10) → newest retro
#      epoch > newest block epoch → NO MISSING-RETRO WARN. With --follow (pre-fix), the original
#      creation date (year 2000) would be used → newest block epoch > newest retro epoch → WARN fires.
#      This case is RED against the --follow'd SUT (WARN fires) and GREEN after removal (no WARN).
d="$TMP/rename-tradeoff"
mkdir -p "$d"
git -C "$d" init -q -b main
git -C "$d" config user.email t@example.com
git -C "$d" config user.name tester
cat > "$d/RESEARCH-STATE.md" <<'EOF'
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
: > "$d/INDEX.md"
git -C "$d" add -A
GIT_AUTHOR_DATE="2026-01-01T00:00:00" GIT_COMMITTER_DATE="2026-01-01T00:00:00" \
  git -C "$d" commit -q -m "baseline"
printf '# Block 1\nBody.\n' > "$d/t-block1.md"
git -C "$d" add t-block1.md
GIT_AUTHOR_DATE="2026-01-10T00:00:00" GIT_COMMITTER_DATE="2026-01-10T00:00:00" \
  git -C "$d" commit -q -m "add block1"
mkdir -p "$d/retros"
printf '# retro\n' > "$d/retros/orig-retro.md"
git -C "$d" add retros/orig-retro.md
GIT_AUTHOR_DATE="2000-01-01T00:00:00" GIT_COMMITTER_DATE="2000-01-01T00:00:00" \
  git -C "$d" commit -q -m "add orig-retro.md (deep-past)"
git -C "$d" mv retros/orig-retro.md retros/retro-focus.md
GIT_AUTHOR_DATE="2026-02-01T00:00:00" GIT_COMMITTER_DATE="2026-02-01T00:00:00" \
  git -C "$d" commit -q -m "rename orig-retro.md to retro-focus.md"
# deliberately dirty on return — see the comment in mkgood_git above (#970 F1 real-flow contract).
bash "$HERE/../research-sdd-status.sh" "$d" --sync-state >/dev/null 2>&1
out="$(bash "$SUT" "$d" 2>&1)"; rc=$?
if [ "$rc" = 0 ] && ! grep -qi 'MISSING-RETRO' <<<"$out"; then
  ok "36 renamed-after-creation retro dated from rename commit (after block) → no MISSING-RETRO WARN (accepted --follow tradeoff)"
else
  no "36 renamed-after-creation retro dated from rename commit (after block) → no MISSING-RETRO WARN (accepted --follow tradeoff)" \
     "rc=$rc :: $(grep -i 'retro\|MISSING' <<<"$out" | head -2)"
fi

# 36b — STRUCTURAL guard (kit issue #1401, defence in depth): every `git -C "$d" log ... --diff-filter=A`
#       CODE line in the SUT carries --no-renames (comments stripped, so a comment cannot satisfy it).
#       On git 2.55 the pathspec stops rename pairing, so a behavioural case cannot go RED for a
#       flag-less call today; this source-level pin is the assertion that bites.
c36b_counts() {   # $1 = SUT path → "<total> <with --no-renames>"
  local t o code
  code="$(sed -E 's/^[[:space:]]*#.*$//; s/[[:space:]]#.*$//' "$1")"
  t="$(grep -c 'git -C "\$d" log .*--diff-filter=A' <<<"$code")"
  o="$(grep 'git -C "\$d" log .*--diff-filter=A' <<<"$code" | grep -c -- '--no-renames')"
  printf '%s %s' "$t" "$o"
}
read -r _c36b_total _c36b_ok <<<"$(c36b_counts "$SUT")"
if [ "$_c36b_total" -ge 1 ] && [ "$_c36b_total" = "$_c36b_ok" ]; then
  ok "36b every 'git log --diff-filter=A' call in SUT passes --no-renames ($_c36b_ok/$_c36b_total)"
else
  no "36b every 'git log --diff-filter=A' call in SUT must pass --no-renames (total=$_c36b_total with-flag=$_c36b_ok)"
fi

# 37 — MISSING-RETRO GATE (D6: promoted from advisory WARN to hard gate): a corpus with blocks
#      advanced past the newest §18 retro must REFUSE with exit 3 (gate code), not merely WARN.
#      mkgood now seeds a close-retro; remove it to expose the gate (no retro → condition fires).
d="$TMP/missing-retro-gate"; mkgood "$d"; rm -rf "$d/retros"
out="$(bash "$SUT" "$d" 2>&1)"; rc=$?
if [ "$rc" = 3 ] && grep -qiE 'MISSING-RETRO.*REFUSE' <<<"$out"; then
  ok "37 MISSING-RETRO gate: corpus advanced past retro → REFUSED (exit 3)"
else no "37 MISSING-RETRO gate: exit=$rc (want 3) / gate line=$(grep -cE 'MISSING-RETRO.*REFUSE' <<<"$out") :: $(head -2 <<<"$out")"; fi

# 37a — NEGATIVE CONTROL: a corpus with a valid pending retro (newer than all blocks) must still
#       close (exit 0) — the MISSING-RETRO gate has no false positive.
d="$TMP/missing-retro-gate-neg"; mkgood "$d"; mkdir -p "$d/retros"
: > "$d/retros/2030-01-01-fresh.md"; touch -d '2030-01-01' "$d/retros/2030-01-01-fresh.md"
out="$(bash "$SUT" "$d" 2>&1)"; rc=$?
if [ "$rc" = 0 ] && ! grep -qiE 'MISSING-RETRO.*REFUSE' <<<"$out"; then
  ok "37a MISSING-RETRO gate (neg): valid recent retro → archive passes (exit 0, no false positive)"
else no "37a MISSING-RETRO gate (neg): exit=$rc (want 0) :: $(grep -iE 'MISSING-RETRO|REFUSE' <<<"$out" | head -1)"; fi

# ==================== T-AR1 — --focus <name> scoping ====================

# 38 — T-AR1: --focus alpha scopes UF gate to alpha only; beta's UF=1 must not block alpha's archive.
d="$TMP/ar1-focus"; mkmulti "$d"
awk '/^undocumented_findings:/{$0="undocumented_findings: 1"} {print}' \
  "$d/RESEARCH-STATE-beta.md" > "$d/RS.tmp" && mv "$d/RS.tmp" "$d/RESEARCH-STATE-beta.md"
out38="$(bash "$SUT" "$d" --focus alpha --dry-run 2>&1)"; rc38=$?
[ "$rc38" = 0 ] \
  && ok "38 T-AR1: --focus alpha scopes UF gate (beta UF=1 ignored) → archive passes (exit 0)" \
  || no "38 T-AR1: --focus alpha: exit=$rc38 (want 0) :: $(grep -iE 'refuse|uf|undoc' <<<"$out38" | head -2)"

# 39 — T-AR1: --focus with unknown slug → loud exit 2, error names the missing focus.
d="$TMP/ar1-unknown"; mkmulti "$d"
out39="$(bash "$SUT" "$d" --focus unknown-slug 2>&1)"; rc39=$?
[ "$rc39" = 2 ] && grep -qi 'unknown-slug' <<<"$out39" \
  && ok "39 T-AR1: --focus unknown-slug → exit 2, error names missing focus" \
  || no "39 T-AR1: unknown-slug: exit=$rc39 (want 2) / mention=$(grep -ci 'unknown-slug' <<<"$out39") :: $(head -1 <<<"$out39")"

# 40 — T-AR1 regression: no --focus → default behavior preserved (exit 0 on clean corpus).
d="$TMP/ar1-default"; mkgood "$d"
out40="$(bash "$SUT" "$d" --dry-run 2>&1)"; rc40=$?
[ "$rc40" = 0 ] \
  && ok "40 T-AR1 regression: no --focus → archive proceeds normally (exit 0)" \
  || no "40 T-AR1 regression: no --focus: exit=$rc40 (want 0) :: $(head -2 <<<"$out40")"

# 40b — kit issue #1818: a FLAT multi-focus corpus (root + RESEARCH-STATE-aaa.md). Without --focus archive must act
# on the ROOT, not on the focus file that sorts before it (C-locale '-' < '.'). The two files carry DIFFERENT
# iteration-history row counts (root 1, focus 2), so the mirror-facts line names which file was read.
d="$TMP/ar-1818-rootpref"; mkgood "$d"
cp "$d/RESEARCH-STATE.md" "$d/RESEARCH-STATE-aaa.md"
sed -i '/^| 1 | 2026/a | 2 | 2026-07-08 | second | B1 | no · inline | 0 |' "$d/RESEARCH-STATE-aaa.md"
bash "$HERE/../research-sdd-status.sh" "$d" --sync-state --focus aaa >/dev/null 2>&1
out40b="$(bash "$SUT" "$d" --dry-run 2>&1)"; rc40b=$?
[ "$rc40b" = 0 ] && grep -q 'iteration-history rows: 1$' <<<"$out40b" \
  && ok "40b #1818: flat root + focus, no --focus → archive acts on the ROOT (history rows 1, not the focus file's 2)" \
  || no "40b #1818: rc=$rc40b :: $(grep -E 'iteration-history|REFUSE|FAIL' <<<"$out40b" | head -3)"

# NEGATIVE CONTROLS (--prove-teeth) — every mutant is a COPY of the SUT built by lib/mutant.sh (kit issues #943, #1299),
# which REFUSES an empty, byte-identical, syntax-broken or live-tree mutant. Each tooth asserts the exact GOOD verdict
# (rc + positive output) on the ORIGINAL against the same fixture AND the specific BAD verdict (rc + positive output)
# on the mutant; a crash or empty output can satisfy neither side.
if [ "${1:-}" = "--prove-teeth" ]; then
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  mutant_bootstrap mutant_chain mutant_tooth || exit 2
  MUT="$(mktemp -d)"
  trap 'chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP" ${MUT:+"$MUT"}' EXIT
  export MUTANT_TOOTH_ICASE=1   # the output predicates below are case-insensitive, as they always were
  # Thin counting wrappers over the shared helpers: they print their own FAIL/PASS lines and never touch this
  # suite's counters, so the caller counts.
  # mk_sed LABEL OUT EXPR...  build $OUT from $SUT, one sed stage per EXPR (mutant_chain: each stage must change
  # the original ON ITS OWN, a chain whose first stage applies would hide a later no-op stage).
  mk_sed(){ local label="$1" out="$2"; shift 2; mutant_chain "$label" "$SUT" "$out" "$@" || { fail=$((fail+1)); return 1; }; }
  # tooth LABEL GOOD_RC BAD_RC MUTANT [--good-has RE] [--good-lacks RE] [--bad-has RE] [--bad-lacks RE] -- ARGV...
  # The shared mutant_tooth runs ARGV against the original ('@SUT@' -> $SUT) and the mutant: PASS only when the
  # original returns exactly GOOD_RC (output matches --good-has, not --good-lacks) AND the mutant returns exactly
  # BAD_RC (output matches --bad-has, not --bad-lacks).
  tooth(){ if mutant_tooth "$@"; then pass=$((pass+1)); else fail=$((fail+1)); fi; }
  # run_on_fix [VAR=val...] SUT FIXDIR [ARGS...]  run SUT on a FRESH copy of FIXDIR (a real, non --dry-run archive
  # of the first run must not leak state into the second), optionally under extra environment variables.
  run_on_fix(){
    local -a ev=()
    while [[ "${1:-}" == [A-Za-z_]*=* ]]; do ev+=("$1"); shift; done
    local sut="$1" fix="$2" f rc; shift 2
    f="$(mktemp -d "$MUT/fix.XXXXXX")" && rm -rf "$f" && cp -a "$fix" "$f" || { echo "run_on_fix: could not copy fixture $fix" >&2; return 99; }
    env ${ev[@]+"${ev[@]}"} bash "$sut" "$f" "$@"; rc=$?
    rm -rf "$f"; return "$rc"
  }
  # Every mutant is a copy of the SUT placed in $MUT, so the siblings and lib/ it resolves via $(dirname $0) are
  # copied there ONCE.
  mkdir -p "$MUT/lib"
  cp "$HERE/../verify-state.sh" "$HERE/../verify-sources.sh" "$HERE/../scan-secrets.sh" "$HERE/../verify-corrections.sh" "$MUT/"
  cp "$HERE/../lib/retro-status.sh" "$HERE/../lib/focus-prefix.sh" "$HERE/../lib/state-files.sh" "$HERE/../lib/block-files.sh" "$HERE/../lib/blocked-rows.sh" "$MUT/lib/"
  REFUSE_RE='REFUSED: reconcile'   # printed by the SUT's gate on exit 3
  ARCH_RE='^  archived'            # printed by the SUT's last line on exit 0
  UF_RE='undocumented_findings: REFUSE'

  echo "-- teeth: neuter the gate in a mutant, expect the stale fixture to archive instead of refusing --"
  d="$TMP/teeth"; mkgood "$d"; sed -i 's#2 / 3 closed#3 / 3 closed#' "$d/RESEARCH-STATE.md"   # fixture edit: coverage claims all closed while a gap is pending
  mk_sed "teeth" "$MUT/archive.MUTANT.sh" 's/gate_rc=1/gate_rc=0/g' \
    && tooth "teeth: gate-neutered mutant archives a stale corpus → gate test has teeth" 3 0 "$MUT/archive.MUTANT.sh" \
         --good-has "$REFUSE_RE" --bad-has "$ARCH_RE" --bad-lacks "$REFUSE_RE" -- run_on_fix @SUT@ "$d"

  echo "-- teeth: revert the ADDED-only filter (drop --diff-filter=A) so a backlink-edit counts; expect a WARN --"
  mk_sed "teeth(23a)" "$MUT/archive.ADDMUTANT.sh" 's/show --diff-filter=A -M --name-only/show --name-only/' \
    && { mkrun_git_backlink "$TMP/teeth-backlink"
         tooth "teeth: name-only mutant WARNs on the add-1+modify-1 iteration → case 23a has teeth" 0 0 "$MUT/archive.ADDMUTANT.sh" \
           --good-has "$ARCH_RE" --good-lacks 'ONE-BLOCK-PER-COMMIT' --bad-has 'ONE-BLOCK-PER-COMMIT' -- run_on_fix @SUT@ "$TMP/teeth-backlink"; }

  echo "-- teeth: drop -M from the block detector (RDD round 2, F4) — expect a false WARN on the rename fixture --"
  mk_sed "teeth(23b)" "$MUT/archive.NOMUTANT.sh" 's/show --diff-filter=A -M --name-only/show --diff-filter=A --name-only/' \
    && { mkrun_git_rename "$TMP/teeth-rename"
         tooth "teeth: -M dropped → false WARN on rename+add under diff.renames=false → case 23b has teeth" 0 0 "$MUT/archive.NOMUTANT.sh" \
           --good-has "$ARCH_RE" --good-lacks 'ONE-BLOCK-PER-COMMIT' --bad-has 'ONE-BLOCK-PER-COMMIT' -- run_on_fix @SUT@ "$TMP/teeth-rename"; }

  echo "-- teeth: neuter the #1887 exemption — the exempt fixture must WARN again --"
  mk_sed "teeth(22a)" "$MUT/archive.PSAMUTANT.sh" 's/if \[ "\$psa_max" -ge "\${nbf:-0}" \]; then/if false; then/' \
    && { mkrun_git_psa "$TMP/teeth-psa" 'method: per-section-agent · 2 sections'
         tooth "teeth: exemption neutered → per-section-agent import commit WARNs → case 22a has teeth" 0 0 "$MUT/archive.PSAMUTANT.sh" \
           --good-has "$ARCH_RE" --good-lacks 'WARN: ONE-BLOCK-PER-COMMIT' --bad-has 'WARN: ONE-BLOCK-PER-COMMIT' -- run_on_fix @SUT@ "$TMP/teeth-psa"; }

  echo "-- teeth: #1887 C1 — drop the run boundary (skip=0); the stale N=20 row must then wrongly exempt --"
  mk_sed "teeth(22d)" "$MUT/archive.PSAWIN.sh" 's/rows > skip \&\& match/rows > 0 \&\& match/' \
    && { PSA_PRE_ROW='| 2 | 2026-02-01 | old | B0 | no · inline · method: per-section-agent · 20 sections | 0 |' mkrun_git "$TMP/teeth-psa-stale" together
         tooth "teeth: boundary dropped → stale row exempts → case 22d has teeth" 0 0 "$MUT/archive.PSAWIN.sh" \
           --good-has "$ARCH_RE" --good-has 'WARN: ONE-BLOCK-PER-COMMIT' --bad-lacks 'WARN: ONE-BLOCK-PER-COMMIT' -- run_on_fix @SUT@ "$TMP/teeth-psa-stale"; }

  echo "-- teeth: #1887 W2 — accept lines without a leading pipe; a pipe-less numeric-first row must then wrongly exempt --"
  mk_sed "teeth(22e)" "$MUT/archive.PSATBL.sh" 's/if (substr(l,1,1)!="|") next/if (0) next/' \
    && { mkrun_git_psa "$TMP/teeth-psa-prose" "" "" '2 | 2026-07-08 | x | B1,B2 | method: per-section-agent · 40 sections | 0'
         tooth "teeth: leading-pipe filter dropped → pipe-less row exempts → case 22e has teeth" 0 0 "$MUT/archive.PSATBL.sh" \
           --good-has "$ARCH_RE" --good-has 'WARN: ONE-BLOCK-PER-COMMIT' --bad-lacks 'WARN: ONE-BLOCK-PER-COMMIT' -- run_on_fix @SUT@ "$TMP/teeth-psa-prose"; }

  echo "-- teeth: #1887 W2 — drop the numeric-first-cell and fence filters --"
  mk_sed "teeth(22e3)" "$MUT/archive.PSANUM.sh" 's/if (a\[1\] !~ \/\^\[0-9\]+\$\/) next/if (0) next/' \
    && { mkrun_git_psa "$TMP/teeth-psa-nonnum" "" "" '| n/a | 2026-07-08 | x | B1,B2 | method: per-section-agent · 40 sections | 0 |'
         tooth "teeth: numeric-first-cell filter dropped → non-data row exempts → case 22e3 has teeth" 0 0 "$MUT/archive.PSANUM.sh" \
           --good-has "$ARCH_RE" --good-has 'WARN: ONE-BLOCK-PER-COMMIT' --bad-lacks 'WARN: ONE-BLOCK-PER-COMMIT' -- run_on_fix @SUT@ "$TMP/teeth-psa-nonnum"; }
  mk_sed "teeth(22e2)" "$MUT/archive.PSAFENCE.sh" 's/f \&\& !fence {/f {/' \
    && { mkrun_git_psa "$TMP/teeth-psa-fence" "" "" $'```\n| 2 | 2026-07-08 | x | B1,B2 | method: per-section-agent · 40 sections | 0 |\n```'
         tooth "teeth: fence filter dropped → fenced row exempts → case 22e2 has teeth" 0 0 "$MUT/archive.PSAFENCE.sh" \
           --good-has "$ARCH_RE" --good-has 'WARN: ONE-BLOCK-PER-COMMIT' --bad-lacks 'WARN: ONE-BLOCK-PER-COMMIT' -- run_on_fix @SUT@ "$TMP/teeth-psa-fence"; }

  echo "-- teeth: AR-VCORR — neuter the linter call (force rc 0); the one-directional corpus must stop REFUSING --"
  d="$TMP/vcorr-teeth"; mkvcorr "$d"
  mk_sed "teeth(vcorr)" "$MUT/archive.VCMUTANT.sh" 's/_vc_rc=\$?  # AR-VCORR-GATE/_vc_rc=0; _vc_out="   ok     MUTANT"  # MUTANT/' \
    && tooth "teeth(vcorr): linter result ignored → one-directional corpus archives with 'ok' → case AR-VCORR has teeth" 3 0 "$MUT/archive.VCMUTANT.sh" \
         --good-has 'verify-corrections : FAIL' --bad-has 'verify-corrections : ok' --bad-lacks 'verify-corrections : FAIL' -- run_on_fix @SUT@ "$d" --dry-run

  echo "-- teeth: AR-VCORR refuse — neuter ONLY the gate_rc=1 of the verify-corrections refusal; the FAIL line stays but the close proceeds --"
  mk_sed "teeth(vcorr-ref)" "$MUT/archive.VCREFMUTANT.sh" 's/gate_rc=1  # vcorr-gate-refuse/gate_rc=0  # MUTANT-vcorr-refuse/' \
    && tooth "teeth(vcorr-ref): refusal neutered → FAIL printed yet exit 0 → the refusal is load-bearing" 3 0 "$MUT/archive.VCREFMUTANT.sh" \
         --good-has "$REFUSE_RE" --bad-has 'verify-corrections : FAIL' --bad-lacks "$REFUSE_RE" -- run_on_fix @SUT@ "$d" --dry-run

  echo "-- teeth: AR-VCORR override — make the flag inert; with the flag the corpus must then still REFUSE --"
  mk_sed "teeth(vcorr-ovr)" "$MUT/archive.VCOVRMUTANT.sh" 's/if \[ "\$allow_vc" = 1 \]; then  # AR-VCORR-OVERRIDE$/if false; then  # MUTANT-vcorr-override/' \
    && tooth "teeth(vcorr-ovr): override ignored → flagged corpus still refuses → override branch has teeth" 0 3 "$MUT/archive.VCOVRMUTANT.sh" \
         --good-has 'verify-corrections : OVERRIDDEN' --bad-has "$REFUSE_RE" --bad-lacks 'verify-corrections : OVERRIDDEN' -- run_on_fix @SUT@ "$d" --dry-run --allow-unreciprocated-corrections

  echo "-- teeth: AR-VCORR partial — blind the ok-partial match; the PARTIAL corpus must then read a bare ok --"
  d="$TMP/vcorr-teeth-partial"; mkgood "$d"
  printf '# Block 2 — correction\nCorrects [Block 9] §1.1 — the earlier claim was wrong.\n' > "$d/t-block2.md"
  bash "$HERE/../research-sdd-status.sh" "$d" --sync-state >/dev/null 2>&1
  mk_sed "teeth(vcorr-part)" "$MUT/archive.VCPARTMUTANT.sh" "s/grep -q '^ \*ok-partial ' <<<\"\$_vc_out\"/grep -q 'ZZZ-never' <<<\"\$_vc_out\"/" "s/elif grep -q '^ \*ok ' <<<\"\$_vc_out\"; then  # AR-VCORR-OK-POSITIVE/elif true; then  # MUTANT/" \
    && tooth "teeth(vcorr-part): ok-partial match broken → PARTIAL reads as bare ok → partial discrimination has teeth" 0 0 "$MUT/archive.VCPARTMUTANT.sh" \
         --good-has 'verify-corrections : PARTIAL' --bad-has 'verify-corrections : ok' --bad-lacks 'verify-corrections : PARTIAL' -- run_on_fix @SUT@ "$d" --dry-run

  echo "-- teeth: AR-VCORR exit-2 discrimination — break the no-block-files match; the no-blocks corpus must stop reading n/a --"
  d="$TMP/vcorr-teeth-nb"; mkgood "$d"; rm -f "$d/t-block1.md"
  mk_sed "teeth(vcorr-nb)" "$MUT/archive.VCNBMUTANT.sh" "s/grep -q 'no block files' <<<\"\$_vc_out\"/grep -q 'ZZZ-never' <<<\"\$_vc_out\"/" \
    && tooth "teeth(vcorr-nb): no-blocks match broken → n/a becomes ERROR did-not-run → exit-2 discrimination has teeth" 3 3 "$MUT/archive.VCNBMUTANT.sh" \
         --good-has 'verify-corrections : n/a' --bad-has 'did not run \(bad args' --bad-lacks 'verify-corrections : n/a' -- run_on_fix @SUT@ "$d" --dry-run

  echo "-- teeth: AR-VCORR count guard — drop the zero check; a drifted linter prefix must then print a 0 count --"
  mkdir -p "$MUT/stub" && cp -a "$MUT/lib" "$MUT/stub/" && cp "$MUT/verify-state.sh" "$MUT/verify-sources.sh" "$MUT/scan-secrets.sh" "$MUT/stub/"
  printf '#!/usr/bin/env bash\necho "ISSUE B2 corrects B1" >&2\nexit 1\n' > "$MUT/stub/verify-corrections.sh"; chmod +x "$MUT/stub/verify-corrections.sh"
  d="$TMP/vcorr-teeth-drift"; mkgood "$d"
  cp "$SUT" "$MUT/stub/archive.ORIG.sh"
  mk_sed "teeth(vcorr-cnt)" "$MUT/stub/archive.CNTMUTANT.sh" 's/elif \[ "\$_vc_n" -gt 0 \]; then/elif true; then/' \
    && tooth "teeth(vcorr-cnt): zero guard dropped → drifted linter (exit 1, no findings) archives silently → guard has teeth" 3 0 "$MUT/stub/archive.CNTMUTANT.sh" --orig "$MUT/stub/archive.ORIG.sh" \
         --good-has 'exited 1 with no findings' --bad-has "$ARCH_RE" --bad-lacks 'exited 1 with no findings' -- run_on_fix @SUT@ "$d" --dry-run

  echo "-- teeth: AR-VCORR degraded — blind the degraded: match; a degraded linter must then read as a (zero-count) FAIL, not DEGRADED --"
  mkdir -p "$MUT/stub2" && cp -a "$MUT/lib" "$MUT/stub2/" && cp "$MUT/verify-state.sh" "$MUT/verify-sources.sh" "$MUT/scan-secrets.sh" "$MUT/stub2/"
  printf '#!/usr/bin/env bash\necho "verify-corrections: degraded: awk not found on PATH; the corpus was NOT checked" >&2\nexit 1\n' > "$MUT/stub2/verify-corrections.sh"; chmod +x "$MUT/stub2/verify-corrections.sh"
  d="$TMP/vcorr-teeth-degraded"; mkgood "$d"
  cp "$SUT" "$MUT/stub2/archive.ORIG.sh"
  mk_sed "teeth(vcorr-deg)" "$MUT/stub2/archive.DEGMUTANT.sh" "s/if grep -q 'degraded:' <<<\"\$_vc_out\"; then  # AR-VCORR-DEGRADED/if false; then  # MUTANT/" \
    && tooth "teeth(vcorr-deg): degraded match broken → DEGRADED reads as a generic exit-1 ERROR → degraded discrimination has teeth" 3 3 "$MUT/stub2/archive.DEGMUTANT.sh" --orig "$MUT/stub2/archive.ORIG.sh" \
         --good-has 'verify-corrections : DEGRADED' --bad-has 'exited 1 with no findings' --bad-lacks 'verify-corrections : DEGRADED' -- run_on_fix @SUT@ "$d" --dry-run

  echo "-- teeth: AR-VCORR focus scope — classify every pair in-focus; the sibling-only corpus must then refuse --"
  d="$TMP/vcorr-teeth-sib"; mkvfocus "$d" beta
  mk_sed "teeth(vcorr-sib)" "$MUT/archive.VCSIBMUTANT.sh" 's/if \[ -z "\$_vc_c" \] || \[ -z "\$_vc_t" \]/if true || [ -z "$_vc_t" ]/' \
    && tooth "teeth(vcorr-sib): every pair in-focus → sibling failure refuses --focus alpha → the SIBLING classification has teeth" 0 3 "$MUT/archive.VCSIBMUTANT.sh" \
         --good-has 'verify-corrections : SIBLING' --bad-has 'verify-corrections : FAIL' --bad-lacks 'verify-corrections : SIBLING' -- run_on_fix @SUT@ "$d" --dry-run --focus alpha

  echo "-- teeth: AR-VCORR focus scope — classify every pair as sibling; the failing focus must then stop refusing --"
  mk_sed "teeth(vcorr-infocus)" "$MUT/archive.VCINFMUTANT.sh" 's/\[ "\$_vc_tp" = "\$_vc_fslug" \] || \[ "\$_vc_cp" = "\$_vc_fslug" \]/false/' \
    && tooth "teeth(vcorr-infocus): in-focus test neutered → failing focus beta archives → in-focus detection has teeth" 3 0 "$MUT/archive.VCINFMUTANT.sh" \
         --good-has 'verify-corrections : FAIL' --bad-has 'verify-corrections : SIBLING' --bad-lacks "$REFUSE_RE" -- run_on_fix @SUT@ "$d" --dry-run --focus beta

  echo "-- teeth: AR-VCORR focus unresolved — disable the no-focus-blocks guard; the unresolvable focus must then not read ERROR --"
  d="$TMP/vcorr-teeth-unres"; mkvfocus "$d" alpha; rm -f "$d/beta-block1.md"
  mk_sed "teeth(vcorr-unres)" "$MUT/archive.VCUNRMUTANT.sh" 's/\[ "\$_vc_fcount" -eq 0 \]; then/[ "$_vc_fcount" -eq 99 ]; then/' \
    && tooth "teeth(vcorr-unres): guard disabled → unresolvable focus classified sibling instead of ERROR → guard has teeth" 3 3 "$MUT/archive.VCUNRMUTANT.sh" \
         --good-has 'verify-corrections : ERROR — cannot scope' --bad-has 'verify-corrections : SIBLING' --bad-lacks 'verify-corrections : ERROR' -- run_on_fix @SUT@ "$d" --dry-run --focus beta

  echo "-- teeth (#1857): focus ownership by the correcting block's file prefix --"
  d="$TMP/vcorr-teeth-xcorr"; mkmulti "$d"
  printf '# Alpha Block 7\nCorrects `beta` [Block 1] §1.1 — the earlier claim was wrong.\n' > "$d/alpha-block7.md"
  bash "$HERE/../research-sdd-status.sh" "$d" --sync-state --focus alpha >/dev/null 2>&1
  mk_sed "teeth(vcorr-cp)" "$MUT/archive.VCCPMUTANT.sh" 's/ || \[ "\$_vc_cp" = "\$_vc_fslug" \]//' \
    && tooth "teeth(vcorr-cp): correcting-prefix test dropped → alpha's own correction of beta reads SIBLING → ownership by correcting file has teeth" 3 0 "$MUT/archive.VCCPMUTANT.sh" \
         --good-has 'FAIL   B7 corrects \[Block 1\] but beta-block1.md' --bad-has 'verify-corrections : SIBLING' --bad-lacks "$REFUSE_RE" -- run_on_fix @SUT@ "$d" --dry-run --focus alpha
  d="$TMP/vcorr-teeth-num"; mkvfocus "$d" beta
  printf '# Alpha Block 2\nBody.\n' > "$d/alpha-block2.md"; bash "$HERE/../research-sdd-status.sh" "$d" --sync-state --focus alpha >/dev/null 2>&1
  mk_sed "teeth(vcorr-ownall)" "$MUT/archive.VCOWNMUTANT.sh" 's/ || \[ "\$_vc_cp" = "\$_vc_fslug" \]; then  # AR-VCORR-IN-FOCUS/ || true; then  # AR-VCORR-IN-FOCUS/' \
    && tooth "teeth(vcorr-ownall): correcting-prefix test always true (the old over-broad ownership) → beta's own pair refuses --focus alpha" 0 3 "$MUT/archive.VCOWNMUTANT.sh" \
         --good-has 'verify-corrections : SIBLING' --bad-has 'verify-corrections : FAIL' --bad-lacks 'verify-corrections : SIBLING' -- run_on_fix @SUT@ "$d" --dry-run --focus alpha
  d="$TMP/alpha-block9-dir-teeth/corpus"; mkdir -p "$TMP/alpha-block9-dir-teeth"; mkvfocus "$d" beta
  mk_sed "teeth(vcorr-base)" "$MUT/archive.VCBASEMUTANT.sh" 's/^_vc_pfx() { basename "\$1" | sed/_vc_pfx() { printf "%s\\n" "$1" | sed/' \
    && tooth "teeth(vcorr-base): prefix read from the full path → a prefix-named directory breaks the focus scope → basename read has teeth" 0 3 "$MUT/archive.VCBASEMUTANT.sh" \
         --good-has 'verify-corrections : SIBLING' --bad-has 'verify-corrections : ERROR — cannot scope' --bad-lacks 'verify-corrections : SIBLING' -- run_on_fix @SUT@ "$d" --dry-run --focus alpha
  mkdir -p "$MUT/stub4" && cp -a "$MUT/lib" "$MUT/stub4/" && cp "$MUT/verify-state.sh" "$MUT/verify-sources.sh" "$MUT/scan-secrets.sh" "$MUT/stub4/"
  printf '#!/usr/bin/env bash\necho "   FAIL   B2 corrects [Block 1] but beta-block1.md has no reciprocal backlink to B2 (§14)"\nexit 1\n' > "$MUT/stub4/verify-corrections.sh"; chmod +x "$MUT/stub4/verify-corrections.sh"
  d="$TMP/vcorr-teeth-nocf"; mkvfocus "$d" beta
  cp "$SUT" "$MUT/stub4/archive.ORIG.sh"
  mk_sed "teeth(vcorr-nocf)" "$MUT/stub4/archive.NOCFMUTANT.sh" 's/ || \[ -z "\$_vc_cf" \]//' \
    && tooth "teeth(vcorr-nocf): unnamed correcting file no longer conservative → the pair reads SIBLING and archives → conservative default has teeth" 3 0 "$MUT/stub4/archive.NOCFMUTANT.sh" --orig "$MUT/stub4/archive.ORIG.sh" \
         --good-has 'verify-corrections : FAIL' --bad-has 'verify-corrections : SIBLING' --bad-lacks "$REFUSE_RE" -- run_on_fix @SUT@ "$d" --dry-run --focus alpha

  echo "-- teeth (#1868): the PARTIAL line counts typed AMBIG lines --"
  d="$TMP/vcorr-teeth-ambig"; mkgood "$d"
  printf '# Block 2 — correction\nCorrects B1 §1.1 — the earlier claim was wrong.\n' > "$d/t-block2.md"
  bash "$HERE/../research-sdd-status.sh" "$d" --sync-state >/dev/null 2>&1
  mk_sed "teeth(vcorr-amb)" "$MUT/archive.VCAMBMUTANT.sh" 's/^\(       _vc_amb=\).*/\1""/' \
    && tooth "teeth(vcorr-amb): AMBIG count dropped → PARTIAL line reports 0 typed ambiguous → the count has teeth" 0 0 "$MUT/archive.VCAMBMUTANT.sh" \
         --good-has '\(1 typed ambiguous' --bad-lacks '\(1 typed ambiguous' -- run_on_fix @SUT@ "$d" --dry-run

  echo "-- teeth: AR-VCORR positive ok — accept any exit 0; a linter printing no ok line must then read ok --"
  mkdir -p "$MUT/stub3" && cp -a "$MUT/lib" "$MUT/stub3/" && cp "$MUT/verify-state.sh" "$MUT/verify-sources.sh" "$MUT/scan-secrets.sh" "$MUT/stub3/"
  printf '#!/usr/bin/env bash\necho "nothing useful"\nexit 0\n' > "$MUT/stub3/verify-corrections.sh"; chmod +x "$MUT/stub3/verify-corrections.sh"
  d="$TMP/vcorr-teeth-bare0"; mkgood "$d"
  cp "$SUT" "$MUT/stub3/archive.ORIG.sh"
  mk_sed "teeth(vcorr-ok0)" "$MUT/stub3/archive.OK0MUTANT.sh" "s/elif grep -q '^ \*ok ' <<<\"\$_vc_out\"; then  # AR-VCORR-OK-POSITIVE/elif true; then  # MUTANT/" \
    && tooth "teeth(vcorr-ok0): positive ok match dropped → verdict-less exit 0 reads ok → positive-match guard has teeth" 3 0 "$MUT/stub3/archive.OK0MUTANT.sh" --orig "$MUT/stub3/archive.ORIG.sh" \
         --good-has 'exited 0 without an' --bad-has 'verify-corrections : ok' --bad-lacks 'exited 0 without an' -- run_on_fix @SUT@ "$d" --dry-run

  echo "-- teeth: uf-gate — neuter ONLY the undocumented_findings refuse; uf=1 corpus must then archive --"
  d="$TMP/uf-teeth-gate"; mkgood "$d"
  awk '/^undocumented_findings:/{$0="undocumented_findings: 1"} {print}' "$d/RESEARCH-STATE.md" > "$d/RS.tmp" && mv "$d/RS.tmp" "$d/RESEARCH-STATE.md"
  mk_sed "teeth(uf)" "$MUT/archive.UFMUTANT.sh" 's/gate_rc=1  # uf-gate-refuse/gate_rc=0  # MUTANT-uf-gate/' \
    && tooth "teeth(uf): uf gate neutered → uf=1 corpus archives (exit 0) — uf refuse is load-bearing" 3 0 "$MUT/archive.UFMUTANT.sh" \
         --good-has "$UF_RE" --bad-has "$ARCH_RE" --bad-lacks "$REFUSE_RE" -- run_on_fix @SUT@ "$d"

  echo "-- teeth(uf-split): revert uf-gate scope from \$target to \$corpus; split-layout UF=1 must then archive --"
  # Reverting to "$corpus" reproduces the bug: corpus = first-focus dir, sibling focuses are skipped.
  d="$TMP/split-teeth"; mksplit "$d"
  awk '/^undocumented_findings:/{$0="undocumented_findings: 1"} {print}' \
    "$d/beta/RESEARCH-STATE.md" > "$d/RS.tmp" && mv "$d/RS.tmp" "$d/beta/RESEARCH-STATE.md"
  mk_sed "teeth(uf-split)" "$MUT/archive.SPLITMUTANT.sh" 's/|| list_state_files "\$target"  # AR1-FOCUS-SCOPE/|| list_state_files "\$corpus"  # AR1-FOCUS-SCOPE  # MUTANT-uf-split/' \
    && tooth "teeth(uf-split): scope-reversion mutant → split-layout UF=1 archives (exit 0) — \$target scope is load-bearing" 3 0 "$MUT/archive.SPLITMUTANT.sh" \
         --good-has "$UF_RE" --bad-has "$ARCH_RE" --bad-lacks "$REFUSE_RE" -- run_on_fix @SUT@ "$d"

  echo "-- teeth(root-pref): restoring the lexical 'sort | head -1' pick must make archive act on the focus file (#1818) --"
  mk_sed "teeth(root-pref)" "$MUT/archive.ROOTPREF-MUTANT.sh" 's#^  state="\$(resolve_state_file "\$target")"; _rsf_rc=\$?$#  state="$(find "$target" -maxdepth 3 -name "RESEARCH-STATE*.md" -not -name "*.template.md" -not -path "*/.git/*" 2>/dev/null | sort | head -1)"; _rsf_rc=0  \# MUTANT-root-pref#' \
    && tooth "teeth(root-pref): lexical-pick mutant → reads the focus file (history rows 2) instead of the root (rows 1)" 0 0 "$MUT/archive.ROOTPREF-MUTANT.sh" \
         --good-has 'iteration-history rows: 1$' --bad-has 'iteration-history rows: 2$' -- run_on_fix @SUT@ "$TMP/ar-1818-rootpref" --dry-run

  echo "-- teeth(mf-uf): multi-focus uf gate — UF=1 in one focus must refuse; neutered mutant must archive --"
  d="$TMP/mf-uf-teeth"; mkmulti "$d"
  awk '/^undocumented_findings:/{$0="undocumented_findings: 1"} {print}' \
    "$d/RESEARCH-STATE-alpha.md" > "$d/RS.tmp" && mv "$d/RS.tmp" "$d/RESEARCH-STATE-alpha.md"
  mk_sed "teeth(mf-uf)" "$MUT/archive.MFUF-MUTANT.sh" 's/gate_rc=1  # uf-gate-refuse/gate_rc=0  # MUTANT-uf-gate-mf/' \
    && tooth "teeth(mf-uf): mf uf gate neutered → UF=1 in alpha-focus archives (exit 0) — mf uf refuse is load-bearing" 3 0 "$MUT/archive.MFUF-MUTANT.sh" \
         --good-has "$UF_RE" --bad-has "$ARCH_RE" --bad-lacks "$REFUSE_RE" -- run_on_fix @SUT@ "$d"

  echo "-- teeth(rename-tradeoff): reintroduce --follow to rsdd_added_epoch; renamed retro must trigger MISSING-RETRO gate (exit 3) --"
  # After D6 promotion: the --follow mutant dates the retro from year-2000 (before the 2026-01-10 block)
  # → MISSING-RETRO gate fires → exit 3.
  mk_sed "teeth(rename-tradeoff)" "$MUT/archive.RENAME-MUTANT.sh" 's/log --no-renames --diff-filter=A --format=%ct/log --follow --no-renames --diff-filter=A --format=%ct/' \
    && tooth "teeth(rename-tradeoff): --follow mutant triggers MISSING-RETRO gate (exit 3) → case 36 has teeth" 0 3 "$MUT/archive.RENAME-MUTANT.sh" \
         --good-has "$ARCH_RE" --good-lacks 'MISSING-RETRO' --bad-has 'MISSING-RETRO  : REFUSE' --bad-lacks "$ARCH_RE" -- run_on_fix @SUT@ "$TMP/rename-tradeoff"

  echo "-- teeth(no-renames): drop --no-renames from rsdd_added_epoch; structural case 36b must go RED --"
  if mk_sed "teeth(no-renames)" "$MUT/archive.NORENAMES-MUTANT.sh" 's/log --no-renames --diff-filter=A --format=%ct/log --diff-filter=A --format=%ct/'; then
    read -r _nr_t _nr_o <<<"$(c36b_counts "$MUT/archive.NORENAMES-MUTANT.sh")"
    if [ "$_nr_t" -ge 1 ] && [ "$_nr_t" != "$_nr_o" ]; then
      ok "teeth(no-renames): flag-less call breaks the structural guard → case 36b has teeth ($_nr_o/$_nr_t)"
    else
      no "teeth(no-renames): flag-less call not detected — case 36b is THEATER (total=$_nr_t with-flag=$_nr_o)"
    fi
  fi

  echo "-- teeth(missing-retro-gate): neuter ONLY the missing-retro gate; corpus-advanced case must then archive --"
  d_mrg="$TMP/mr-gate-teeth"; mkgood "$d_mrg"; rm -rf "$d_mrg/retros"   # no retro → missing-retro condition
  mk_sed "teeth(missing-retro-gate)" "$MUT/archive.MRG-MUTANT.sh" 's/gate_rc=1  # missing-retro-gate-refuse/gate_rc=0  # MUTANT-missing-retro-gate/' \
    && tooth "teeth(missing-retro-gate): gate neutered → corpus-advanced archives (exit 0) — missing-retro gate is load-bearing" 3 0 "$MUT/archive.MRG-MUTANT.sh" \
         --good-has 'MISSING-RETRO  : REFUSE' --bad-has "$ARCH_RE" --bad-lacks "$REFUSE_RE" -- run_on_fix @SUT@ "$d_mrg"

  # AR2 teeth: strip AR2-VSTATE-FOCUS-SCOPE so verify-state is called without --focus;
  # --focus alpha must then REFUSE because beta's stale state fails the unscoped verify-state gate.
  echo "-- teeth-ar2: strip verify-state focus scope; --focus alpha must revert to full-corpus verify-state check --"
  # Neuter: replace the array-fill line with a no-op so _vstate_args stays empty.
  # Build the AR2 teeth corpus here (ar2-vstscope is created after the --prove-teeth block).
  _ar2t="$TMP/ar2-teeth"; mkmulti "$_ar2t"
  awk 'index($0,"| Priority | Gap |")==1{print; print "| high | beta-open-gap | web | pending |"; next} {print}' \
    "$_ar2t/RESEARCH-STATE-beta.md" > "$_ar2t/RS.tmp" && mv "$_ar2t/RS.tmp" "$_ar2t/RESEARCH-STATE-beta.md"
  bash "$HERE/../research-sdd-status.sh" "$_ar2t" --sync-state --focus beta >/dev/null 2>&1
  mk_sed "teeth-ar2" "$MUT/archive.AR2-MUTANT.sh" 's/\[ -n "\$focus_slug" \] && _vstate_args=.*# AR2-VSTATE-FOCUS-SCOPE/_vstate_args=()  # AR2-VSTATE-FOCUS-SCOPE [MUTANT]/' \
    && tooth "teeth-ar2: mutant exit 3 on --focus alpha (verify-state not scoped) — AR2 scope is load-bearing" 0 3 "$MUT/archive.AR2-MUTANT.sh" \
         --good-has "$ARCH_RE" --good-lacks "$REFUSE_RE" --bad-has "$REFUSE_RE" --bad-lacks "$ARCH_RE" -- run_on_fix @SUT@ "$_ar2t" --focus alpha --dry-run

  # T-AR1 teeth: neuter AR1-FOCUS-SCOPE; --focus alpha must no longer scope UF gate → beta UF=1 blocks it.
  echo "-- teeth-ar1: neuter AR1-FOCUS-SCOPE; --focus alpha must revert to full-corpus UF scan --"
  mk_sed "teeth-ar1" "$MUT/archive.AR1-MUTANT.sh" 's/\[ -n "\$focus_slug" \] && printf.*# AR1-FOCUS-SCOPE/list_state_files "$target"  # AR1-FOCUS-SCOPE [MUTANT]/' \
    && tooth "teeth-ar1: mutant exit 3 on --focus alpha (beta UF=1 not scoped) — AR1 scope is load-bearing" 0 3 "$MUT/archive.AR1-MUTANT.sh" \
         --good-has "$ARCH_RE" --good-lacks "$UF_RE" --bad-has "$UF_RE" --bad-lacks "$ARCH_RE" -- run_on_fix @SUT@ "$TMP/ar1-focus" --focus alpha --dry-run

  # #970 round-3 teeth 1/3 — non-git fallback branch: neuter the `gate "scan-secrets " ...` call that
  # fires when $target is confirmed NOT a git repo (case 16's fixture, "secret", is a plain non-git
  # mkgood corpus with a leaked AWS key). Must then archive clean, proving the fallback call is load-bearing.
  echo "-- teeth(secrets-nongit): neuter the non-git fallback call; a non-git corpus with a leaked secret must then archive --"
  mk_sed "teeth(secrets-nongit)" "$MUT/archive.NONGIT-MUTANT.sh" 's/^    _ss_wt_only_verdict ""$/    :  # MUTANT-non-git-fallback/' \
    && tooth "teeth(secrets-nongit): non-git fallback neutered → non-git corpus with a leaked secret archives (exit 0) — the fallback call is load-bearing" 3 0 "$MUT/archive.NONGIT-MUTANT.sh" \
         --good-has 'scan-secrets +: FAIL' --bad-has "$ARCH_RE" --bad-lacks 'scan-secrets +: FAIL' -- run_on_fix @SUT@ "$TMP/secret"

  # #970 round-3 teeth 2/3 — neuter (a), the plain `scan-secrets.sh $corpus` filesystem scan. The
  # gitignored-.env fixture (17f-opus2) can ONLY be caught by (a) — (b) `--committed` never saw an
  # uncommitted file — so with (a) neutered, the mutant must archive a corpus that objectively has a leaked secret on disk.
  echo "-- teeth(secrets-plain-scan): neuter (a), the plain scan-secrets.sh \$corpus call; a gitignored secret must then archive --"
  mk_sed "teeth(secrets-plain-scan)" "$MUT/archive.PLAINSCAN-MUTANT.sh" 's/"\$here\/scan-secrets\.sh" --files-from "\$_ss_list" "\$_ss_phys" >\/dev\/null 2>&1; _ss_wt_rc=\$?/_ss_wt_rc=0/' \
    && tooth "teeth(secrets-plain-scan): (a) neutered → gitignored-secret fixture archives (exit 0) — the plain filesystem scan is load-bearing" 3 0 "$MUT/archive.PLAINSCAN-MUTANT.sh" \
         --good-has 'scan-secrets' --bad-has "$ARCH_RE" --bad-lacks "$REFUSE_RE" -- run_on_fix @SUT@ "$TMP/gitignored-env"

  # #970 round-3 teeth 3/3 — the F3 loud-refuse branch (scan-secrets-gate-git-probe-error). 17g's stub
  # (a git that always exits 127) is the UNCONDITIONAL, host-independent primary tooth; the dubious-ownership
  # run is bonus coverage behind the same probe-and-skip guard as case 17h (CI run 35969674928: the env var
  # alone is not a reliable CI fixture).
  echo "-- teeth(secrets-f3-refuse): neuter the F3 ambiguous-git-failure refuse; the stubbed-git fixture must then archive --"
  if mk_sed "teeth(secrets-f3-refuse)" "$MUT/archive.F3-MUTANT.sh" 's/gate_rc=1  # scan-secrets-gate-git-probe-error/gate_rc=0  # MUTANT-git-probe-error/'; then
    tooth "teeth(secrets-f3-refuse): F3 refuse neutered → stubbed-git corpus archives (exit 0) — the gate_rc assignment is load-bearing (unconditional, host-independent)" 3 0 "$MUT/archive.F3-MUTANT.sh" \
      --good-has "$REFUSE_RE" --bad-has "$ARCH_RE" --bad-lacks "$REFUSE_RE" -- run_on_fix PATH="$TMP/stubbin:$PATH" @SUT@ "$TMP/gitstub"
    if _dubious_ownership_reproduces "$TMP/dubious"; then
      tooth "teeth(secrets-f3-refuse) bonus: same mutant on dubious-ownership fixture also archives (exit 0) — confirms the sentinel is shared" 3 0 "$MUT/archive.F3-MUTANT.sh" \
        --good-has "$REFUSE_RE" --bad-has "$ARCH_RE" --bad-lacks "$REFUSE_RE" -- run_on_fix GIT_TEST_ASSUME_DIFFERENT_OWNER=1 @SUT@ "$TMP/dubious"
    else
      skip "teeth(secrets-f3-refuse) bonus: GIT_TEST_ASSUME_DIFFERENT_OWNER=1 does not reproduce on this host — unconditional tooth above already covers this sentinel"
    fi
  fi

  # #970 round-3 teeth (b): revert `--committed $target` to a plain `$corpus` scan; the history-only secret
  # (case 17b's fixture — committed once, then removed, nothing left on disk) must then archive clean.
  echo "-- teeth(secrets-committed): revert --committed \$target to a plain \$corpus scan; history-only secret must then archive --"
  mk_sed "teeth(secrets-committed)" "$MUT/archive.COMMITTED-MUTANT.sh" 's/scan-secrets\.sh" --committed "\$target"/scan-secrets.sh" "$corpus"/' \
    && tooth "teeth(secrets-committed): --committed reverted to a plain \$corpus scan → history-only secret archives (exit 0) — --committed \$target is load-bearing" 3 0 "$MUT/archive.COMMITTED-MUTANT.sh" \
         --good-has "$REFUSE_RE" --bad-has "$ARCH_RE" --bad-lacks "$REFUSE_RE" -- run_on_fix @SUT@ "$TMP/committed-deleted-secret"

  # ---- T15a teeth (#1015 #1014): every new branch of the secrets gate has a mutant that flips its fixture ----
  echo "-- teeth(T15a): packaging-list scope, physical nested compare, unborn branch, fail-closed list, WARN/hint output --"
  mk_sed "teeth(narrow)" "$MUT/archive.NARROW-MUTANT.sh" 's/find "\$_ss_phys" /find "$_ss_phys\/blocks" /' \
    && tooth "teeth(narrow): packaging list narrowed to blocks/ → notes.md secret archives (exit 0) — scanning the WHOLE target is load-bearing (#1015)" 3 0 "$MUT/archive.NARROW-MUTANT.sh" \
         --good-has 'scan-secrets +: FAIL' --bad-has "$ARCH_RE" --bad-lacks 'scan-secrets +: FAIL' -- run_on_fix @SUT@ "$TMP/narrow-notes"
  mk_sed "teeth(nested-logical)" "$MUT/archive.NESTLOGICAL-MUTANT.sh" 's/\[ "\$(cd -P "\$_ss_top_out" 2>\/dev\/null \&\& pwd -P)" != "\$_ss_phys" \]/[ "$_ss_top_out" != "$target" ]/' \
    && tooth "teeth(nested-logical): logical compare → symlinked parent reads as nested, history-only secret archives (exit 0) — physical compare is load-bearing (#1014.1)" 3 0 "$MUT/archive.NESTLOGICAL-MUTANT.sh" \
         --good-has 'scan-secrets +: FAIL' --bad-has 'history not scanned' --bad-lacks 'scan-secrets +: FAIL' -- bash @SUT@ "$TMP/symparent-link/hs" --dry-run
  mk_sed "teeth(nested-warn)" "$MUT/archive.NESTWARN-MUTANT.sh" 's/^    echo "WARN: history not scanned — target is inside.*# SS-NESTED-WARN$/    :/' \
    && tooth "teeth(nested-warn): nested WARN deleted → nested target archives silently — the WARN is load-bearing (#1014.3)" 0 0 "$MUT/archive.NESTWARN-MUTANT.sh" \
         --good-has 'WARN: history not scanned — target is inside enclosing repo' --bad-lacks 'history not scanned' -- bash @SUT@ "$d_nested" --dry-run
  mk_sed "teeth(unborn-branch)" "$MUT/archive.UNBORN-MUTANT.sh" 's/\[ -z "\$_ss_refs" \]; then/[ -z "x$_ss_refs" ]; then/' \
    && tooth "teeth(unborn-branch): unborn branch disabled → no-commit repo refuses again (exit 3) — the branch is load-bearing (#1014.2)" 0 3 "$MUT/archive.UNBORN-MUTANT.sh" \
         --good-has 'no commits yet' --bad-has "$REFUSE_RE" -- bash @SUT@ "$TMP/unborn" --dry-run
  mk_sed "teeth(unborn-warn)" "$MUT/archive.UNBORNWARN-MUTANT.sh" 's/^    echo "WARN: history not scanned — repository has no commits yet".*$/    :/' \
    && tooth "teeth(unborn-warn): WARN deleted → the unborn downgrade is silent on stderr — the WARN is load-bearing (#1014.3)" 0 0 "$MUT/archive.UNBORNWARN-MUTANT.sh" \
         --good-has 'WARN: history not scanned — repository has no commits yet' --bad-lacks 'WARN: history not scanned' -- bash @SUT@ "$TMP/unborn" --dry-run
  mk_sed "teeth(list-fail)" "$MUT/archive.LISTFAIL-MUTANT.sh" 's/_ss_wt_rc=90; /_ss_wt_rc=0; /' \
    && tooth "teeth(list-fail): not-computable list treated as clean → archives (exit 0) — the fail-closed refusal is load-bearing" 3 0 "$MUT/archive.LISTFAIL-MUTANT.sh" \
         --good-has 'packaging list could not be computed' --bad-has "$ARCH_RE" --bad-lacks "$REFUSE_RE" -- run_on_fix PATH="$TMP/findstub-fail:$PATH" @SUT@ "$TMP/listfail"
  mk_sed "teeth(list-empty)" "$MUT/archive.LISTEMPTY-MUTANT.sh" 's/_ss_wt_rc=91; /_ss_wt_rc=0; /' \
    && tooth "teeth(list-empty): EMPTY list treated as clean → archives (exit 0) — the empty-input refusal is load-bearing" 3 0 "$MUT/archive.LISTEMPTY-MUTANT.sh" \
         --good-has 'packaging list is EMPTY' --bad-has "$ARCH_RE" --bad-lacks "$REFUSE_RE" -- run_on_fix PATH="$TMP/findstub-empty:$PATH" @SUT@ "$TMP/listfail"
  mk_sed "teeth(list-other-error)" "$MUT/archive.LISTOTHER-MUTANT.sh" 's/if grep -qv .Permission denied. "\$_ss_ferr"; then return 1; fi/:/' \
    && tooth "teeth(list-other-error): any find error tolerated → a non-permission error with a partial list archives (exit 0) — the tolerance is narrow on purpose" 3 0 "$MUT/archive.LISTOTHER-MUTANT.sh" \
         --good-has 'packaging list could not be computed' --bad-has "$ARCH_RE" --bad-lacks "$REFUSE_RE" -- run_on_fix PATH="$TMP/findstub-other:$PATH" @SUT@ "$TMP/listfail"
  mk_sed "teeth(unreadable-note)" "$MUT/archive.UNREADNOTE-MUTANT.sh" "s/printf ', %s unreadable path(s) not scanned' \"\\\$_ss_unreadable\"/:/" \
    && tooth "teeth(unreadable-note): verdict-line disclosure removed → a partial scan reads as a bare ok" 0 0 "$MUT/archive.UNREADNOTE-MUTANT.sh" \
         --good-has 'ok, 1 unreadable path\(s\) not scanned' --bad-lacks 'unreadable path\(s\) not scanned' -- run_on_fix PATH="$TMP/findstub-perm:$PATH" @SUT@ "$TMP/listfail"
  mk_sed "teeth(unreadable-warn)" "$MUT/archive.UNREADWARN-MUTANT.sh" 's/^    echo "WARN: scan-secrets packaging list skipped.*$/    :/' \
    && tooth "teeth(unreadable-warn): stderr WARN removed → the skipped paths are not announced" 0 0 "$MUT/archive.UNREADWARN-MUTANT.sh" \
         --good-has 'WARN: scan-secrets packaging list skipped' --bad-lacks 'WARN: scan-secrets packaging list skipped' -- run_on_fix PATH="$TMP/findstub-perm:$PATH" @SUT@ "$TMP/listfail"
  mk_sed "teeth(hint)" "$MUT/archive.HINT-MUTANT.sh" 's/^      echo "    \$_hint_wt   # working tree (dirty.*$/      :/' \
    && tooth "teeth(hint): packaging-list hint line removed from the refusal block (#1014.3)" 3 3 "$MUT/archive.HINT-MUTANT.sh" \
         --good-has 'scan-secrets.sh --files-from -' --bad-lacks 'scan-secrets.sh --files-from -' -- run_on_fix @SUT@ "$TMP/hintfix"
  mk_sed "teeth(hist-remedy)" "$MUT/archive.HISTREMEDY-MUTANT.sh" 's/if \[ "\$_ss_leak_hist" = 1 \]; then  # SS-HIST-HINT/if false; then/' \
    && tooth "teeth(hist-remedy): history-rewrite line removed → a history-only leak gets no actionable remedy" 3 3 "$MUT/archive.HISTREMEDY-MUTANT.sh" \
         --good-has 'history must be rewritten' --bad-lacks 'history must be rewritten' -- run_on_fix @SUT@ "$TMP/committed-deleted-secret"
  mk_sed "teeth(wt-remedy-hist)" "$MUT/archive.WTREMEDYHIST-MUTANT.sh" 's/if \[ "\$_ss_leak_wt" = 1 \]; then  # SS-REMEDY-HINT/if [ "$_ss_leak_wt$_ss_leak_hist" != 00 ]; then/' \
    && tooth "teeth(wt-remedy-hist): move-outside line printed for a history-only leak (the old any-leak behaviour)" 3 3 "$MUT/archive.WTREMEDYHIST-MUTANT.sh" \
         --good-lacks 'OUTSIDE the target directory' --bad-has 'OUTSIDE the target directory' -- run_on_fix @SUT@ "$TMP/committed-deleted-secret"
  mk_sed "teeth(unresolvable-hint)" "$MUT/archive.UNRESOLV-MUTANT.sh" 's/if \[ -z "\$_ss_phys" \]; then  # SS-UNRESOLVABLE-HINT/if false; then/' \
    && tooth "teeth(unresolvable-hint): typed hint removed → an empty-path find command is printed" 3 3 "$MUT/archive.UNRESOLV-MUTANT.sh" \
         --good-has 'target unresolvable' --bad-lacks 'target unresolvable' -- env BASH_ENV="$TMP/cdfail.env" bash @SUT@ "$TMP/unresolvable"
  mk_sed "teeth(find-silent)" "$MUT/archive.FINDSILENT-MUTANT.sh" 's/^    \[ -s "\$_ss_ferr" \] || return 1$/    :/' \
    && tooth "teeth(find-silent): empty-stderr find failure tolerated → an unproven (possibly partial) list archives (exit 0) — the non-empty-stderr proof is load-bearing" 3 0 "$MUT/archive.FINDSILENT-MUTANT.sh" \
         --good-has 'packaging list could not be computed' --bad-has "$ARCH_RE" --bad-lacks "$REFUSE_RE" -- run_on_fix PATH="$TMP/findstub-silent:$PATH" @SUT@ "$TMP/listsilent"
  mk_sed "teeth(remedy-hint)" "$MUT/archive.REMEDY-MUTANT.sh" 's/if \[ "\$_ss_leak_wt" = 1 \]; then  # SS-REMEDY-HINT/if false; then/' \
    && tooth "teeth(remedy-hint): remedy lines removed → the refusal no longer says where the secret store must go" 3 3 "$MUT/archive.REMEDY-MUTANT.sh" \
         --good-has 'OUTSIDE the target directory' --bad-lacks 'OUTSIDE the target directory' -- run_on_fix @SUT@ "$TMP/hintfix"
  mk_sed "teeth(hint-quote)" "$MUT/archive.HINTQUOTE-MUTANT.sh" "s/_q_phys=\"\\\$(printf '%q' \"\\\$_ss_phys\")\"/_q_phys=\"\$_ss_phys\"/" "s/_q_target=\"\\\$(printf '%q' \"\\\$target\")\"/_q_target=\"\$target\"/" \
    && tooth "teeth(hint-quote): %q dropped → a target path with a space prints as a broken command" 3 3 "$MUT/archive.HINTQUOTE-MUTANT.sh" \
         --good-has 'hint\\ space' --bad-lacks 'hint\\ space' -- bash @SUT@ "$TMP/hint space"
  if [ "$(id -u)" != 0 ]; then
    mk_sed "teeth(degraded-note)" "$MUT/archive.DEGNOTE-MUTANT.sh" "s/if \[ \"\\\$1\" = 3 \]; then printf ' — DEGRADED/if false; then printf ' — DEGRADED/" \
      && { chmod 000 "$TMP/unreadable-file/notes.md"
           tooth "teeth(degraded-note): DEGRADED typing removed → an unreadable in-scope file reads as a bare generic error" 3 3 "$MUT/archive.DEGNOTE-MUTANT.sh" \
             --good-has 'DEGRADED: an unreadable in-scope file' --bad-lacks 'DEGRADED: an unreadable in-scope file' -- bash @SUT@ "$TMP/unreadable-file"
           chmod 644 "$TMP/unreadable-file/notes.md"; }
  fi
fi

# ==================== AR2 — --focus scopes the verify-state gate (#647) ====================
# Scenario: multi-focus corpus where beta has a STALE summary (Coverage metric claims all closed
# while the backlog still has a pending gap) → verify-state FAILs for beta.
# Without --focus: archive REFUSES (exit 3) — because verify-state fails on beta.
# With --focus alpha: archive passes (exit 0) — verify-state scoped to alpha only.
# This is the fix for issue #647: archive --dry-run was failing on verify-state FAIL caused by
# unrelated focuses' stale state, blocking a clean focus from archiving.

d="$TMP/ar2-vstscope"; mkmulti "$d"
# Make beta stale: add a pending gap to beta's backlog so the Coverage metric ("1 / 1 closed")
# no longer matches — verify-state CHECK 1 fires for beta.
awk 'index($0,"| Priority | Gap |")==1{print; print "| high | beta-open-gap | web | pending |"; next} {print}' \
  "$d/RESEARCH-STATE-beta.md" > "$d/RS.tmp" && mv "$d/RS.tmp" "$d/RESEARCH-STATE-beta.md"
# Re-sync beta's envelope so investigable_open=1 (correct), but the Coverage metric prose
# still says "1 / 1 closed" — this is the stale desync that verify-state CHECK 1 catches.
bash "$HERE/../research-sdd-status.sh" "$d" --sync-state --focus beta >/dev/null 2>&1

# Confirm beta's state now FAILS verify-state (required pre-condition for AR2 to be meaningful).
bash "$HERE/../verify-state.sh" "$d" --focus beta >/dev/null 2>&1; _ar2_vsbeta=$?
[ "$_ar2_vsbeta" -ne 0 ] \
  && ok "AR2 precondition: beta verify-state fails (exit $_ar2_vsbeta) — stale summary confirmed" \
  || no "AR2 precondition: beta verify-state passed (want non-zero) — test fixture may be wrong"

# Without --focus: archive must REFUSE because verify-state fails on the full corpus.
out_ar2_all="$(bash "$SUT" "$d" --dry-run 2>&1)"; rc_ar2_all=$?
[ "$rc_ar2_all" = 3 ] \
  && ok "AR2 baseline: no --focus → REFUSED (exit 3) when sibling focus has stale state" \
  || no "AR2 baseline: no --focus: exit=$rc_ar2_all (want 3) :: $(grep -iE 'verify-state|fail|refuse' <<<"$out_ar2_all" | head -2)"

# With --focus alpha: archive must PASS because alpha's state is clean.
out_ar2_foc="$(bash "$SUT" "$d" --focus alpha --dry-run 2>&1)"; rc_ar2_foc=$?
[ "$rc_ar2_foc" = 0 ] \
  && ok "AR2: --focus alpha → archive passes despite stale beta state (verify-state scoped to focus)" \
  || no "AR2: --focus alpha: exit=$rc_ar2_foc (want 0) — verify-state gate not scoped to focus :: $(grep -iE 'verify-state|fail|refuse' <<<"$out_ar2_foc" | head -2)"

# AR2 teeth — inside the --prove-teeth block (appended there separately below).

# AR-VCORR — verify-corrections is a GATE (issue #1790 step 4; promoted from the #1787 advisory WARN).
# A real FAIL (exit 1 with FAIL lines) REFUSES (exit 3) unless --allow-unreciprocated-corrections is given;
# could-not-run states (DEGRADED / ERROR) refuse with a typed reason; ok-partial passes as PARTIAL.
d="$TMP/vcorr-bad"; mkvcorr "$d"
out_vc="$(bash "$SUT" "$d" --dry-run 2>&1)"; rc_vc=$?
if [ "$rc_vc" = 3 ] && grep -q 'verify-corrections : FAIL — 1 one-directional' <<<"$out_vc" \
   && grep -q 'FAIL   B2 corrects \[Block 1\]' <<<"$out_vc" && grep -q 'REFUSED: reconcile' <<<"$out_vc" \
   && ! grep -q 'verify-corrections : ok' <<<"$out_vc"; then
  ok "AR-VCORR: one-directional correction → FAIL with count + failing pair, REFUSED exit 3"
else no "AR-VCORR bad: rc=$rc_vc :: $(grep -i 'verify-corrections\|REFUSED' <<<"$out_vc" | head -3)"; fi

# override: same corpus + the documented flag → typed OVERRIDDEN line, archive proceeds (exit 0).
out_vc="$(bash "$SUT" "$d" --dry-run --allow-unreciprocated-corrections 2>&1)"; rc_vc=$?
if [ "$rc_vc" = 0 ] && grep -q 'verify-corrections : OVERRIDDEN — 1 one-directional' <<<"$out_vc" \
   && ! grep -q 'REFUSED: reconcile' <<<"$out_vc"; then
  ok "AR-VCORR: --allow-unreciprocated-corrections → typed OVERRIDDEN line, exit 0"
else no "AR-VCORR override: rc=$rc_vc :: $(grep -i 'verify-corrections\|REFUSED' <<<"$out_vc" | head -3)"; fi

d="$TMP/vcorr-ok"; mkvcorr "$d"; printf 'Corrected in B2.\n' >> "$d/t-block1.md"
out_vc="$(bash "$SUT" "$d" --dry-run 2>&1)"; rc_vc=$?
if [ "$rc_vc" = 0 ] && grep -q 'verify-corrections : ok' <<<"$out_vc" && ! grep -q 'one-directional' <<<"$out_vc"; then
  ok "AR-VCORR: reciprocated correction → verify-corrections ok, no refusal"
else no "AR-VCORR ok: rc=$rc_vc :: $(grep -i 'verify-corrections' <<<"$out_vc" | head -2)"; fi

d="$TMP/vcorr-clean"; mkgood "$d"
out_vc="$(bash "$SUT" "$d" --dry-run 2>&1)"
if grep -q 'verify-corrections : ok' <<<"$out_vc"; then ok "AR-VCORR: corpus with no corrections → ok"
else no "AR-VCORR clean :: $(grep -i 'verify-corrections' <<<"$out_vc" | head -2)"; fi

# ok-partial (a declared correction whose target block does not exist) is NOT a silent ok: typed PARTIAL, archive proceeds.
d="$TMP/vcorr-partial"; mkgood "$d"
printf '# Block 2 — correction\nCorrects [Block 9] §1.1 — the earlier claim was wrong.\n' > "$d/t-block2.md"
bash "$HERE/../research-sdd-status.sh" "$d" --sync-state >/dev/null 2>&1
out_vc="$(bash "$SUT" "$d" --dry-run 2>&1)"; rc_vc=$?
if [ "$rc_vc" = 0 ] && grep -q 'verify-corrections : PARTIAL — 1 declared correction(s) NOT checked' <<<"$out_vc" \
   && ! grep -q 'verify-corrections : ok' <<<"$out_vc"; then
  ok "AR-VCORR: ok-partial → typed PARTIAL (never a bare ok), exit 0"
else no "AR-VCORR partial: rc=$rc_vc :: $(grep -i 'verify-corrections' <<<"$out_vc" | head -2)"; fi

# exit 2 (no block files) must read as n/a, never a spurious ERROR (§7 three states).
d="$TMP/vcorr-noblocks"; mkgood "$d"; rm -f "$d/t-block1.md"
out_vc="$(bash "$SUT" "$d" --dry-run 2>&1)"
if grep -q 'verify-corrections : n/a' <<<"$out_vc" && ! grep -q 'verify-corrections : \(ERROR\|WARN\|FAIL\)' <<<"$out_vc"; then
  ok "AR-VCORR: no block files (linter exit 2) → n/a, not an ERROR"
else no "AR-VCORR no-blocks :: $(grep -i 'verify-corrections' <<<"$out_vc" | head -2)"; fi

# could-not-run: bad args (exit 2 WITHOUT the no-block-files reason) and any other exit code are typed ERROR + REFUSED
# (never n/a, never a silent pass); the override flag turns the refusal into a typed OVERRIDDEN line.
AR_STUB="$TMP/vcorr-stub"; mkdir -p "$AR_STUB/lib"
cp "$SUT" "$HERE/../verify-state.sh" "$HERE/../verify-sources.sh" "$HERE/../scan-secrets.sh" "$AR_STUB/"
cp "$HERE/../lib/"*.sh "$AR_STUB/lib/"
for _stub_rc in 7 2; do
  printf '#!/usr/bin/env bash\necho "usage: verify-corrections.sh <target-dir>" >&2\nexit %s\n' "$_stub_rc" > "$AR_STUB/verify-corrections.sh"
  chmod +x "$AR_STUB/verify-corrections.sh"
  d="$TMP/vcorr-stubcorpus-$_stub_rc"; mkgood "$d"
  out_vc="$(bash "$AR_STUB/research-sdd-archive.sh" "$d" --dry-run 2>&1)"; rc_vc=$?
  if grep -q 'verify-corrections : ERROR — verify-corrections.sh did not run' <<<"$out_vc" \
     && ! grep -q 'verify-corrections : n/a' <<<"$out_vc" && [ "$rc_vc" = 3 ]; then
    ok "AR-VCORR: linter exit $_stub_rc (not no-blocks) → ERROR did-not-run, REFUSED, never n/a"
  else no "AR-VCORR stub exit $_stub_rc: rc=$rc_vc :: $(grep -i 'verify-corrections' <<<"$out_vc" | head -2)"; fi
  out_vc="$(bash "$AR_STUB/research-sdd-archive.sh" "$d" --dry-run --allow-unreciprocated-corrections 2>&1)"; rc_vc=$?
  if grep -q 'verify-corrections : OVERRIDDEN — verify-corrections.sh did not run' <<<"$out_vc" && [ "$rc_vc" = 0 ]; then
    ok "AR-VCORR: linter exit $_stub_rc + override flag → typed OVERRIDDEN did-not-run, exit 0"
  else no "AR-VCORR stub override $_stub_rc: rc=$rc_vc :: $(grep -i 'verify-corrections' <<<"$out_vc" | head -2)"; fi
done
# exit 1 with an UNEXPECTED prefix and no `degraded:` (contract drift / lib failed): ERROR, never a findings claim.
printf '#!/usr/bin/env bash\necho "ISSUE B2 corrects B1" >&2\nexit 1\n' > "$AR_STUB/verify-corrections.sh"
chmod +x "$AR_STUB/verify-corrections.sh"
d="$TMP/vcorr-drift"; mkgood "$d"
out_vc="$(bash "$AR_STUB/research-sdd-archive.sh" "$d" --dry-run 2>&1)"; rc_vc=$?
if grep -q 'verify-corrections : ERROR — verify-corrections exited 1 with no findings (could not run?)' <<<"$out_vc" \
   && ! grep -q 'one-directional' <<<"$out_vc" && ! grep -q 'verify-corrections : FAIL' <<<"$out_vc" && [ "$rc_vc" = 3 ]; then
  ok "AR-VCORR: linter exit 1 with no findings and no degraded: → ERROR (no findings claimed), REFUSED"
else no "AR-VCORR drift: rc=$rc_vc :: $(grep -i 'verify-corrections' <<<"$out_vc" | head -2)"; fi
# exit 1 with the linter's own `degraded:` marker (instrument could not look): DEGRADED + REFUSED, not a FAIL count.
printf '#!/usr/bin/env bash\necho "verify-corrections: degraded: awk not found on PATH; the corpus was NOT checked" >&2\nexit 1\n' > "$AR_STUB/verify-corrections.sh"
chmod +x "$AR_STUB/verify-corrections.sh"
d="$TMP/vcorr-degraded"; mkgood "$d"
out_vc="$(bash "$AR_STUB/research-sdd-archive.sh" "$d" --dry-run 2>&1)"; rc_vc=$?
if grep -q 'verify-corrections : DEGRADED — ' <<<"$out_vc" && ! grep -q 'one-directional' <<<"$out_vc" && [ "$rc_vc" = 3 ]; then
  ok "AR-VCORR: linter degraded: marker → DEGRADED (typed, not a finding count), REFUSED"
else no "AR-VCORR degraded: rc=$rc_vc :: $(grep -i 'verify-corrections' <<<"$out_vc" | head -2)"; fi
out_vc="$(bash "$AR_STUB/research-sdd-archive.sh" "$d" --dry-run --allow-unreciprocated-corrections 2>&1)"; rc_vc=$?
if grep -q 'verify-corrections : OVERRIDDEN — .*degraded' <<<"$out_vc" && [ "$rc_vc" = 0 ]; then
  ok "AR-VCORR: degraded + override flag → typed OVERRIDDEN, exit 0"
else no "AR-VCORR degraded override: rc=$rc_vc :: $(grep -i 'verify-corrections' <<<"$out_vc" | head -2)"; fi
rm -f "$AR_STUB/verify-corrections.sh"
d="$TMP/vcorr-missing"; mkgood "$d"
out_vc="$(bash "$AR_STUB/research-sdd-archive.sh" "$d" --dry-run 2>&1)"; rc_vc=$?
if grep -q 'verify-corrections : ERROR — verify-corrections.sh did not run (exit 127)' <<<"$out_vc" && [ "$rc_vc" = 3 ]; then
  ok "AR-VCORR: linter script missing → ERROR did-not-run (exit 127), REFUSED"
else no "AR-VCORR missing :: $(grep -i 'verify-corrections' <<<"$out_vc" | head -2)"; fi

# item 3 — a bare exit 0 must POSITIVELY match the linter's `ok` line; exit 0 with neither ok nor ok-partial is ERROR.
printf '#!/usr/bin/env bash\necho "nothing useful"\nexit 0\n' > "$AR_STUB/verify-corrections.sh"; chmod +x "$AR_STUB/verify-corrections.sh"
d="$TMP/vcorr-bare0"; mkgood "$d"
out_vc="$(bash "$AR_STUB/research-sdd-archive.sh" "$d" --dry-run 2>&1)"; rc_vc=$?
if grep -q "verify-corrections : ERROR — verify-corrections.sh exited 0 without an 'ok' verdict line" <<<"$out_vc" \
   && ! grep -q 'verify-corrections : ok' <<<"$out_vc" && [ "$rc_vc" = 3 ]; then
  ok "AR-VCORR: bare exit 0 without an ok verdict line → ERROR, REFUSED (never a silent ok)"
else no "AR-VCORR bare0: rc=$rc_vc :: $(grep -i 'verify-corrections' <<<"$out_vc" | head -2)"; fi
rm -f "$AR_STUB/verify-corrections.sh"

# item 4 — the override flag must not mask ANOTHER gate: a stale mirror (verify-state FAIL) + a one-directional
# correction + the flag still REFUSES (exit 3), with verify-state's FAIL and the typed OVERRIDDEN line both visible.
d="$TMP/vcorr-ovr-other"; mkvcorr "$d"; sed -i 's#2 / 3 closed#3 / 3 closed#' "$d/RESEARCH-STATE.md"
out_vc="$(bash "$SUT" "$d" --dry-run --allow-unreciprocated-corrections 2>&1)"; rc_vc=$?
if [ "$rc_vc" = 3 ] && grep -q 'verify-corrections : OVERRIDDEN' <<<"$out_vc" && grep -q 'verify-state   : FAIL' <<<"$out_vc" \
   && grep -q 'REFUSED: reconcile' <<<"$out_vc"; then
  ok "AR-VCORR: override flag does not mask a failing verify-state (still exit 3)"
else no "AR-VCORR override-other: rc=$rc_vc :: $(grep -iE 'verify-state|verify-corrections|REFUSED' <<<"$out_vc" | head -4)"; fi

# item 1 — --focus scoping (same rule as verify-state, #647).
d="$TMP/vcorr-focus-sib"; mkvfocus "$d" beta
out_vc="$(bash "$SUT" "$d" --dry-run --focus alpha 2>&1)"; rc_vc=$?
if [ "$rc_vc" = 0 ] && grep -q 'verify-corrections : SIBLING — 1 pair(s) outside focus alpha not enforced' <<<"$out_vc" \
   && ! grep -q 'verify-corrections : FAIL' <<<"$out_vc" && ! grep -q 'REFUSED: reconcile' <<<"$out_vc"; then
  ok "AR-VCORR focus: clean focus alpha + failing sibling beta → SIBLING (typed, not enforced), exit 0"
else no "AR-VCORR focus-sibling: rc=$rc_vc :: $(grep -iE 'verify-corrections|REFUSED' <<<"$out_vc" | head -3)"; fi
out_vc="$(bash "$SUT" "$d" --dry-run 2>&1)"; rc_vc=$?
if [ "$rc_vc" = 3 ] && grep -q 'verify-corrections : FAIL — 1 one-directional' <<<"$out_vc"; then
  ok "AR-VCORR focus: the same corpus WITHOUT --focus still refuses (whole-corpus gate unchanged)"
else no "AR-VCORR focus-nofocus: rc=$rc_vc :: $(grep -iE 'verify-corrections|REFUSED' <<<"$out_vc" | head -3)"; fi
out_vc="$(bash "$SUT" "$d" --dry-run --focus beta 2>&1)"; rc_vc=$?
if [ "$rc_vc" = 3 ] && grep -q 'verify-corrections : FAIL — 1 one-directional' <<<"$out_vc" \
   && grep -q 'FAIL   B2 corrects \[Block 1\] but beta-block1.md' <<<"$out_vc" && ! grep -q 'SIBLING' <<<"$out_vc"; then
  ok "AR-VCORR focus: failing focus beta refuses (exit 3) naming its own pair"
else no "AR-VCORR focus-failing: rc=$rc_vc :: $(grep -iE 'verify-corrections|REFUSED' <<<"$out_vc" | head -3)"; fi
d="$TMP/vcorr-focus-unres"; mkvfocus "$d" alpha; rm -f "$d/beta-block1.md"
out_vc="$(bash "$SUT" "$d" --dry-run --focus beta 2>&1)"; rc_vc=$?
if [ "$rc_vc" = 3 ] && grep -q 'verify-corrections : ERROR — cannot scope the §14 gate to focus beta' <<<"$out_vc" \
   && ! grep -q 'verify-corrections : \(SIBLING\|ok\)' <<<"$out_vc"; then
  ok "AR-VCORR focus: focus prefix unresolvable (no block carries it) + findings → typed ERROR, REFUSED (never a silent pass)"
else no "AR-VCORR focus-unres: rc=$rc_vc :: $(grep -iE 'verify-corrections|REFUSED' <<<"$out_vc" | head -3)"; fi

# #1857 — focus ownership is decided by the CORRECTING block's file prefix (the linter now ends every FAIL line with
# `[correcting: <file>]`), not by "the focus owns some block with the same number", and the prefix test reads the BASENAME.
# (a) beta's block 2 corrects beta's block 1; alpha ALSO owns a block 2 (old rule: "owns number 2" → in-focus → refused).
d="$TMP/vcorr-focus-num"; mkvfocus "$d" beta
printf '# Alpha Block 2\nBody.\n' > "$d/alpha-block2.md"; bash "$HERE/../research-sdd-status.sh" "$d" --sync-state --focus alpha >/dev/null 2>&1
out_vc="$(bash "$SUT" "$d" --dry-run --focus alpha 2>&1)"; rc_vc=$?
if [ "$rc_vc" = 0 ] && grep -q 'verify-corrections : SIBLING — 1 pair(s) outside focus alpha not enforced' <<<"$out_vc" && ! grep -q 'verify-corrections : FAIL' <<<"$out_vc"; then
  ok "AR-VCORR focus #1857: beta's B2→beta-B1 is a SIBLING pair even though alpha also owns a block numbered 2"
else no "AR-VCORR focus-number: rc=$rc_vc :: $(grep -iE 'verify-corrections|REFUSED' <<<"$out_vc" | head -3)"; fi
# (b) the correcting block belongs to the focus and corrects a block of the sibling focus: in-focus by the correcting prefix.
d="$TMP/vcorr-focus-xcorr"; mkmulti "$d"
printf '# Alpha Block 7\nCorrects `beta` [Block 1] §1.1 — the earlier claim was wrong.\n' > "$d/alpha-block7.md"
bash "$HERE/../research-sdd-status.sh" "$d" --sync-state --focus alpha >/dev/null 2>&1
out_vc="$(bash "$SUT" "$d" --dry-run --focus alpha 2>&1)"; rc_vc=$?
if [ "$rc_vc" = 3 ] && grep -q 'FAIL   B7 corrects \[Block 1\] but beta-block1.md' <<<"$out_vc" && ! grep -q 'SIBLING' <<<"$out_vc"; then
  ok "AR-VCORR focus #1857: alpha's own block correcting beta's block is IN focus alpha (refused)"
else no "AR-VCORR focus-xcorr: rc=$rc_vc :: $(grep -iE 'verify-corrections|REFUSED' <<<"$out_vc" | head -3)"; fi
# (c) a corpus whose DIRECTORY name carries a focus prefix: the pair is classified from the file BASENAMES only.
d="$TMP/alpha-block9-dir/corpus"; mkdir -p "$TMP/alpha-block9-dir"; mkvfocus "$d" beta
out_vc="$(bash "$SUT" "$d" --dry-run --focus alpha 2>&1)"; rc_vc=$?
if [ "$rc_vc" = 0 ] && grep -q 'verify-corrections : SIBLING — 1 pair(s)' <<<"$out_vc"; then
  ok "AR-VCORR focus #1857: a directory named like a focus prefix does not turn a sibling pair in-focus"
else no "AR-VCORR focus-dirname: rc=$rc_vc :: $(grep -iE 'verify-corrections|REFUSED' <<<"$out_vc" | head -3)"; fi
# (d) a linter that does not name the correcting file (older output) is never silently dropped: in-focus (conservative).
printf '#!/usr/bin/env bash\necho "   FAIL   B2 corrects [Block 1] but beta-block1.md has no reciprocal backlink to B2 (§14)"\nexit 1\n' > "$AR_STUB/verify-corrections.sh"
chmod +x "$AR_STUB/verify-corrections.sh"
d="$TMP/vcorr-focus-nocf"; mkvfocus "$d" beta
out_vc="$(bash "$AR_STUB/research-sdd-archive.sh" "$d" --dry-run --focus alpha 2>&1)"; rc_vc=$?
if [ "$rc_vc" = 3 ] && grep -q 'verify-corrections : FAIL — 1 one-directional' <<<"$out_vc" && ! grep -q 'SIBLING' <<<"$out_vc"; then
  ok "AR-VCORR focus #1857: a FAIL line without [correcting: …] is treated as in-focus (refused), never dropped"
else no "AR-VCORR focus-nocf: rc=$rc_vc :: $(grep -iE 'verify-corrections|REFUSED' <<<"$out_vc" | head -3)"; fi
rm -f "$AR_STUB/verify-corrections.sh"
# (e) #1868: typed AMBIG lines (here a bare `B1`) never refuse; the PARTIAL line counts them.
d="$TMP/vcorr-ambig"; mkgood "$d"
printf '# Block 2 — correction\nCorrects B1 §1.1 — the earlier claim was wrong.\n' > "$d/t-block2.md"
bash "$HERE/../research-sdd-status.sh" "$d" --sync-state >/dev/null 2>&1
out_vc="$(bash "$SUT" "$d" --dry-run 2>&1)"; rc_vc=$?
if [ "$rc_vc" = 0 ] && grep -q 'verify-corrections : PARTIAL — 1 declared correction(s) NOT checked (1 typed ambiguous' <<<"$out_vc" && ! grep -q 'verify-corrections : FAIL' <<<"$out_vc"; then
  ok "AR-VCORR #1868: an AMBIG line is a typed PARTIAL naming its count, never a refusal (exit 0)"
else no "AR-VCORR ambig: rc=$rc_vc :: $(grep -iE 'verify-corrections|REFUSED' <<<"$out_vc" | head -3)"; fi


echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
