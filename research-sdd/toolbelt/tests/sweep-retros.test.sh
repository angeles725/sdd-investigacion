#!/usr/bin/env bash
# sweep-retros.test.sh — red-first regression harness for sweep-retros.sh (surfaces
# un-reviewed §18 self-retrospective proposals across research-sdd targets, METHODOLOGY §18).
#
# WHY THIS SHAPE. sweep-retros.sh is READ-ONLY pure text logic: it reads the backtick-wrapped
# absolute target paths out of the kit's TARGETS.md, walks each <target>/retros/*.md, and a retro
# is PENDING unless its top carries a 'review-status: applied' or 'review-status: dismissed'
# marker; for each pending retro it prints a 'PENDING <file>' line plus a '~N proposed deltas'
# count (rows shaped like '| <digits> |') and a 'status: <word|none>' tag, closing with a
# 'Summary: <pending> pending / <total> retros' line. This suite pins that contract — marker
# detection (pending vs applied vs dismissed vs unknown-word, plus case-insensitive normalization
# and leading-block-only marker scanning), the delta count, multi-target aggregation, the empty-summary
# and empty-retros-dir paths, and the truncated-'...'-path filter — WITHOUT any external tool. It never
# edits the SUT; it exercises a throwaway COPY placed inside a sandbox kit so KIT=dirname/.. resolves
# hermetically. The marker is only honored in the retro's LEADING BLOCK (line 1 until the first blank
# line or first '# ' heading); a marker sitting in the body is ignored — cases 14/16 pin that.
#
# Usage: sweep-retros.test.sh                (run the suite)
#        sweep-retros.test.sh --prove-teeth  (run suite + the mutation teeth proof)
# Exit: 0 = every assertion held · 1 = a regression · 2 = harness error.

