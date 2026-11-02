#!/usr/bin/env bash
# retro-gate.test.sh — RED-FIRST regression harness for retro-gate.sh (U17 / #479 PR2).
#
# Exercises the Stop-hook body: loop-safety (stop_hook_active), block-once, no-change
# early exit, MISSING-RETRO block, non-conforming retro block, conforming retro allow.
#
# TEETH (--prove-teeth): sentinel-based mutants prove each guard actually bites.
#   blocks-twice          mutant ignores block-once state file → blocks second call
#   allows-unmarked       mutant skips verify-retro → allows non-conforming retro
#   ignores-stop_hook_active  mutant removes stop_hook_active check → blocks loop
#   reason-not-actionable mutant reduces reason to bare "retro pending"
#   nojq-path-dirname-leak  old dirname logic leaks jq via /bin→/usr/bin duplicate
#   nw-* / catalog-not-excluded  (#1223, #1229) nested-worktree guards and the CATALOG.md skip
#   hb-*                  (#1161) hermetic-bin builder: skip glob, first-wins, excluded name, batch ln
#   esc-*                 (#1167 item 2) _json_escape_reason replacement operand; esc-ctrl* (#1301-6)
#   l-*                   (#1301) one mutant per `find -H` scan site (symlinked target)
#   dirlink-*, bp-read-unbraced  (#1311) directory-symlink scan; back-pointer read stderr
#   dirlink-untracked-leg, -timeout-validation, -newline-split, -fallback-print  (#1352) Part C follow-ups
#   nw-backpointer-dropped, p-*  (#1301) worktree back-pointer proof; probe-failure fail-safe
#   j-*                   (#1711) one mutant per --json guard: block/allow envelope sites, counts, check_mode,
#                         usage/operational/degraded/build-failure exit codes, degraded envelope, default-mode decision
#
# Usage: retro-gate.test.sh [--prove-teeth]     Exit: 0 = all held · 1 = regression

