#!/usr/bin/env bash
# research-sdd-install.test.sh — RED-FIRST harness for the multi-harness kit installer.
#
# The discriminating behaviour: ONE table-driven install loop surfaces the neutral SKILL.md +
# a launcher into every harness's own paths (claude / opencode / codex), WITHOUT any per-harness
# branching in the loop. --dry-run must print a deterministic plan (locked by committed goldens);
# apply must be idempotent (re-running never duplicates the marked prompt section).
#
# Usage: research-sdd-install.test.sh [--prove-teeth]   Exit: 0 all held · 1 regression · 2 setup.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../research-sdd-install.sh"
GOLD="$HERE/golden"
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
TMP="$(mktemp -d)"; MUTANT=""
trap 'rm -rf "$TMP"; [ -n "$MUTANT" ] && rm -f "$MUTANT"' EXIT
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

# Normalise a per-run tmp home to a stable placeholder so goldens are machine-independent.
norm(){ sed "s|$1|{HOME}|g"; }

echo "== research-sdd-install.test.sh =="

# 1..3 — dry-run plan per harness matches its committed golden (locks WHERE + WHAT is written).
for h in claude opencode codex; do
  home="$TMP/dry-$h"
  out="$(bash "$SUT" --dry-run --home "$home" --harness "$h" 2>&1 | norm "$home")"
  g="$GOLD/plan-$h.txt"
  if [ ! -f "$g" ]; then no "golden missing: plan-$h.txt"; continue; fi
  if [ "$out" = "$(cat "$g")" ]; then ok "dry-run plan ($h) matches golden"
  else no "dry-run plan ($h) drifted from golden"; diff <(cat "$g") <(printf '%s\n' "$out") | head -20; fi
done

# 4 — dry-run writes NOTHING (pure planning).
home="$TMP/nowrite"; bash "$SUT" --dry-run --home "$home" --harness all >/dev/null 2>&1
[ ! -e "$home" ] && ok "dry-run creates no files" || no "dry-run mutated the filesystem under $home"

# 5 — apply installs the neutral SKILL.md into the harness's own skills dir (claude leg preserved).
home="$TMP/apply"; bash "$SUT" --home "$home" --harness all >/dev/null 2>&1
skill="$home/.claude/skills/research-sdd/SKILL.md"
if [ -f "$skill" ] && grep -q 'Research-SDD launcher' "$skill"; then ok "apply installs neutral SKILL.md (claude)"
else no "SKILL.md not installed for claude at $skill"; fi
[ -f "$home/.codex/skills/research-sdd/SKILL.md" ] && ok "apply installs SKILL.md (codex leg)" || no "codex SKILL.md missing"

# 6 — apply is idempotent: run twice, exactly ONE marked section in the prompt file.
home="$TMP/idem"
bash "$SUT" --home "$home" --harness claude >/dev/null 2>&1
bash "$SUT" --home "$home" --harness claude >/dev/null 2>&1
pf="$home/.claude/CLAUDE.md"
n="$(grep -c '<!-- research-sdd:start -->' "$pf" 2>/dev/null || echo 0)"
[ "$n" = 1 ] && ok "idempotent: exactly one marked section after two applies" || no "idempotency broken: $n marked sections in $pf"

# 7 — apply preserves pre-existing prompt-file content (markdown-sections splice, not clobber).
home="$TMP/preserve"; mkdir -p "$home/.claude"; printf '# my own notes\nkeep me\n' > "$home/.claude/CLAUDE.md"
bash "$SUT" --home "$home" --harness claude >/dev/null 2>&1
grep -q 'keep me' "$home/.claude/CLAUDE.md" && ok "markdown-sections preserves existing content" || no "existing CLAUDE.md content clobbered"

# 8 — codex leg documents the manual session-start sweep (no hook fires there); claude does NOT.
home="$TMP/sweep"; bash "$SUT" --home "$home" --harness all >/dev/null 2>&1
cx="$home/.codex/AGENTS.md"; cl="$home/.claude/CLAUDE.md"
if grep -q 'sweep-retros.sh' "$cx" && grep -q 'verify-registry.sh' "$cx"; then ok "codex AGENTS.md documents the manual sweep fallback"
else no "codex sweep-fallback doc missing in $cx"; fi
grep -q 'sweep-retros.sh' "$cl" && no "claude section wrongly carries sweep fallback (has a hook)" || ok "claude section omits sweep fallback (hook fires instead)"

# 9 — opencode surfaces via markdown-sections into a fresh AGENTS.md: the launcher marker is present.
home="$TMP/fr"; bash "$SUT" --home "$home" --harness opencode >/dev/null 2>&1
grep -q '<!-- research-sdd:start -->' "$home/.config/opencode/AGENTS.md" 2>/dev/null \
  && ok "opencode markdown-sections writes the launcher into AGENTS.md" || no "opencode AGENTS.md missing the launcher marker"

# 10 — the install loop carries ZERO per-harness case arms (all divergence lives in the adapter table).
#      A case arm is a harness name at a statement boundary followed by `|` or `)` (e.g. `claude)`);
#      prose mentions like "(opencode)" in a comment are ignored.
if grep -Eq '^[[:space:]]*(claude|opencode|codex)[|)]' "$SUT"; then no "installer has a per-harness case arm (should be table-driven)"
else ok "install loop has no per-harness branching"; fi