set -uo pipefail
# HERMETICITY (kit issue #1157): never read the developer's real ~/.claude/projects launch history.
export RSDD_CLAUDE_PROJECTS_DIR="/nonexistent/rsdd-claude-history"
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="${SWEEP_RETROS_SUT:-$HERE/../sweep-retros.sh}"   # override = run the suite against another build (RED check)
[ -f "$SUT" ] || { echo "FATAL: script under test not found: $SUT" >&2; exit 2; }
BASH_BIN="$(type -P bash)"; [ -n "$BASH_BIN" ] || { echo "FATAL: bash not on PATH" >&2; exit 2; }
LIB="$HERE/../lib/retro-status.sh"           # shared marker reader the SUT now sources
[ -f "$LIB" ] || { echo "FATAL: helper not found: $LIB" >&2; exit 2; }
TP_LIB="$HERE/../lib/target-paths.sh"        # shared path derivation the SUT now sources
[ -f "$TP_LIB" ] || { echo "FATAL: target-paths helper not found: $TP_LIB" >&2; exit 2; }
RG_LIB="$HERE/../lib/retro-grammar.sh"       # shared delta-heading grammar the SUT now sources
[ -f "$RG_LIB" ] || { echo "FATAL: retro-grammar helper not found: $RG_LIB" >&2; exit 2; }
# shellcheck source=lib/stage-libs.sh
. "$HERE/lib/stage-libs.sh"   # rsdd_stage_libs: stage every toolbelt/lib file into a sandbox kit toolbelt
[ -f "$HERE/../lib/hook-wiring.sh" ] || { echo "FATAL: hook-wiring helper not found: $HERE/../lib/hook-wiring.sh" >&2; exit 2; }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
# HERMETICITY (kit issue #1140 round-2 review, Blocking 4): lib/hook-wiring.sh's git-root walk-up
# climbs from a target to `/` unless RSDD_HOOK_WIRING_CEILING is set. Several fixtures below
# `git init` a target under $ROOT; without this, a $TMPDIR that happens to sit inside a real repo
# (this kit checkout, for instance) would let an ENCLOSING repo's .git bleed into every fixture.
RSDD_HOOK_WIRING_CEILING="$(dirname "$ROOT")"
export RSDD_HOOK_WIRING_CEILING
pass=0; fail=0
ok()   { printf '  PASS  %-56s %s\n' "$1" "${2:-}"; pass=$((pass+1)); }
no()   { printf '  FAIL  %-56s %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

# mkkit <name> : lay down a runnable COPY of the SUT at <ROOT>/<name>/toolbelt/ so the script's
# KIT=dirname/.. resolves inside the sandbox; echoes the kit dir. TARGETS.md goes at its top.
mkkit() {
  local kit="$ROOT/$1"
  rsdd_stage_libs "$kit/toolbelt"   # every lib the SUT sources (retro-status, target-paths, block-files, retro-grammar, hook-wiring)
  cp "$SUT" "$kit/toolbelt/sweep-retros.sh"
  printf '%s' "$kit"
}

# write_targets <kit> <targetpath...> : build a minimal TARGETS.md whose table carries each
# target as a backtick-wrapped absolute path — the only thing the SUT reads out of it.
write_targets() {
  local kit="$1"; shift
  { printf '# targets\n\n| # | name | path |\n|---|---|---|\n'
    local i=0 t
    for t in "$@"; do i=$((i+1)); printf '| %d | t%d | `%s` |\n' "$i" "$i" "$t"; done
  } > "$kit/TARGETS.md"
}

# mkretro <target> <filename> <marker-line|-> <ndeltas> : write a retro with an optional top
# marker line and <ndeltas> table rows shaped like '| <n> | ... |' (what the SUT counts).
mkretro() {
  local tgt="$1" fname="$2" marker="$3" nd="$4" i=0
  mkdir -p "$tgt/retros"
  {
    [ "$marker" = "-" ] || printf '%s\n' "$marker"
    printf '# retro\n\n## Proposed kit deltas\n\n| # | delta | rationale |\n|---|---|---|\n'
    while [ "$i" -lt "$nd" ]; do i=$((i+1)); printf '| %d | delta %d | because |\n' "$i" "$i"; done
  } > "$tgt/retros/$fname"
}

# wire_target <target> : create a minimal .claude/settings.json that wires retro-gate under the
# "Stop" event block so the wiring-status pass stays quiet (no absent-settings or unwired WARN)
# for tests focused on other behaviour. Writes real JSON so the awk Stop-scoped check passes.
# Call after the target dir already exists (mkretro/mkdir ensures that).
wire_target() {
  local t="$1"
  mkdir -p "$t/.claude"
  printf '{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"retro-gate-stop.sh"}]}]}}\n' \
    > "$t/.claude/settings.json"
}

# run <kit> : invoke the sandbox copy of the SUT, capture stdout+stderr into OUT, exit into RC.
run() { OUT="$("$BASH_BIN" "$1/toolbelt/sweep-retros.sh" 2>&1)"; RC=$?; }

# run_profile <kit> : invoke with RSDD_PROFILE=1; capture STDOUT_P/STDERR_P/RC separately.
run_profile() {
  local _ef; _ef="$(mktemp "$ROOT/prof.XXXXXX")"
  STDOUT_P="$(RSDD_PROFILE=1 "$BASH_BIN" "$1/toolbelt/sweep-retros.sh" 2>"$_ef")"; RC=$?
  STDERR_P="$(cat "$_ef")"; rm -f "$_ef"
}

# mkretro_git <target> <filename> <marker-line|-> <ndeltas> <git-date> <mtime> : like mkretro, but the
# target becomes a hermetic git repo and the retro's git FIRST-COMMIT date is set INDEPENDENTLY of its
# file mtime via GIT_AUTHOR_DATE/GIT_COMMITTER_DATE (deterministic — no wall-clock flakiness; the sibling
# stage-retro.test.sh already relies on this idiom via its `mkrepo` helper) so a case can prove the AGING
# feature reads the git-added date, not mtime. Lazily inits the target repo (idempotent across calls).
mkretro_git() {
  local tgt="$1" fname="$2" marker="$3" nd="$4" gdate="$5" mtime="$6"
  mkretro "$tgt" "$fname" "$marker" "$nd"
  if [ ! -d "$tgt/.git" ]; then
    git -C "$tgt" init -q -b main
    git -C "$tgt" config user.email t@example.com
    git -C "$tgt" config user.name tester
  fi
  git -C "$tgt" add -A
  GIT_AUTHOR_DATE="$gdate" GIT_COMMITTER_DATE="$gdate" git -C "$tgt" commit -q -m "add $fname"
  touch -d "$mtime" "$tgt/retros/$fname"
}

echo "== sweep-retros.test.sh (SUT: $(basename "$SUT")) =="


echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