set -uo pipefail
# HERMETICITY (kit issue #1157): never read the developer's real ~/.claude/projects launch history.
export RSDD_CLAUDE_PROJECTS_DIR="/nonexistent/rsdd-claude-history"
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../retro-gate.sh"
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
# shellcheck source=lib/stage-libs.sh
. "$HERE/lib/stage-libs.sh"   # rsdd_stage_libs: stage every toolbelt/lib file into a fixture kit toolbelt
BASH_BIN="$(type -P bash)"; [ -n "$BASH_BIN" ] || { echo "FATAL: bash not on PATH" >&2; exit 2; }
# verify-retro.sh must exist (merged in PR1)
VR="$HERE/../verify-retro.sh"
[ -f "$VR" ] || { echo "FATAL: verify-retro.sh not found (PR1 must be merged): $VR" >&2; exit 2; }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
pass=0; fail=0
ok() { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

# ── Fixture helpers ───────────────────────────────────────────────────────────

# mkgit <dir>: init a hermetic git repo with one baseline commit (idempotent)
mkgit() {
  local d="$1"
  mkdir -p "$d"
  if [ ! -d "$d/.git" ]; then
    git -C "$d" init -q -b main
    git -C "$d" config user.email t@example.com
    git -C "$d" config user.name tester
    touch "$d/.gitkeep"
    git -C "$d" add -A
    GIT_AUTHOR_DATE="2026-01-01T00:00:00" GIT_COMMITTER_DATE="2026-01-01T00:00:00" \
      git -C "$d" commit -q -m "init"
  fi
}

# mksessionfile <target> <session_id> [<mtime-touch-arg>]:
# records current HEAD sha as session-start; optionally sets explicit mtime.
# MUST be called BEFORE mkblock so the session sha precedes the block commit.
mksessionfile() {
  local tgt="$1" sid="$2" mtime="${3:-}"
  mkdir -p "$tgt/.claude"
  git -C "$tgt" rev-parse HEAD > "$tgt/.claude/.rsdd-session-$sid"
  [ -n "$mtime" ] && touch -t "$mtime" "$tgt/.claude/.rsdd-session-$sid"
}

# mkblock <target> <name> <gdate>: create and commit a block file
mkblock() {
  local tgt="$1" name="$2" gdate="$3"
  printf '# Block — test\n\nContent.\n' > "$tgt/$name"
  git -C "$tgt" add "$name"
  GIT_AUTHOR_DATE="$gdate" GIT_COMMITTER_DATE="$gdate" \
    git -C "$tgt" commit -q -m "add $name"
}

# mkretro <target> <fname> <conforming:1|0>: create a retro file (in retros/)
mkretro() {
  local tgt="$1" fname="$2" ok_retro="$3"
  mkdir -p "$tgt/retros"
  if [ "$ok_retro" -eq 1 ]; then
    printf '<!-- review-status: pending -->\n# Retro — test\n\n## Proposed kit deltas\n\n| # | change | target | evidence | type | priority |\n|---|---|---|---|---|---|\n| 1 | test delta fixture row | file.sh | evidence | fix | low |\n' \
      > "$tgt/retros/$fname"
  else
    # non-conforming: missing marker and delta section
    printf '# Retro — test\n\nSome notes.\n' > "$tgt/retros/$fname"
  fi
}

# mkjson <session_id> <stop_hook_active:true|false>: generate Stop-hook JSON
mkjson() {
  printf '{"session_id":"%s","stop_hook_active":%s,"hook_event_name":"Stop","cwd":"/tmp"}' "$1" "$2"
}

# run_gate <target> <json_str> → sets OUT RC ERR
run_gate() {
  local tgt="$1" json="$2" errf
  errf="$ROOT/err.$$"
  OUT="$(printf '%s' "$json" | "$BASH_BIN" "$SUT" "$tgt" 2>"$errf")"; RC=$?
  ERR="$(cat "$errf")"; rm -f "$errf"
}

# run_mutant <mutant_path> <target> <json_str> → sets OUT RC ERR
run_mutant() {
  local m="$1" tgt="$2" json="$3" errf
  errf="$ROOT/merr.$$"
  OUT="$(printf '%s' "$json" | "$BASH_BIN" "$m" "$tgt" 2>"$errf")"; RC=$?
  ERR="$(cat "$errf")"; rm -f "$errf"
}

# build_hermetic_nojq_bin <src_path> <out_dir>
# Populate <out_dir> with symlinks to every executable reachable from <src_path> except jq.
# <src_path> is a colon-separated PATH string. First-wins across dirs prevents duplicate-dir
# entries (e.g. /bin→/usr/bin on Ubuntu) from leaking jq through a second path entry.
# Used by both the main NOJQ_PATH setup and TOOTH 9, so both exercise the same code path
# and TOOTH 9 proves the function handles duplicate dirs correctly (#910 refactor).
#
# #1161 — cost: on WSL the ambient PATH carries the Windows PATH (63 /mnt/c/... entries, and
# /mnt/c/WINDOWS/system32 alone has ~5,300 entries on a 9P mount), and the old body forked
# `basename` plus `ln` once per executable. Now (a) source dirs matching HERMETIC_BIN_SKIP_GLOB
# (default '/mnt/*' = WSL Windows drive mounts; nothing the SUT or this suite runs lives there)
# are never walked, (b) the name comes from ${_exe##*/} (no fork), (c) links are created with ONE
# `ln -s -t` per source dir. First-wins semantics are unchanged.
build_hermetic_nojq_bin() {
  local src_path="$1" out_dir="$2" _oifs _pd _exe _n _batch _skip="${HERMETIC_BIN_SKIP_GLOB:-/mnt/*}"
  _oifs="$IFS"; IFS=':'
  for _pd in $src_path; do
    IFS="$_oifs"
    [ -d "$_pd" ] || continue
    # SENTINEL-HB-SKIP-START
    # shellcheck disable=SC2254
    case "$_pd" in $_skip) continue ;; esac
    # SENTINEL-HB-SKIP-END
    _batch=()
    while IFS= read -r -d '' _exe; do
      _n="${_exe##*/}"
      [ "$_n" = "jq" ] && continue
      [ -e "$out_dir/$_n" ] && continue   # SENTINEL-HB-FIRSTWINS
      _batch+=("$_exe")
    done < <(find "$_pd" -maxdepth 1 \( -type f -o -type l \) -executable -print0 2>/dev/null)
    if [ "${#_batch[@]}" -gt 0 ]; then ln -s -t "$out_dir" -- "${_batch[@]}"; fi
  done
  IFS="$_oifs"
}