# 11 — CRITICAL 1: opencode's AGENTS.md is the user's GLOBAL system prompt. Installing MUST splice a
#      marked section, preserving pre-existing user content, NOT truncate the whole file.
home="$TMP/oc-preserve"; mkdir -p "$home/.config/opencode"
printf '# user global prompt\nmy custom rule line\n' > "$home/.config/opencode/AGENTS.md"
bash "$SUT" --home "$home" --harness opencode >/dev/null 2>&1
pf="$home/.config/opencode/AGENTS.md"
n="$(grep -c '<!-- research-sdd:start -->' "$pf" 2>/dev/null || echo 0)"
if grep -q 'my custom rule line' "$pf" && [ "$n" = 1 ]; then ok "opencode preserves user AGENTS.md content (splice, exactly one section)"
else no "opencode clobbered user AGENTS.md (present? $(grep -qc 'my custom rule line' "$pf"; echo $?), sections=$n)"; fi

# 12 — CRITICAL 2: an orphaned start marker (no matching end, hand-edited file) must NOT drop every
#      trailing user line to EOF. Trailing user content MUST survive the re-splice.
home="$TMP/orphan"; mkdir -p "$home/.claude"
printf '# top\n<!-- research-sdd:start -->\nstale body\nIMPORTANT user tail line\n' > "$home/.claude/CLAUDE.md"
bash "$SUT" --home "$home" --harness claude >/dev/null 2>&1
grep -q 'IMPORTANT user tail line' "$home/.claude/CLAUDE.md" \
  && ok "orphaned start marker: trailing user content preserved" \
  || no "orphaned start marker dropped trailing user content to EOF"

# 13 — CRITICAL 3: on a partial failure (one harness's config-root parent non-writable), overall exit
#      MUST be nonzero AND the still-writable harnesses must still be installed.
if [ "$(id -u)" -eq 0 ]; then ok "exit-code aggregation test skipped (running as root, chmod is a no-op)"
else
  home="$TMP/aggr"; mkdir -p "$home/.config"; chmod 000 "$home/.config"
  bash "$SUT" --home "$home" --harness all >/dev/null 2>&1; rc=$?
  chmod 755 "$home/.config"
  [ "$rc" -ne 0 ] && ok "partial failure yields nonzero overall exit" || no "partial failure silently exited 0 (rc=$rc)"
  if [ -f "$home/.claude/skills/research-sdd/SKILL.md" ] && [ -f "$home/.codex/skills/research-sdd/SKILL.md" ]; then
    ok "partial failure still installs the writable harnesses (claude + codex)"
  else no "writable harnesses not installed after a mid-loop failure"; fi
fi

# 14 — WARNING 1: a symlinked prompt-file target must be written THROUGH (link preserved, real target
#      updated), never replaced by a plain file (which would sever the link / clobber the wrong path).
home="$TMP/symlink"; mkdir -p "$home/.claude"
# Pre-seed the REAL target with an existing marked section so the re-splice takes the rewrite path
# (not the fresh-append path) — that is the path that historically severed the link via `mv`.
printf '# real target\nuser data line\n<!-- research-sdd:start -->\nold section\n<!-- research-sdd:end -->\n' \
  > "$home/.claude/real-notes.md"
ln -s real-notes.md "$home/.claude/CLAUDE.md"
bash "$SUT" --home "$home" --harness claude >/dev/null 2>&1
if [ -L "$home/.claude/CLAUDE.md" ] && grep -q 'user data line' "$home/.claude/real-notes.md" \
   && grep -q '<!-- research-sdd:start -->' "$home/.claude/real-notes.md"; then
  ok "symlinked prompt file written through (link preserved, target spliced)"
else no "symlinked prompt file was severed/replaced instead of written through"; fi

# NEGATIVE CONTROL — neuter the idempotent splice (force blind append); two applies must then
# leave TWO marked sections, proving test 6's idempotency assertion has teeth.
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: neuter the marker-aware splice, expect duplicate sections on re-apply --"
  # Live beside the real SUT so the mutant still resolves adapters.sh + the kit's source SKILL.md.
  MUTANT="$HERE/../research-sdd-install.MUTANT.$$.sh"
  # Break the "does the file already carry our marker?" guard so splice always appends.
  sed 's/grep -q .<!-- research-sdd:start -->. "\$file"/false/' "$SUT" > "$MUTANT"
  home="$TMP/teeth"
  bash "$MUTANT" --home "$home" --harness claude >/dev/null 2>&1
  bash "$MUTANT" --home "$home" --harness claude >/dev/null 2>&1
  n="$(grep -c '<!-- research-sdd:start -->' "$home/.claude/CLAUDE.md" 2>/dev/null || echo 0)"
  [ "$n" -ge 2 ] && ok "teeth: append-only mutant duplicates the section → idempotency check has teeth" \
    || no "teeth: mutant did not duplicate ($n) — idempotency check is THEATER"
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