# Build NOJQ_PATH: a hermetic single-dir PATH with symlinks to every executable on
# the current PATH except jq.  Resolving by name (first-wins across dirs) prevents
# /bin→/usr/bin duplicates from leaking jq even when jq lives in the canonical target.
_NOJQ_BIN="$ROOT/nojq_bin"
mkdir -p "$_NOJQ_BIN"
if command -v jq >/dev/null 2>&1; then
  build_hermetic_nojq_bin "$PATH" "$_NOJQ_BIN"
  NOJQ_PATH="$_NOJQ_BIN"
else
  NOJQ_PATH="$PATH"  # jq already absent
fi

# Build FAIL_AUTH_GH_DIR: a bin dir with a fake gh that fails auth status.
# This simulates gh present-but-not-authenticated (more portable than truly hiding gh).
FAIL_AUTH_GH_DIR="$ROOT/failauthbin"
mkdir -p "$FAIL_AUTH_GH_DIR"
cat > "$FAIL_AUTH_GH_DIR/gh" << 'FAILGHEOF'
#!/usr/bin/env bash
# fake gh: auth status always fails (not authenticated), other ops succeed
case "${1:-} ${2:-}" in
  "auth status") exit 1 ;;
  *) exit 0 ;;
esac
FAILGHEOF
chmod +x "$FAIL_AUTH_GH_DIR/gh"

# run_gate_nojq <target> <json_str> → sets OUT RC ERR; hides jq from PATH
run_gate_nojq() {
  local tgt="$1" json="$2" errf
  errf="$ROOT/err_nojq.$$"
  OUT="$(printf '%s' "$json" | PATH="$NOJQ_PATH" "$BASH_BIN" "$SUT" "$tgt" 2>"$errf")"; RC=$?
  ERR="$(cat "$errf")"; rm -f "$errf"
}

# run_mutant_nojq <mutant_path> <target> <json_str> → sets OUT RC ERR; hides jq from PATH
run_mutant_nojq() {
  local m="$1" tgt="$2" json="$3" errf
  errf="$ROOT/merr_nojq.$$"
  OUT="$(printf '%s' "$json" | PATH="$NOJQ_PATH" "$BASH_BIN" "$m" "$tgt" 2>"$errf")"; RC=$?
  ERR="$(cat "$errf")"; rm -f "$errf"
}

# ── EN3: fixture-kit helpers (seeding tests) ──────────────────────────────────
# FKIT mirrors the real toolbelt but uses a stub stage-retro-issues.sh that logs
# calls to SEED_LOG (env var).  A mock-gh dir is prepended to PATH so gh probes pass.
FKIT="$ROOT/fkit"
rsdd_stage_libs "$FKIT/toolbelt"
cp "$HERE/../verify-retro.sh"       "$FKIT/toolbelt/"
# Stub seeder: logs "<retro> <flags>" to SEED_LOG, emits real summary: format, exits 0
cat > "$FKIT/toolbelt/stage-retro-issues.sh" << 'STUBEOF'
#!/usr/bin/env bash
# EN3 test stub: log all arguments to SEED_LOG (env var); emit real summary: line
printf '%s\n' "$*" >> "${SEED_LOG:-/dev/null}"
printf 'summary: created=0 skipped-duplicate=0 skipped-shipped=0 skipped-wrong-kit=0\n'
exit 0
STUBEOF
chmod +x "$FKIT/toolbelt/stage-retro-issues.sh"
# Copy the SUT into FKIT so SELF_DIR-relative KIT path points to stub seeder
cp "$SUT" "$FKIT/toolbelt/retro-gate.sh"
# Mock gh: auth status always succeeds, other calls are no-ops
MOCK_GH_DIR="$ROOT/mockbin"
mkdir -p "$MOCK_GH_DIR"
cat > "$MOCK_GH_DIR/gh" << 'GHEOF'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "auth status") exit 0 ;;
  *) exit 0 ;;
esac
GHEOF
chmod +x "$MOCK_GH_DIR/gh"

SEED_LOG_EN3="$ROOT/en3-seed.log"

# run_fkit_gate <target> <json_str> → sets OUT RC ERR; uses FKIT SUT + stub seeder + mock gh
run_fkit_gate() {
  local tgt="$1" json="$2" errf
  errf="$ROOT/fkit_err.$$"
  OUT="$(printf '%s' "$json" | SEED_LOG="$SEED_LOG_EN3" \
    PATH="$MOCK_GH_DIR:$PATH" "$BASH_BIN" "$FKIT/toolbelt/retro-gate.sh" "$tgt" 2>"$errf")"; RC=$?
  ERR="$(cat "$errf")"; rm -f "$errf"
}

# run_gate_nogh <target> <json_str> → sets OUT RC ERR; uses fake-auth-failing gh (real SUT)
# simulates gh present but not authenticated → triggers the not-authenticated WARN
run_gate_nogh() {
  local tgt="$1" json="$2" errf
  errf="$ROOT/err_nogh.$$"
  OUT="$(printf '%s' "$json" | PATH="$FAIL_AUTH_GH_DIR:$PATH" "$BASH_BIN" "$SUT" "$tgt" 2>"$errf")"; RC=$?
  ERR="$(cat "$errf")"; rm -f "$errf"
}

echo "== retro-gate.test.sh (SUT: $(basename "$SUT")) =="

# ─── BAD ARGS ────────────────────────────────────────────────────────────────
printf '' | "$BASH_BIN" "$SUT" >/dev/null 2>&1; _rc=$?
[ "$_rc" -eq 0 ] && ok "BAD: no arg → exit 0 (hook contract)" || no "BAD: no arg — want exit 0, got $_rc"

printf '' | "$BASH_BIN" "$SUT" "/nonexistent-target-$$" >/dev/null 2>&1; _rc=$?
[ "$_rc" -eq 0 ] && ok "BAD: nonexistent target → exit 0 (hook contract)" || no "BAD: nonexistent — want 0, got $_rc"

# ─── (1) stop_hook_active=true → always allow, even with changed block ───────
T1="$ROOT/t1"; mkgit "$T1"; SID1="sess-001"
mksessionfile "$T1" "$SID1" "202609050800"  # session sha before block; mtime 08:00
mkblock "$T1" "niagara-block1.md" "2026-09-05T10:00:00"
# Mtime: session=08:00, block=now (after 08:00 → detectable); stop_hook_active=true overrides

_j1="$(mkjson "$SID1" "true")"
run_gate "$T1" "$_j1"
[ "$RC" -eq 0 ] && ok "ALLOW: stop_hook_active=true → exit 0" || no "ALLOW: stop_hook_active=true — want 0, got $RC"
[ -z "$OUT" ] && ok "ALLOW: stop_hook_active=true → no block JSON on stdout" || no "ALLOW: stop_hook_active=true — unexpected stdout: $OUT"
<<<"$ERR" grep -q 'loop-safety' && ok "ALLOW: stop_hook_active stderr says loop-safety" \
  || no "ALLOW: stop_hook_active — stderr missing 'loop-safety': $ERR"

# ─── (2) First call with block + no retro → blocks ───────────────────────────
T2="$ROOT/t2"; mkgit "$T2"; SID2="sess-002"
mksessionfile "$T2" "$SID2" "202609050800"
mkblock "$T2" "niagara-block1.md" "2026-09-05T10:00:00"

_j2="$(mkjson "$SID2" "false")"
run_gate "$T2" "$_j2"
[ "$RC" -eq 0 ] && ok "BLOCK: no retro → exit 0 (hook contract)" || no "BLOCK: no retro — want exit 0, got $RC"
<<<"$OUT" grep -qF '"decision":"block"' && ok "BLOCK: no retro → decision=block in stdout" \
  || no "BLOCK: no retro — missing decision:block in stdout: $OUT"
<<<"$OUT" grep -qF 'retro.template.md' && ok "BLOCK: no retro → reason has template ref" \
  || no "BLOCK: no retro — reason missing template ref: $OUT"

# ─── (3) Block-once: second call in same session → allow ─────────────────────
run_gate "$T2" "$_j2"
[ "$RC" -eq 0 ] && ok "ALLOW: block-once second call → exit 0" || no "ALLOW: block-once — want 0, got $RC"
[ -z "$OUT" ] && ok "ALLOW: block-once second call → no block JSON" || no "ALLOW: block-once — expected no block, got: $OUT"
<<<"$ERR" grep -q 'block-once' && ok "ALLOW: block-once stderr says block-once" \
  || no "ALLOW: block-once — stderr missing 'block-once': $ERR"

# ─── (4) No research files changed → allow ───────────────────────────────────
T3="$ROOT/t3"; mkgit "$T3"; SID3="sess-003"
# Commit a non-research file, then take snapshot AFTER that commit
printf 'readme\n' > "$T3/README.txt"
git -C "$T3" add README.txt
GIT_AUTHOR_DATE="2026-09-05T09:00:00" GIT_COMMITTER_DATE="2026-09-05T09:00:00" \
  git -C "$T3" commit -q -m "add readme"
mksessionfile "$T3" "$SID3"  # records sha AFTER readme commit
# No research files after session start → both git-diff and find-newer return empty

_j3="$(mkjson "$SID3" "false")"
run_gate "$T3" "$_j3"
[ "$RC" -eq 0 ] && ok "ALLOW: no research change → exit 0" || no "ALLOW: no change — want 0, got $RC"
[ -z "$OUT" ] && ok "ALLOW: no research change → no block JSON" || no "ALLOW: no change — unexpected stdout: $OUT"
<<<"$ERR" grep -q 'no-change' && ok "ALLOW: no-change branch in stderr" \
  || no "ALLOW: no-change — stderr missing 'no-change': $ERR"

# ─── (5) Conforming retro newer than block → allow ───────────────────────────
T4="$ROOT/t4"; mkgit "$T4"; SID4="sess-004"
mksessionfile "$T4" "$SID4" "202609050800"   # session mtime: 08:00
mkblock "$T4" "niagara-block1.md" "2026-09-05T10:00:00"
touch -t 202609051000 "$T4/niagara-block1.md"   # block mtime: 10:00
mkretro "$T4" "2026-09-05-good-retro.md" 1
touch -t 202609051200 "$T4/retros/2026-09-05-good-retro.md"  # retro mtime: 12:00

_j4="$(mkjson "$SID4" "false")"
run_gate "$T4" "$_j4"
[ "$RC" -eq 0 ] && ok "ALLOW: conforming retro newer than block → exit 0" || no "ALLOW: conform — want 0, got $RC"
[ -z "$OUT" ] && ok "ALLOW: conforming retro → no block JSON" || no "ALLOW: conform — unexpected stdout: $OUT"
<<<"$ERR" grep -q 'retro-conforming' && ok "ALLOW: conforming retro branch in stderr" \
  || no "ALLOW: conform — stderr missing 'retro-conforming': $ERR"

# ─── Summary ─────────────────────────────────────────────────────────────────
echo
echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] && exit 0 || exit 1
