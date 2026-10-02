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
#
# Usage: retro-gate.test.sh [--prove-teeth]     Exit: 0 = all held · 1 = regression

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../retro-gate.sh"
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
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
    printf '<!-- review-status: pending -->\n# Retro — test\n\n## Proposed kit deltas\n\n| # | change | target | evidence | type | priority |\n|---|---|---|---|---|---|\n| 1 | test delta | file.sh | evidence | fix | low |\n' \
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
mkdir -p "$FKIT/toolbelt/lib"
cp "$HERE/../lib/block-files.sh"    "$FKIT/toolbelt/lib/"
cp "$HERE/../lib/retro-status.sh"   "$FKIT/toolbelt/lib/"
cp "$HERE/../lib/retro-grammar.sh"  "$FKIT/toolbelt/lib/"
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
printf '%s' "$ERR" | grep -q 'loop-safety' && ok "ALLOW: stop_hook_active stderr says loop-safety" \
  || no "ALLOW: stop_hook_active — stderr missing 'loop-safety': $ERR"

# ─── (2) First call with block + no retro → blocks ───────────────────────────
T2="$ROOT/t2"; mkgit "$T2"; SID2="sess-002"
mksessionfile "$T2" "$SID2" "202609050800"
mkblock "$T2" "niagara-block1.md" "2026-09-05T10:00:00"

_j2="$(mkjson "$SID2" "false")"
run_gate "$T2" "$_j2"
[ "$RC" -eq 0 ] && ok "BLOCK: no retro → exit 0 (hook contract)" || no "BLOCK: no retro — want exit 0, got $RC"
printf '%s' "$OUT" | grep -qF '"decision":"block"' && ok "BLOCK: no retro → decision=block in stdout" \
  || no "BLOCK: no retro — missing decision:block in stdout: $OUT"
printf '%s' "$OUT" | grep -qF 'retro.template.md' && ok "BLOCK: no retro → reason has template ref" \
  || no "BLOCK: no retro — reason missing template ref: $OUT"

# ─── (3) Block-once: second call in same session → allow ─────────────────────
run_gate "$T2" "$_j2"
[ "$RC" -eq 0 ] && ok "ALLOW: block-once second call → exit 0" || no "ALLOW: block-once — want 0, got $RC"
[ -z "$OUT" ] && ok "ALLOW: block-once second call → no block JSON" || no "ALLOW: block-once — expected no block, got: $OUT"
printf '%s' "$ERR" | grep -q 'block-once' && ok "ALLOW: block-once stderr says block-once" \
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
printf '%s' "$ERR" | grep -q 'no-change' && ok "ALLOW: no-change branch in stderr" \
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
printf '%s' "$ERR" | grep -q 'retro-conforming' && ok "ALLOW: conforming retro branch in stderr" \
  || no "ALLOW: conform — stderr missing 'retro-conforming': $ERR"

# ─── (6) Non-conforming retro newer than block → block with actionable reason ─
T5="$ROOT/t5"; mkgit "$T5"; SID5="sess-005"
mksessionfile "$T5" "$SID5" "202609050800"
mkblock "$T5" "niagara-block1.md" "2026-09-05T10:00:00"
touch -t 202609051000 "$T5/niagara-block1.md"
mkretro "$T5" "2026-09-05-bad-retro.md" 0
touch -t 202609051200 "$T5/retros/2026-09-05-bad-retro.md"

_j5="$(mkjson "$SID5" "false")"
run_gate "$T5" "$_j5"
printf '%s' "$OUT" | grep -qF '"decision":"block"' && ok "BLOCK: non-conforming retro → decision=block" \
  || no "BLOCK: non-conforming — missing decision:block: $OUT"
printf '%s' "$OUT" | grep -qF 'retro.template.md' && ok "BLOCK: non-conforming reason has template ref" \
  || no "BLOCK: non-conforming — reason missing template ref: $OUT"
printf '%s' "$OUT" | grep -qF 'missing elements' && ok "BLOCK: non-conforming reason has missing elements" \
  || no "BLOCK: non-conforming — reason missing 'missing elements': $OUT"

# ─── (7) jq absent → degrade allow (exit 0, degraded stderr, no block JSON) ──
T6="$ROOT/t6"; mkgit "$T6"; SID6="sess-006"
mksessionfile "$T6" "$SID6" "202609050800"
mkblock "$T6" "niagara-block1.md" "2026-09-05T10:00:00"

_j6="$(mkjson "$SID6" "false")"
# Precondition: NOJQ_PATH must actually hide jq; if it leaks jq the downstream
# assertions would pass for the wrong reason (SUT uses jq normally, not degraded).
if PATH="$NOJQ_PATH" command -v jq >/dev/null 2>&1; then
  no "PRECOND(7): NOJQ_PATH still resolves jq — simulation broken, test 7 skipped"
else
  run_gate_nojq "$T6" "$_j6"
  [ "$RC" -eq 0 ] && ok "DEGRADE: jq absent → exit 0 (hook contract)" \
    || no "DEGRADE: jq absent — want exit 0, got $RC"
  [ -z "$OUT" ] && ok "DEGRADE: jq absent → no block JSON on stdout" \
    || no "DEGRADE: jq absent — unexpected stdout: $OUT"
  printf '%s' "$ERR" | grep -q 'branch=degraded' && ok "DEGRADE: jq absent → branch=degraded in stderr" \
    || no "DEGRADE: jq absent — stderr missing 'branch=degraded': $ERR"
  printf '%s' "$ERR" | grep -q 'jq missing' && ok "DEGRADE: jq absent → 'jq missing' in stderr" \
    || no "DEGRADE: jq absent — stderr missing 'jq missing': $ERR"
fi

# ─── (8) Pure-bash emitter: block JSON is valid + handles embedded " in reason ─
# Use target whose basename contains a double-quote — the reason embeds it.
T7="$ROOT/t7-dq\"test"; mkgit "$T7"; SID7="sess-007"
mksessionfile "$T7" "$SID7" "202609050800"
mkblock "$T7" "niagara-block1.md" "2026-09-05T10:00:00"

_j7="$(mkjson "$SID7" "false")"
run_gate "$T7" "$_j7"
[ "$RC" -eq 0 ] && ok "EMITTER: block with dq-name → exit 0" || no "EMITTER: dq-name — want 0, got $RC"
printf '%s' "$OUT" | grep -qF '"decision":"block"' \
  && ok "EMITTER: dq-name → decision=block present" \
  || no "EMITTER: dq-name — missing decision:block: $OUT"
if command -v jq >/dev/null 2>&1; then
  printf '%s' "$OUT" | jq . >/dev/null 2>&1 \
    && ok "EMITTER: block JSON with \" in reason is valid JSON (jq parses it)" \
    || no "EMITTER: block JSON failed jq parse (escaping bug): $OUT"
fi

# ─── (EN3-a) Conforming retro → seeding invoked with --apply ─────────────────
TEN3A="$ROOT/en3a"; mkgit "$TEN3A"; SIDEN3A="en3-sess-a"
mksessionfile "$TEN3A" "$SIDEN3A" "202609050800"
mkblock "$TEN3A" "niagara-block1.md" "2026-09-05T10:00:00"
touch -t 202609051000 "$TEN3A/niagara-block1.md"
mkretro "$TEN3A" "2026-09-05-seeding-test.md" 1
touch -t 202609051200 "$TEN3A/retros/2026-09-05-seeding-test.md"
_jen3a="$(mkjson "$SIDEN3A" "false")"

rm -f "$SEED_LOG_EN3"
run_fkit_gate "$TEN3A" "$_jen3a"
[ "$RC" -eq 0 ] && ok "EN3-a: conforming retro → exit 0 (seeding path still allows)" \
  || no "EN3-a: conforming retro → want exit 0, got $RC"
[ -z "$OUT" ] && ok "EN3-a: conforming retro → no block JSON on stdout" \
  || no "EN3-a: conforming retro → unexpected stdout: $OUT"
if [ -f "$SEED_LOG_EN3" ] && grep -qF -- '--apply' "$SEED_LOG_EN3"; then
  ok "EN3-a: stub seeder was called with --apply"
else
  no "EN3-a: stub seeder NOT called with --apply (seeding not triggered); log=$(cat "$SEED_LOG_EN3" 2>/dev/null || echo '<absent>')"
fi
printf '%s' "$ERR" | grep -q 'issue-seeding' && ok "EN3-a: 'issue-seeding' summary in stderr" \
  || no "EN3-a: 'issue-seeding' summary missing from stderr: $ERR"
printf '%s' "$ERR" | grep -q 'ran=1' && ok "EN3-a: ran=1 counter in issue-seeding summary" \
  || no "EN3-a: expected ran=1 in issue-seeding summary; got: $ERR"

# ─── (EN3-b) No retro → still blocks, seeding NOT called ─────────────────────
# (Existing T2 already verifies the block; this asserts seeding was not triggered)
rm -f "$SEED_LOG_EN3"
TEN3B="$ROOT/en3b"; mkgit "$TEN3B"; SIDEN3B="en3-sess-b"
mksessionfile "$TEN3B" "$SIDEN3B" "202609050800"
mkblock "$TEN3B" "niagara-block1.md" "2026-09-05T10:00:00"
_jen3b="$(mkjson "$SIDEN3B" "false")"
# Use real SUT (no stub needed; seeding should not be reached on block path)
run_gate "$TEN3B" "$_jen3b"
printf '%s' "$OUT" | grep -qF '"decision":"block"' \
  && ok "EN3-b: no retro → still produces decision:block" \
  || no "EN3-b: no retro → missing decision:block: $OUT"

# ─── (EN3-c) Conforming retro + gh absent → WARN + allow (not blocked) ───────
TEN3C="$ROOT/en3c"; mkgit "$TEN3C"; SIDEN3C="en3-sess-c"
mksessionfile "$TEN3C" "$SIDEN3C" "202609050800"
mkblock "$TEN3C" "niagara-block1.md" "2026-09-05T10:00:00"
touch -t 202609051000 "$TEN3C/niagara-block1.md"
mkretro "$TEN3C" "2026-09-05-good-retro.md" 1
touch -t 202609051200 "$TEN3C/retros/2026-09-05-good-retro.md"
_jen3c="$(mkjson "$SIDEN3C" "false")"
run_gate_nogh "$TEN3C" "$_jen3c"
[ "$RC" -eq 0 ] && ok "EN3-c: conforming retro + gh absent → exit 0 (still allows)" \
  || no "EN3-c: conforming retro + gh absent → want exit 0, got $RC"
[ -z "$OUT" ] && ok "EN3-c: conforming retro + gh absent → no block JSON" \
  || no "EN3-c: conforming retro + gh absent → unexpected stdout: $OUT"
printf '%s' "$ERR" | grep -q 'issue-seeding' && ok "EN3-c: gh absent → 'issue-seeding' in stderr (WARN or summary)" \
  || no "EN3-c: gh absent → 'issue-seeding' missing from stderr: $ERR"
printf '%s' "$ERR" | grep -q 'WARN' && ok "EN3-c: gh absent → 'WARN' in stderr" \
  || no "EN3-c: gh absent → 'WARN' missing from stderr: $ERR"

# ─── (EN3-d) Idempotent re-run: seeding called twice without error ────────────
# Two separate sessions → block-once does not suppress second run
rm -f "$SEED_LOG_EN3"
SIDEN3D1="en3-sess-d1"; SIDEN3D2="en3-sess-d2"
# reuse TEN3A fixtures; only session IDs differ
_jen3d1="$(mkjson "$SIDEN3D1" "false")"
_jen3d2="$(mkjson "$SIDEN3D2" "false")"
run_fkit_gate "$TEN3A" "$_jen3d1"
run_fkit_gate "$TEN3A" "$_jen3d2"
_seed_count=0
[ -f "$SEED_LOG_EN3" ] && _seed_count="$(wc -l < "$SEED_LOG_EN3" | tr -d ' ')"
[ "${_seed_count:-0}" -ge 2 ] && ok "EN3-d: idempotent — stub called at least twice (no error)" \
  || no "EN3-d: idempotent — stub called ${_seed_count} time(s), want ≥2; log=$(cat "$SEED_LOG_EN3" 2>/dev/null || echo '<absent>')"

# ─── (EN3-e) Failing seeder → WARN emitted, failed=N in summary, gate still allows ──
# Validates the seeder-rc fix: a non-zero seeder exit must NOT be swallowed silently.
FKIT_FAIL="$ROOT/fkit_fail"
mkdir -p "$FKIT_FAIL/toolbelt/lib"
cp "$HERE/../lib/block-files.sh"    "$FKIT_FAIL/toolbelt/lib/"
cp "$HERE/../lib/retro-status.sh"   "$FKIT_FAIL/toolbelt/lib/"
cp "$HERE/../lib/retro-grammar.sh"  "$FKIT_FAIL/toolbelt/lib/"
cp "$HERE/../verify-retro.sh"       "$FKIT_FAIL/toolbelt/"
# Failing seeder: exits 1 (simulates a seeder failure, e.g. API rate limit)
cat > "$FKIT_FAIL/toolbelt/stage-retro-issues.sh" << 'FAILEOF'
#!/usr/bin/env bash
printf 'seeder: error: API rate limit exceeded\n' >&2
exit 1
FAILEOF
chmod +x "$FKIT_FAIL/toolbelt/stage-retro-issues.sh"
cp "$SUT" "$FKIT_FAIL/toolbelt/retro-gate.sh"

run_fkit_fail_gate() {
  local tgt="$1" json="$2" errf
  errf="$ROOT/fkit_fail_err.$$"
  OUT="$(printf '%s' "$json" | SEED_LOG="$SEED_LOG_EN3" \
    PATH="$MOCK_GH_DIR:$PATH" "$BASH_BIN" "$FKIT_FAIL/toolbelt/retro-gate.sh" "$tgt" 2>"$errf")"; RC=$?
  ERR="$(cat "$errf")"; rm -f "$errf"
}

TEN3E="$ROOT/en3e"; mkgit "$TEN3E"; SIDEN3E="en3-sess-e"
mksessionfile "$TEN3E" "$SIDEN3E" "202609050800"
mkblock "$TEN3E" "niagara-block1.md" "2026-09-05T10:00:00"
touch -t 202609051000 "$TEN3E/niagara-block1.md"
mkretro "$TEN3E" "2026-09-05-fail-seeder.md" 1
touch -t 202609051200 "$TEN3E/retros/2026-09-05-fail-seeder.md"
_jen3e="$(mkjson "$SIDEN3E" "false")"
run_fkit_fail_gate "$TEN3E" "$_jen3e"
# Gate block/allow decision must be unaffected by seeder failure
[ "$RC" -eq 0 ] && ok "EN3-e: failing seeder → gate still allows (exit 0)" \
  || no "EN3-e: failing seeder → expected exit 0, got $RC"
[ -z "$OUT" ] && ok "EN3-e: failing seeder → no block JSON on stdout" \
  || no "EN3-e: failing seeder → unexpected stdout: $OUT"
printf '%s' "$ERR" | grep -q 'WARN.*seeder failed' && ok "EN3-e: failing seeder → WARN in stderr" \
  || no "EN3-e: failing seeder → expected 'WARN.*seeder failed' in stderr; got: $ERR"
printf '%s' "$ERR" | grep -q 'failed=1' && ok "EN3-e: failing seeder → failed=1 in summary line" \
  || no "EN3-e: failing seeder → expected 'failed=1' in summary; got: $ERR"
printf '%s' "$ERR" | grep -q 'WARN.*fail-seeder' && ok "EN3-e: failing seeder → retro filename in WARN line" \
  || no "EN3-e: failing seeder → expected 'WARN.*fail-seeder' in WARN line; got: $ERR"
# Seeder reason (first line of seeder output) appears in the per-retro WARN line
printf '%s' "$ERR" | grep -q 'WARN.*rate limit' && ok "EN3-e: failing seeder → seeder reason in WARN" \
  || no "EN3-e: failing seeder → expected seeder reason 'rate limit' in WARN; got: $ERR"

# ─── (EN3-e-partial) Partial seeder: creates some issues then fails ───────────
# Validates Issue 2 regression fix: created/skipped are counted regardless of seeder rc.
# On the old SUT the 'continue' before count causes created=0 even though one was created.
FKIT_PARTIAL="$ROOT/fkit_partial"
mkdir -p "$FKIT_PARTIAL/toolbelt/lib"
cp "$HERE/../lib/block-files.sh"    "$FKIT_PARTIAL/toolbelt/lib/"
cp "$HERE/../lib/retro-status.sh"   "$FKIT_PARTIAL/toolbelt/lib/"
cp "$HERE/../lib/retro-grammar.sh"  "$FKIT_PARTIAL/toolbelt/lib/"
cp "$HERE/../verify-retro.sh"       "$FKIT_PARTIAL/toolbelt/"
cat > "$FKIT_PARTIAL/toolbelt/stage-retro-issues.sh" << 'PARTIALEOF'
#!/usr/bin/env bash
# Partial seeder: creates 1 issue then exits 1 without summary: (tests fallback counting)
printf 'created: https://github.com/test/repo/issues/42 (row 1)\n'
printf 'seeder: rate limit exceeded after partial run\n' >&2
exit 1
PARTIALEOF
chmod +x "$FKIT_PARTIAL/toolbelt/stage-retro-issues.sh"
cp "$SUT" "$FKIT_PARTIAL/toolbelt/retro-gate.sh"

TEN3P="$ROOT/en3p"; mkgit "$TEN3P"; SIDEN3P="en3-sess-p"
mksessionfile "$TEN3P" "$SIDEN3P" "202609050800"
mkblock "$TEN3P" "niagara-block1.md" "2026-09-05T10:00:00"
touch -t 202609051000 "$TEN3P/niagara-block1.md"
mkretro "$TEN3P" "2026-09-05-partial.md" 1
touch -t 202609051200 "$TEN3P/retros/2026-09-05-partial.md"
_jen3p="$(mkjson "$SIDEN3P" "false")"
errf_p="$ROOT/fkit_partial_err.$$"
OUT="$(printf '%s' "$_jen3p" | PATH="$MOCK_GH_DIR:$PATH" \
  "$BASH_BIN" "$FKIT_PARTIAL/toolbelt/retro-gate.sh" "$TEN3P" 2>"$errf_p")"; RC=$?
ERR_P="$(cat "$errf_p")"; rm -f "$errf_p"
# Gate decision unchanged
[ "$RC" -eq 0 ] && ok "EN3-e-partial: partial seeder → gate still allows (exit 0)" \
  || no "EN3-e-partial: partial seeder → expected exit 0; got $RC"
# created=1 in summary (partial progress must be counted even on failure)
printf '%s' "$ERR_P" | grep -q 'created=1' && ok "EN3-e-partial: partial seeder → created=1 in summary" \
  || no "EN3-e-partial: partial seeder → expected 'created=1' in summary; got: $ERR_P"
# failed=1 in summary
printf '%s' "$ERR_P" | grep -q 'failed=1' && ok "EN3-e-partial: partial seeder → failed=1 in summary" \
  || no "EN3-e-partial: partial seeder → expected 'failed=1' in summary; got: $ERR_P"
# WARN must say count came from partial-progress lines (not summary)
printf '%s' "$ERR_P" | grep -q 'no summary:.*counted.*partial-progress' && ok "EN3-e-partial: partial seeder → WARN mentions partial-progress count" \
  || no "EN3-e-partial: partial seeder → expected WARN about partial-progress count; got: $ERR_P"

# ─── EN3-f: seeder exit 0 + typed outcome (empty-input:) → empty=1, no absent-summary WARN ─
# RED before fix: SUT has no typed-outcome recognition — treats empty-input: as absent-summary
# → emits WARN and never increments empty counter.
# The real seeder exits 0 with empty-input: on ~50% of the fleet (retros with no delta section).
FKIT_F="$ROOT/fkit_f"
mkdir -p "$FKIT_F/toolbelt/lib"
cp "$HERE/../lib/block-files.sh"    "$FKIT_F/toolbelt/lib/"
cp "$HERE/../lib/retro-status.sh"   "$FKIT_F/toolbelt/lib/"
cp "$HERE/../lib/retro-grammar.sh"  "$FKIT_F/toolbelt/lib/"
cp "$HERE/../verify-retro.sh"       "$FKIT_F/toolbelt/"
cat > "$FKIT_F/toolbelt/stage-retro-issues.sh" << 'FABSEOF'
#!/usr/bin/env bash
# Models real seeder: retro has no delta section (empty-input path)
# Real seeder emits to stderr; gate captures 2>&1 — stream-agnostic.
printf 'empty-input: no delta section found in retro.md\n' >&2
exit 0
FABSEOF
chmod +x "$FKIT_F/toolbelt/stage-retro-issues.sh"
cp "$SUT" "$FKIT_F/toolbelt/retro-gate.sh"
TF="$ROOT/tf"; mkgit "$TF"; STFF="tf-sess"
mksessionfile "$TF" "$STFF" "202609050800"
mkblock "$TF" "tf-block1.md" "2026-09-05T10:00:00"
touch -t 202609051000 "$TF/tf-block1.md"
mkretro "$TF" "2026-09-05-tf.md" 1
touch -t 202609051200 "$TF/retros/2026-09-05-tf.md"
_jtf="$(mkjson "$STFF" "false")"
errf_tf="$ROOT/err_tf.$$"
printf '%s' "$_jtf" | PATH="$MOCK_GH_DIR:$PATH" \
  "$BASH_BIN" "$FKIT_F/toolbelt/retro-gate.sh" "$TF" >"$ROOT/out_tf.$$" 2>"$errf_tf"
ERR_F="$(cat "$errf_tf")"; rm -f "$errf_tf" "$ROOT/out_tf.$$"
# empty=1 in issue-seeding summary (typed outcome recognised, counter incremented)
printf '%s' "$ERR_F" | grep -q 'empty=1' \
  && ok "EN3-f: empty-input: typed outcome → empty=1 in issue-seeding summary" \
  || no "EN3-f: expected empty=1 in summary; got: $ERR_F"
# NO absent-summary WARN (typed outcome suppresses the WARN)
printf '%s' "$ERR_F" | grep -q 'WARN.*no summary' \
  && no "EN3-f: empty-input: must NOT trigger absent-summary WARN; got: $ERR_F" \
  || ok "EN3-f: empty-input: did not trigger absent-summary WARN (correct)"
# ran=1 in summary (seeder was called)
printf '%s' "$ERR_F" | grep -q 'ran=1' \
  && ok "EN3-f: ran=1 in issue-seeding summary (seeder was called)" \
  || no "EN3-f: expected ran=1 in summary; got: $ERR_F"

# ─── (EN3-unclassifiable) seeder exit 0 + typed outcome (unclassifiable:) → unclassifiable=1,
# typed loud non-fatal WARN, no generic "no summary: line" fallback WARN (kit issue #1129
# finding 1). Stub reproduces the REAL seeder's exact output shape for a real fleet retro
# (Pancaddia/corpus/retros/2026-09-22-monitor-jace-y-diagnostico-datos.md) — a Spanish-alias
# canonical section whose body is ### ABSORB sub-headings, not table rows.
# RED before fix: SUT's typed-outcome case only recognises empty-input:/no-match: — an
# unclassifiable: retro falls through to the generic "seeder exited 0 but no summary: line"
# WARN and is never counted. 15 real seedable fleet retros hit this on every Stop.
FKIT_U="$ROOT/fkit_u"
mkdir -p "$FKIT_U/toolbelt/lib"
cp "$HERE/../lib/block-files.sh"    "$FKIT_U/toolbelt/lib/"
cp "$HERE/../lib/retro-status.sh"   "$FKIT_U/toolbelt/lib/"
cp "$HERE/../lib/retro-grammar.sh"  "$FKIT_U/toolbelt/lib/"
cp "$HERE/../verify-retro.sh"       "$FKIT_U/toolbelt/"
cat > "$FKIT_U/toolbelt/stage-retro-issues.sh" << 'FUEOF'
#!/usr/bin/env bash
# Models the real seeder's exact output shape for an unclassifiable retro (kit issue #1111):
# a canonical/proposal-like section this parser cannot auto-stage issues from.
printf 'unclassifiable: delta section found but not in row-table form in retro.md — needs manual review, no issue auto-staged\n' >&2
exit 0
FUEOF
chmod +x "$FKIT_U/toolbelt/stage-retro-issues.sh"
cp "$SUT" "$FKIT_U/toolbelt/retro-gate.sh"
TU="$ROOT/tu"; mkgit "$TU"; STU="tu-sess"
mksessionfile "$TU" "$STU" "202609050800"
mkblock "$TU" "tu-block1.md" "2026-09-05T10:00:00"
touch -t 202609051000 "$TU/tu-block1.md"
mkretro "$TU" "2026-09-05-tu.md" 1
touch -t 202609051200 "$TU/retros/2026-09-05-tu.md"
_jtu="$(mkjson "$STU" "false")"
errf_u="$ROOT/err_u.$$"
printf '%s' "$_jtu" | PATH="$MOCK_GH_DIR:$PATH" \
  "$BASH_BIN" "$FKIT_U/toolbelt/retro-gate.sh" "$TU" >"$ROOT/out_u.$$" 2>"$errf_u"
ERR_U="$(cat "$errf_u")"; rm -f "$errf_u" "$ROOT/out_u.$$"
# unclassifiable=1 in issue-seeding summary (typed outcome recognised, counter incremented)
printf '%s' "$ERR_U" | grep -q 'unclassifiable=1' \
  && ok "EN3-unclassifiable: unclassifiable: typed outcome → unclassifiable=1 in issue-seeding summary" \
  || no "EN3-unclassifiable: expected unclassifiable=1 in summary; got: $ERR_U"
# A typed, loud, non-fatal WARN naming the retro (not the generic 'no summary: line' fallback)
printf '%s' "$ERR_U" | grep -q 'WARN: seeder: unclassifiable for.*needs manual review' \
  && ok "EN3-unclassifiable: typed loud WARN naming the retro (needs manual review)" \
  || no "EN3-unclassifiable: expected typed WARN naming the retro; got: $ERR_U"
# NO generic 'no summary: line' fallback WARN (typed outcome suppresses it)
printf '%s' "$ERR_U" | grep -q 'no summary: line' \
  && no "EN3-unclassifiable: must NOT trigger the generic 'no summary: line' WARN; got: $ERR_U" \
  || ok "EN3-unclassifiable: did not trigger the generic 'no summary: line' WARN (correct)"
# failed=0 — non-fatal, never counted as a create failure
printf '%s' "$ERR_U" | grep -q 'failed=0' \
  && ok "EN3-unclassifiable: non-fatal — failed=0 in summary" \
  || no "EN3-unclassifiable: expected failed=0 (non-fatal); got: $ERR_U"
# ran=1 in summary (seeder was called)
printf '%s' "$ERR_U" | grep -q 'ran=1' \
  && ok "EN3-unclassifiable: ran=1 in issue-seeding summary (seeder was called)" \
  || no "EN3-unclassifiable: expected ran=1 in summary; got: $ERR_U"

# ─── (EN3-absent) absent-input: typed outcome → absent=1, WARN naming retro ───
# Distinct from empty-input/no-match: retro file not found is a §7 absent-input signal.
# RED before fix: absent-input: is folded into empty=N with no WARN (issue #940).
FKIT_ABS="$ROOT/fkit_abs"
mkdir -p "$FKIT_ABS/toolbelt/lib"
cp "$HERE/../lib/block-files.sh"    "$FKIT_ABS/toolbelt/lib/"
cp "$HERE/../lib/retro-status.sh"   "$FKIT_ABS/toolbelt/lib/"
cp "$HERE/../lib/retro-grammar.sh"  "$FKIT_ABS/toolbelt/lib/"
cp "$HERE/../verify-retro.sh"       "$FKIT_ABS/toolbelt/"
# Stub: real seeder absent-input path (search: absent-input: retro not found)
# Real seeder emits to stderr; gate captures 2>&1 — stream-agnostic.
cat > "$FKIT_ABS/toolbelt/stage-retro-issues.sh" << 'ABSEOF'
#!/usr/bin/env bash
# Models real seeder: retro file not found (absent-input path)
printf 'absent-input: retro not found: retro.md\n' >&2
exit 1
ABSEOF
chmod +x "$FKIT_ABS/toolbelt/stage-retro-issues.sh"
cp "$SUT" "$FKIT_ABS/toolbelt/retro-gate.sh"
TABS="$ROOT/tabs"; mkgit "$TABS"; STABS="tabs-sess"
mksessionfile "$TABS" "$STABS" "202609050800"
mkblock "$TABS" "tabs-block1.md" "2026-09-05T10:00:00"
touch -t 202609051000 "$TABS/tabs-block1.md"
mkretro "$TABS" "2026-09-05-tabs.md" 1
touch -t 202609051200 "$TABS/retros/2026-09-05-tabs.md"
_jtabs="$(mkjson "$STABS" "false")"
errf_abs="$ROOT/err_abs.$$"
printf '%s' "$_jtabs" | PATH="$MOCK_GH_DIR:$PATH" \
  "$BASH_BIN" "$FKIT_ABS/toolbelt/retro-gate.sh" "$TABS" >"$ROOT/out_abs.$$" 2>"$errf_abs"
ERR_ABS="$(cat "$errf_abs")"; rm -f "$errf_abs" "$ROOT/out_abs.$$"
# absent=1 in issue-seeding summary (distinct from empty)
printf '%s' "$ERR_ABS" | grep -q 'absent=1' \
  && ok "EN3-absent: absent-input: typed outcome → absent=1 in issue-seeding summary" \
  || no "EN3-absent: expected absent=1 in summary; got: $ERR_ABS"
# empty=0 — must not be folded into empty counter
printf '%s' "$ERR_ABS" | grep -q 'empty=0' \
  && ok "EN3-absent: absent-input: does not increment empty counter (empty=0)" \
  || no "EN3-absent: expected empty=0 (not folded into empty); got: $ERR_ABS"
# failed=0 — absent-input seeder must NOT contribute to failed counter
printf '%s' "$ERR_ABS" | grep -q 'failed=0 ' \
  && ok "EN3-absent: absent-input: does not increment failed counter (failed=0)" \
  || no "EN3-absent: expected failed=0 (absent not counted as failed); got: $ERR_ABS"
# No per-retro seeder-failed WARN (only the absent-input WARN fires)
printf '%s' "$ERR_ABS" | grep -q 'WARN: seeder failed' \
  && no "EN3-absent: absent-input must NOT emit seeder-failed WARN; got: $ERR_ABS" \
  || ok "EN3-absent: absent-input: no seeder-failed WARN (correct)"
# Anchored WARN: must match the specific absent-input WARN line, not a reason line
printf '%s' "$ERR_ABS" | grep -qF 'WARN: seeder: absent-input for 2026-09-05-tabs.md' \
  && ok "EN3-absent: absent-input: typed outcome → WARN naming retro emitted" \
  || no "EN3-absent: expected 'WARN: seeder: absent-input for 2026-09-05-tabs.md'; got: $ERR_ABS"

# ─── (EN3-no-match) no-match: typed outcome → empty=1, no absent-input WARN ──
# Real seeder (search: STAGE_RETRO_ISSUES_NOMATCH_GUARD): emits no-match: to stderr
# AND summary: created=0 ... to stdout, rc 0 (all rows shipped).
# The summary branch must still detect no-match: and count it as empty.
FKIT_NM="$ROOT/fkit_nm"
mkdir -p "$FKIT_NM/toolbelt/lib"
cp "$HERE/../lib/block-files.sh"    "$FKIT_NM/toolbelt/lib/"
cp "$HERE/../lib/retro-status.sh"   "$FKIT_NM/toolbelt/lib/"
cp "$HERE/../lib/retro-grammar.sh"  "$FKIT_NM/toolbelt/lib/"
cp "$HERE/../verify-retro.sh"       "$FKIT_NM/toolbelt/"
# Stub: real seeder no-match path (search: STAGE_RETRO_ISSUES_NOMATCH_GUARD)
# Real seeder emits no-match: to stderr AND summary: to stdout; gate captures 2>&1.
cat > "$FKIT_NM/toolbelt/stage-retro-issues.sh" << 'NMEOF'
#!/usr/bin/env bash
# Models real seeder: all rows shipped (no-match path)
printf 'no-match: delta section found but all rows are shipped\n' >&2
printf 'summary: created=0 skipped-duplicate=0 skipped-shipped=1 skipped-wrong-kit=0 failed=0\n'
exit 0
NMEOF
chmod +x "$FKIT_NM/toolbelt/stage-retro-issues.sh"
cp "$SUT" "$FKIT_NM/toolbelt/retro-gate.sh"
TNM="$ROOT/tnm"; mkgit "$TNM"; STNM="tnm-sess"
mksessionfile "$TNM" "$STNM" "202609050800"
mkblock "$TNM" "tnm-block1.md" "2026-09-05T10:00:00"
touch -t 202609051000 "$TNM/tnm-block1.md"
mkretro "$TNM" "2026-09-05-tnm.md" 1
touch -t 202609051200 "$TNM/retros/2026-09-05-tnm.md"
_jtnm="$(mkjson "$STNM" "false")"
errf_nm="$ROOT/err_nm.$$"
printf '%s' "$_jtnm" | PATH="$MOCK_GH_DIR:$PATH" \
  "$BASH_BIN" "$FKIT_NM/toolbelt/retro-gate.sh" "$TNM" >"$ROOT/out_nm.$$" 2>"$errf_nm"
ERR_NM="$(cat "$errf_nm")"; rm -f "$errf_nm" "$ROOT/out_nm.$$"
# empty=1 in summary (no-match with summary: → empty counter via summary branch)
printf '%s' "$ERR_NM" | grep -q 'empty=1' \
  && ok "EN3-no-match: no-match: typed outcome → empty=1 in issue-seeding summary" \
  || no "EN3-no-match: expected empty=1 in summary; got: $ERR_NM"
# absent=0 — must not be counted as absent
printf '%s' "$ERR_NM" | grep -q 'absent=0' \
  && ok "EN3-no-match: no-match: does not increment absent counter (absent=0)" \
  || no "EN3-no-match: expected absent=0; got: $ERR_NM"
# no absent-input WARN
printf '%s' "$ERR_NM" | grep -q 'WARN.*absent-input' \
  && no "EN3-no-match: no-match must NOT trigger absent-input WARN; got: $ERR_NM" \
  || ok "EN3-no-match: no-match: did not trigger absent-input WARN (correct)"

# ─── (EN3-absent-summary-WARN) exit 0, no typed outcome, no summary → WARN ───
# Seeder exits 0 but prints nothing recognizable — §7 absent-summary WARN must fire.
# This is the fallback path distinct from the typed-outcome paths above.
FKIT_ASW="$ROOT/fkit_asw"
mkdir -p "$FKIT_ASW/toolbelt/lib"
cp "$HERE/../lib/block-files.sh"    "$FKIT_ASW/toolbelt/lib/"
cp "$HERE/../lib/retro-status.sh"   "$FKIT_ASW/toolbelt/lib/"
cp "$HERE/../lib/retro-grammar.sh"  "$FKIT_ASW/toolbelt/lib/"
cp "$HERE/../verify-retro.sh"       "$FKIT_ASW/toolbelt/"
cat > "$FKIT_ASW/toolbelt/stage-retro-issues.sh" << 'ASWEOF'
#!/usr/bin/env bash
# Seeder exits 0 but emits no typed outcome and no summary: line
printf 'some-unrecognised-output: doing things\n'
exit 0
ASWEOF
chmod +x "$FKIT_ASW/toolbelt/stage-retro-issues.sh"
cp "$SUT" "$FKIT_ASW/toolbelt/retro-gate.sh"
TASW="$ROOT/tasw"; mkgit "$TASW"; STASW="tasw-sess"
mksessionfile "$TASW" "$STASW" "202609050800"
mkblock "$TASW" "tasw-block1.md" "2026-09-05T10:00:00"
touch -t 202609051000 "$TASW/tasw-block1.md"
mkretro "$TASW" "2026-09-05-tasw.md" 1
touch -t 202609051200 "$TASW/retros/2026-09-05-tasw.md"
_jtasw="$(mkjson "$STASW" "false")"
errf_asw="$ROOT/err_asw.$$"
printf '%s' "$_jtasw" | PATH="$MOCK_GH_DIR:$PATH" \
  "$BASH_BIN" "$FKIT_ASW/toolbelt/retro-gate.sh" "$TASW" >"$ROOT/out_asw.$$" 2>"$errf_asw"
ERR_ASW="$(cat "$errf_asw")"; rm -f "$errf_asw" "$ROOT/out_asw.$$"
# WARN fires (exit 0 + no typed outcome + no summary = absent-summary WARN)
printf '%s' "$ERR_ASW" | grep -q 'WARN.*no summary' \
  && ok "EN3-absent-summary-WARN: exit 0, no typed outcome → absent-summary WARN fires" \
  || no "EN3-absent-summary-WARN: expected WARN 'no summary'; got: $ERR_ASW"
# Gate still allows (seeder exit 0)
printf '%s' "$ERR_ASW" | grep -q 'ran=1' \
  && ok "EN3-absent-summary-WARN: ran=1 in summary (seeder was called)" \
  || no "EN3-absent-summary-WARN: expected ran=1 in summary; got: $ERR_ASW"

# ─── (EN3-summary) Real seeder summary: format → created=1 parsed (#935) ─────
# RED before fix: SUT greps 'created issue' (never matches real 'created: <url>').
FKIT_SUM="$ROOT/fkit_sum"
mkdir -p "$FKIT_SUM/toolbelt/lib"
cp "$HERE/../lib/block-files.sh"    "$FKIT_SUM/toolbelt/lib/"
cp "$HERE/../lib/retro-status.sh"   "$FKIT_SUM/toolbelt/lib/"
cp "$HERE/../lib/retro-grammar.sh"  "$FKIT_SUM/toolbelt/lib/"
cp "$HERE/../verify-retro.sh"       "$FKIT_SUM/toolbelt/"
cat > "$FKIT_SUM/toolbelt/stage-retro-issues.sh" << 'SUMEOF'
#!/usr/bin/env bash
printf 'created: https://github.com/test/repo/issues/1 (row 1)\n'
printf 'summary: created=1 skipped-duplicate=0 skipped-shipped=0 skipped-wrong-kit=0\n'
exit 0
SUMEOF
chmod +x "$FKIT_SUM/toolbelt/stage-retro-issues.sh"
cp "$SUT" "$FKIT_SUM/toolbelt/retro-gate.sh"
TEN3SUM="$ROOT/en3sum"; mkgit "$TEN3SUM"; SIDEN3SUM="en3-sess-sum"
mksessionfile "$TEN3SUM" "$SIDEN3SUM" "202609050800"
mkblock "$TEN3SUM" "niagara-block1.md" "2026-09-05T10:00:00"
touch -t 202609051000 "$TEN3SUM/niagara-block1.md"
mkretro "$TEN3SUM" "2026-09-05-sum-test.md" 1
touch -t 202609051200 "$TEN3SUM/retros/2026-09-05-sum-test.md"
_jen3sum="$(mkjson "$SIDEN3SUM" "false")"
errf_sum="$ROOT/err_sum.$$"
OUT="$(printf '%s' "$_jen3sum" | PATH="$MOCK_GH_DIR:$PATH" \
  "$BASH_BIN" "$FKIT_SUM/toolbelt/retro-gate.sh" "$TEN3SUM" 2>"$errf_sum")"; RC=$?
ERR_SUM="$(cat "$errf_sum")"; rm -f "$errf_sum"
printf '%s' "$ERR_SUM" | grep -q 'created=1' && ok "EN3-summary: real summary: format → created=1 in issue-seeding" \
  || no "EN3-summary: expected created=1 from summary: parse; got: $ERR_SUM"

# ─── (EN3-ran) ran=N counter present in issue-seeding summary (#935) ─────────
# RED before fix: SUT has no ran= counter.
printf '%s' "$ERR_SUM" | grep -q 'ran=1' && ok "EN3-ran: ran=1 counter in issue-seeding summary" \
  || no "EN3-ran: expected ran=1 in summary; got: $ERR_SUM"

# ─── (EN3-reason) WARN reason = last non-progress line, not first (#935) ──────
# RED before fix: old head -1 returns the first line (a progress 'created:' line).
FKIT_RSN="$ROOT/fkit_rsn"
mkdir -p "$FKIT_RSN/toolbelt/lib"
cp "$HERE/../lib/block-files.sh"    "$FKIT_RSN/toolbelt/lib/"
cp "$HERE/../lib/retro-status.sh"   "$FKIT_RSN/toolbelt/lib/"
cp "$HERE/../lib/retro-grammar.sh"  "$FKIT_RSN/toolbelt/lib/"
cp "$HERE/../verify-retro.sh"       "$FKIT_RSN/toolbelt/"
cat > "$FKIT_RSN/toolbelt/stage-retro-issues.sh" << 'RSNEOF'
#!/usr/bin/env bash
# Progress line first (stdout), then error on stderr
printf 'created: https://github.com/test/repo/issues/1 (row 1)\n'
printf 'seeder: API quota exhausted after first issue\n' >&2
exit 1
RSNEOF
chmod +x "$FKIT_RSN/toolbelt/stage-retro-issues.sh"
cp "$SUT" "$FKIT_RSN/toolbelt/retro-gate.sh"
TEN3RSN="$ROOT/en3rsn"; mkgit "$TEN3RSN"; SIDEN3RSN="en3-sess-rsn"
mksessionfile "$TEN3RSN" "$SIDEN3RSN" "202609050800"
mkblock "$TEN3RSN" "niagara-block1.md" "2026-09-05T10:00:00"
touch -t 202609051000 "$TEN3RSN/niagara-block1.md"
mkretro "$TEN3RSN" "2026-09-05-rsn.md" 1
touch -t 202609051200 "$TEN3RSN/retros/2026-09-05-rsn.md"
_jen3rsn="$(mkjson "$SIDEN3RSN" "false")"
errf_rsn="$ROOT/err_rsn.$$"
OUT="$(printf '%s' "$_jen3rsn" | PATH="$MOCK_GH_DIR:$PATH" \
  "$BASH_BIN" "$FKIT_RSN/toolbelt/retro-gate.sh" "$TEN3RSN" 2>"$errf_rsn")"; RC=$?
ERR_RSN="$(cat "$errf_rsn")"; rm -f "$errf_rsn"
# New: WARN reason should be the last non-progress line ('API quota exhausted'), not 'created:'
printf '%s' "$ERR_RSN" | grep -qE 'WARN.*API quota' && ok "EN3-reason: WARN reason is last non-progress line" \
  || no "EN3-reason: expected 'API quota' as reason; got: $ERR_RSN"
printf '%s' "$ERR_RSN" | grep -qE 'WARN.*created:' && no "EN3-reason: WARN must NOT show progress line as reason" \
  || ok "EN3-reason: WARN does not show 'created:' as reason (correct)"

# ─── (EN3-944) PR #944 compat: summary with failed=N + exit 2 ────────────────
# Seeder exits 2 (partial failure) AND prints summary: with failed=N appended.
# retro-gate must parse failed= from summary and use the exact count (not +1).
# RED before fix: failed count from +1 fallback, not from summary parsing.
FKIT_944="$ROOT/fkit_944"
mkdir -p "$FKIT_944/toolbelt/lib"
cp "$HERE/../lib/block-files.sh"    "$FKIT_944/toolbelt/lib/"
cp "$HERE/../lib/retro-status.sh"   "$FKIT_944/toolbelt/lib/"
cp "$HERE/../lib/retro-grammar.sh"  "$FKIT_944/toolbelt/lib/"
cp "$HERE/../verify-retro.sh"       "$FKIT_944/toolbelt/"
cat > "$FKIT_944/toolbelt/stage-retro-issues.sh" << 'PR944EOF'
#!/usr/bin/env bash
# PR #944 format: summary includes failed=N; exit 2 on create failures
printf 'created: https://github.com/test/repo/issues/10 (row 1)\n'
printf 'summary: created=1 skipped-duplicate=0 skipped-shipped=0 skipped-wrong-kit=0 failed=3\n'
exit 2
PR944EOF
chmod +x "$FKIT_944/toolbelt/stage-retro-issues.sh"
cp "$SUT" "$FKIT_944/toolbelt/retro-gate.sh"
T944="$ROOT/t944"; mkgit "$T944"; ST944="t944-sess"
mksessionfile "$T944" "$ST944" "202609050800"
mkblock "$T944" "t944-block1.md" "2026-09-05T10:00:00"
touch -t 202609051000 "$T944/t944-block1.md"
mkretro "$T944" "2026-09-05-t944.md" 1
touch -t 202609051200 "$T944/retros/2026-09-05-t944.md"
_j944="$(mkjson "$ST944" "false")"
errf_944="$ROOT/err_944.$$"
printf '%s' "$_j944" | PATH="$MOCK_GH_DIR:$PATH" \
  "$BASH_BIN" "$FKIT_944/toolbelt/retro-gate.sh" "$T944" >"$ROOT/out_944.$$" 2>"$errf_944"
ERR_944="$(cat "$errf_944")"; rm -f "$errf_944" "$ROOT/out_944.$$"
# created=1 parsed from summary (not from progress lines)
printf '%s' "$ERR_944" | grep -q 'created=1' \
  && ok "EN3-944: PR #944 summary with failed=N → created=1 parsed correctly" \
  || no "EN3-944: expected created=1 from PR #944 summary; got: $ERR_944"
# failed=1 (retro count, not per-issue count) — one retro failed
printf '%s' "$ERR_944" | grep -qE 'failed=1( |$)' \
  && ok "EN3-944: PR #944 exit 2 → failed=1 (retro count, not per-issue 3)" \
  || no "EN3-944: expected failed=1 (retro count) in summary; got: $ERR_944"
# failed-issues=3 (per-issue count from summary)
printf '%s' "$ERR_944" | grep -q 'failed-issues=3' \
  && ok "EN3-944: PR #944 summary failed=3 → failed-issues=3 (per-issue count)" \
  || no "EN3-944: expected failed-issues=3 from summary parsing; got: $ERR_944"
# per-retro WARN still fires (exit 2 is a failure)
printf '%s' "$ERR_944" | grep -q 'WARN.*seeder failed' \
  && ok "EN3-944: exit 2 with summary → seeder-failed WARN still emitted" \
  || no "EN3-944: expected WARN for seeder exit 2; got: $ERR_944"
# aggregate WARN uses new format: 'N issue create(s) failed across M retro(s)'
# Use here-string to avoid printf|grep-q pipefail race (family #941/e727cde)
grep -q '3 issue create(s) failed across 1 retro(s)' <<< "$ERR_944" \
  && ok "EN3-944: aggregate WARN uses new format (issue count across retro count)" \
  || no "EN3-944: expected '3 issue create(s) failed across 1 retro(s)' in WARN; got: $ERR_944"
# Gate still allows (block/allow decision unaffected by seeder failure)
[ -z "$(printf '%s' "$_j944" | PATH="$MOCK_GH_DIR:$PATH" \
  "$BASH_BIN" "$FKIT_944/toolbelt/retro-gate.sh" "$T944" 2>/dev/null)" ] \
  && ok "EN3-944: exit 2 with summary → gate still allows (no block JSON)" \
  || no "EN3-944: exit 2 with summary → unexpected block JSON"

# ─── #957: retro-gate uses session-start sha scope, not file mtime ───────────
# mkretro_committed <target> <fname> <gdate>: create+commit a conforming retro
mkretro_committed() {
  local tgt="$1" fname="$2" gdate="$3"
  mkdir -p "$tgt/retros"
  printf '<!-- review-status: pending -->\n# Retro — test\n\n## Proposed kit deltas\n\n| # | change | target | evidence | type | priority |\n|---|---|---|---|---|---|\n| 1 | test delta | file.sh | evidence | fix | low |\n' \
    > "$tgt/retros/$fname"
  git -C "$tgt" add "retros/$fname"
  GIT_AUTHOR_DATE="$gdate" GIT_COMMITTER_DATE="$gdate" \
    git -C "$tgt" commit -q -m "add $fname"
}

# T-flip-957: old retro committed BEFORE session start; marker flipped (mtime bumped) after block.
# Pre-fix (mtime) allows because bumped-mtime > block-mtime.
# Post-fix (session-sha scope): git diff --diff-filter=A <session_sha>..HEAD finds no new retro;
# git ls-files --others finds nothing (retro is committed/tracked); blocks.
T_flip="$ROOT/t-flip957"; mkgit "$T_flip"; SID_flip="flip957-sess"
# Step 1: commit old retro with old git date
mkretro_committed "$T_flip" "2026-01-10-old-retro.md" "2026-01-10T00:00:00"
# Step 2: record session sha AFTER old retro commit (session diff range starts here)
mksessionfile "$T_flip" "$SID_flip" "202609050800"
# Step 3: commit block
mkblock "$T_flip" "niagara-block1.md" "2026-09-05T10:00:00"
# Step 4: set block mtime to 10:00
touch -t 202609051000 "$T_flip/niagara-block1.md"
# Step 5: bump old retro mtime to 12:00 — simulates marker flip; mtime > block mtime
touch -t 202609051200 "$T_flip/retros/2026-01-10-old-retro.md"
_j_flip="$(mkjson "$SID_flip" "false")"
run_gate "$T_flip" "$_j_flip"
printf '%s' "$OUT" | grep -qF '"decision":"block"' \
  && ok "#957 T-flip: old retro with bumped mtime → still blocks (session-sha scope, not mtime)" \
  || no "#957 T-flip: old retro with bumped mtime → should block but allowed — session-scope bypass"

# T-git-mv-957: old retro renamed (git mv) after session start → BLOCK.
# Pre-fix (mtime): renamed file's mtime is now > block mtime → allows (bypass).
# Post-fix (session-sha scope): rename has filter R not A; not in diff; ls-files --others
# returns nothing (tracked); no qualifying retro → blocks.  RED on pre-fix SUT.
T_gmv="$ROOT/t-gmv957"; mkgit "$T_gmv"; SID_gmv="gmv957-sess"
# Step 1: commit old retro before session start
mkretro_committed "$T_gmv" "2026-01-10-old-retro.md" "2026-01-10T00:00:00"
# Step 2: record session sha AFTER old retro commit
mksessionfile "$T_gmv" "$SID_gmv" "202609050800"
# Step 3: commit block
mkblock "$T_gmv" "niagara-block1.md" "2026-09-05T10:00:00"
touch -t 202609051000 "$T_gmv/niagara-block1.md"
# Step 4: rename old retro, commit rename — new name has recent mtime (now)
git -C "$T_gmv" mv retros/2026-01-10-old-retro.md retros/2026-09-23-renamed.md
GIT_AUTHOR_DATE="2026-09-23T12:00:00" GIT_COMMITTER_DATE="2026-09-23T12:00:00" \
  git -C "$T_gmv" commit -q -m "rename retro"
_j_gmv="$(mkjson "$SID_gmv" "false")"
run_gate "$T_gmv" "$_j_gmv"
printf '%s' "$OUT" | grep -qF '"decision":"block"' \
  && ok "#957 T-git-mv: renamed retro (git mv) → still blocks (rename=R not A in diff)" \
  || no "#957 T-git-mv: renamed retro → should block but allowed — rename bypass (pre-fix RED)"

# T-git-mv-diff-renames-false-984: same rename as T-git-mv above, but the TARGET repo has
# `diff.renames=false` configured. Without rename detection forced on, `git diff
# --diff-filter=A` (no -M) does NOT see the rename as R — with detection off, git reports the
# move as a plain D+A pair, and the Added half of that pair is indistinguishable from a
# genuinely new retro, so pre-fix the gate wrongly ALLOWS. Post-fix, -M forces rename
# detection regardless of diff.renames, so this repo's config must not change the outcome from
# T-git-mv above: still BLOCK. RED on pre-fix SUT (no -M): allows.
T_gmvdr="$ROOT/t-gmvdr984"; mkgit "$T_gmvdr"; SID_gmvdr="gmvdr984-sess"
git -C "$T_gmvdr" config diff.renames false
# Step 1: commit old retro before session start
mkretro_committed "$T_gmvdr" "2026-01-10-old-retro.md" "2026-01-10T00:00:00"
# Step 2: record session sha AFTER old retro commit
mksessionfile "$T_gmvdr" "$SID_gmvdr" "202609050800"
# Step 3: commit block
mkblock "$T_gmvdr" "niagara-block1.md" "2026-09-05T10:00:00"
touch -t 202609051000 "$T_gmvdr/niagara-block1.md"
# Step 4: rename old retro, commit rename — new name has recent mtime (now)
git -C "$T_gmvdr" mv retros/2026-01-10-old-retro.md retros/2026-09-23-renamed.md
GIT_AUTHOR_DATE="2026-09-23T12:00:00" GIT_COMMITTER_DATE="2026-09-23T12:00:00" \
  git -C "$T_gmvdr" commit -q -m "rename retro"
_j_gmvdr="$(mkjson "$SID_gmvdr" "false")"
run_gate "$T_gmvdr" "$_j_gmvdr"
printf '%s' "$OUT" | grep -qF '"decision":"block"' \
  && ok "#984 T-git-mv-diff-renames-false: renamed retro under diff.renames=false → still blocks (-M forces rename detection)" \
  || no "#984 T-git-mv-diff-renames-false: renamed retro under diff.renames=false → should block but allowed — config-dependent rename bypass (pre-fix RED)"

# T-new-committed-957: genuinely new retro committed AFTER the block →
# git diff --diff-filter=A <session_sha>..HEAD shows it; gate must allow.
T_new957="$ROOT/t-newc957"; mkgit "$T_new957"; SID_new957="newc957-sess"
mksessionfile "$T_new957" "$SID_new957" "202609050800"
mkblock "$T_new957" "niagara-block1.md" "2026-09-05T10:00:00"
touch -t 202609051000 "$T_new957/niagara-block1.md"
mkretro_committed "$T_new957" "2026-09-05-new-retro.md" "2026-09-05T12:00:00"
touch -t 202609051200 "$T_new957/retros/2026-09-05-new-retro.md"
_j_new957="$(mkjson "$SID_new957" "false")"
run_gate "$T_new957" "$_j_new957"
[ -z "$OUT" ] \
  && ok "#957 T-new-committed: new retro committed after block → allows (no block JSON)" \
  || no "#957 T-new-committed: new retro after block → should allow but blocked: $OUT"
grep -q 'retro-conforming' <<< "$ERR" \
  && ok "#957 T-new-committed: stderr shows retro-conforming branch" \
  || no "#957 T-new-committed: stderr missing 'retro-conforming': $ERR"

# T-untracked-new-957: new untracked retro newer than session file → ALLOW.
# Ensures ls-files --others + -nt check admits genuinely new untracked retros.
T_utr="$ROOT/t-utr957"; mkgit "$T_utr"; SID_utr="utr957-sess"
mksessionfile "$T_utr" "$SID_utr" "202609050800"
mkblock "$T_utr" "niagara-block1.md" "2026-09-05T10:00:00"
touch -t 202609051000 "$T_utr/niagara-block1.md"
mkretro "$T_utr" "2026-09-05-untracked.md" 1        # untracked (never committed)
touch -t 202609051200 "$T_utr/retros/2026-09-05-untracked.md"  # 12:00 > session 08:00
_j_utr="$(mkjson "$SID_utr" "false")"
run_gate "$T_utr" "$_j_utr"
[ -z "$OUT" ] \
  && ok "#957 T-untracked-new: untracked retro newer than session → allows (no block JSON)" \
  || no "#957 T-untracked-new: untracked retro → should allow but blocked: $OUT"

# T-same-commit-957: block and retro committed in same commit → ALLOW.
# git diff --diff-filter=A <session_sha>..HEAD -- retros/ shows retro as added.
T_sc="$ROOT/t-sc957"; mkgit "$T_sc"; SID_sc="sc957-sess"
mksessionfile "$T_sc" "$SID_sc"   # records init SHA (before block+retro)
printf '# Block\n\nContent.\n' > "$T_sc/niagara-block1.md"
mkretro "$T_sc" "2026-09-05-same-commit.md" 1
git -C "$T_sc" add -A
GIT_AUTHOR_DATE="2026-09-05T12:00:00" GIT_COMMITTER_DATE="2026-09-05T12:00:00" \
  git -C "$T_sc" commit -q -m "add block and retro together"
_j_sc="$(mkjson "$SID_sc" "false")"
run_gate "$T_sc" "$_j_sc"
[ -z "$OUT" ] \
  && ok "#957 T-same-commit: block+retro in same commit → allows (no block JSON)" \
  || no "#957 T-same-commit: block+retro same commit → should allow but blocked: $OUT"

# T-non-git-957: non-git target → degraded mtime fallback (origin/main behaviour).
# Block older than retro → allow; degraded WARN in stderr.
T_ng="$ROOT/t-ng957"
mkdir -p "$T_ng/retros"
printf '# Block\n\nContent.\n' > "$T_ng/niagara-block1.md"
touch -d '-2 hours' "$T_ng/niagara-block1.md"
mkretro "$T_ng" "2026-09-05-nongit.md" 1
touch -d '-1 hour' "$T_ng/retros/2026-09-05-nongit.md"   # retro newer than block
# No session file exists (non-git, session-start did not write sha)
_j_ng="$(mkjson "nongit-sess" "false")"
run_gate "$T_ng" "$_j_ng"
[ -z "$OUT" ] \
  && ok "#957 T-non-git: non-git target, retro newer than block → allows (mtime fallback)" \
  || no "#957 T-non-git: non-git target → should allow (mtime) but blocked: $OUT"
grep -q 'degraded\|no session' <<< "$ERR" \
  && ok "#957 T-non-git: degraded warning in stderr" \
  || no "#957 T-non-git: degraded warning missing from stderr: $ERR"

# T-staged-957: staged (not yet committed) retro → ALLOW.
# Ensures --cached flag admits retros that are in the index but not HEAD.
# RED on pre-fix SUT (which used sha..HEAD, not --cached): staged retro not found → blocks.
T_stg="$ROOT/t-stg957"; mkgit "$T_stg"; SID_stg="stg957-sess"
mksessionfile "$T_stg" "$SID_stg"   # records HEAD before block
mkblock "$T_stg" "niagara-block1.md" "2026-09-05T10:00:00"
touch -t 202609051000 "$T_stg/niagara-block1.md"
mkretro "$T_stg" "2026-09-05-staged.md" 1
git -C "$T_stg" add "retros/2026-09-05-staged.md"   # staged but NOT committed
_j_stg="$(mkjson "$SID_stg" "false")"
run_gate "$T_stg" "$_j_stg"
[ -z "$OUT" ] \
  && ok "#957 T-staged: staged retro → allows (no block JSON)" \
  || no "#957 T-staged: staged retro → should allow but blocked: $OUT"

# T-badsha-957: session file contains an unresolvable sha → degraded check → mtime fallback.
# On pre-fix SUT: degraded=0 (bad sha silently skips Part A only); git diff for retros fails
# (bad sha) → no qualifying retro → BLOCK.
# On new SUT: rev-parse -q --verify ${sha}^{commit} fails → degraded=1 + WARN → mtime fallback
# → retro newer than block → ALLOW.
T_bs="$ROOT/t-bs957"; mkgit "$T_bs"; SID_bs="bs957-sess"
mkdir -p "$T_bs/.claude"
printf '0123456789abcdef0123456789abcdef01234567\n' > "$T_bs/.claude/.rsdd-session-$SID_bs"
touch -t 202609050800 "$T_bs/.claude/.rsdd-session-$SID_bs"
mkblock "$T_bs" "niagara-block1.md" "2026-09-05T10:00:00"
touch -t 202609051000 "$T_bs/niagara-block1.md"
mkretro "$T_bs" "2026-09-05-badsha.md" 1
git -C "$T_bs" add "retros/2026-09-05-badsha.md"
GIT_AUTHOR_DATE="2026-09-05T12:00:00" GIT_COMMITTER_DATE="2026-09-05T12:00:00" \
  git -C "$T_bs" commit -q -m "add retro"
touch -t 202609051200 "$T_bs/retros/2026-09-05-badsha.md"   # retro mtime 12:00 > block 10:00
_j_bs="$(mkjson "$SID_bs" "false")"
run_gate "$T_bs" "$_j_bs"
[ -z "$OUT" ] \
  && ok "#957 T-badsha: unresolvable sha → degraded mtime fallback → allows" \
  || no "#957 T-badsha: unresolvable sha → should allow (mtime) but blocked: $OUT"
grep -q 'unresolvable\|degraded' <<< "$ERR" \
  && ok "#957 T-badsha: WARN about unresolvable sha in stderr" \
  || no "#957 T-badsha: WARN about unresolvable sha missing from stderr: $ERR"

# T-nest-957: retro committed under corpus/retros/ → ALLOW.
# Ensures the pathspec-free approach catches retros in nested directories.
# RED on pre-fix SUT (-- 'retros/' pathspec misses corpus/retros/): no qualifying retro → blocks.
T_nest="$ROOT/t-nest957"; mkgit "$T_nest"; SID_nest="nest957-sess"
mksessionfile "$T_nest" "$SID_nest"
mkdir -p "$T_nest/corpus"
printf '# Block — test\n\nContent.\n' > "$T_nest/corpus/niagara-block1.md"
git -C "$T_nest" add "corpus/niagara-block1.md"
GIT_AUTHOR_DATE="2026-09-05T10:00:00" GIT_COMMITTER_DATE="2026-09-05T10:00:00" \
  git -C "$T_nest" commit -q -m "add corpus block"
mkdir -p "$T_nest/corpus/retros"
printf '<!-- review-status: pending -->\n# Retro — test\n\n## Proposed kit deltas\n\n| # | change | target | evidence | type | priority |\n|---|---|---|---|---|---|\n| 1 | test delta | file.sh | evidence | fix | low |\n' \
  > "$T_nest/corpus/retros/2026-09-05-nested.md"
git -C "$T_nest" add "corpus/retros/2026-09-05-nested.md"
GIT_AUTHOR_DATE="2026-09-05T12:00:00" GIT_COMMITTER_DATE="2026-09-05T12:00:00" \
  git -C "$T_nest" commit -q -m "add nested retro"
_j_nest="$(mkjson "$SID_nest" "false")"
run_gate "$T_nest" "$_j_nest"
[ -z "$OUT" ] \
  && ok "#957 T-nest: retro in corpus/retros/ → allows (no block JSON)" \
  || no "#957 T-nest: retro in corpus/retros/ → should allow but blocked: $OUT"

# T-untracked-old-957: untracked retro OLDER than the session file → BLOCK.
# Accepted tradeoff: an untracked retro predating the session file does not qualify.
# The researcher must re-touch or commit it to qualify. Both pre- and post-fix block.
T_uto="$ROOT/t-uto957"; mkgit "$T_uto"; SID_uto="uto957-sess"
mkblock "$T_uto" "niagara-block1.md" "2026-09-05T10:00:00"
touch -t 202609051000 "$T_uto/niagara-block1.md"
# Create retro file with old mtime (2026-01-01) BEFORE writing session file
mkretro "$T_uto" "2026-01-01-old-untracked.md" 1
touch -t 202601010800 "$T_uto/retros/2026-01-01-old-untracked.md"
# Session file mtime 2026-09-05 08:00 > retro mtime 2026-01-01 08:00
mksessionfile "$T_uto" "$SID_uto" "202609050800"
_j_uto="$(mkjson "$SID_uto" "false")"
run_gate "$T_uto" "$_j_uto"
printf '%s' "$OUT" | grep -qF '"decision":"block"' \
  && ok "#957 T-untracked-old: untracked retro older than session → blocks (accepted tradeoff)" \
  || no "#957 T-untracked-old: untracked retro older than session → should block: OUT=$OUT"

# T-idx-only-957: only an INDEX.md added this session → BLOCK (not a qualifying retro).
# Index files are excluded by the case-insensitive basename guard.
T_idx="$ROOT/t-idx957"; mkgit "$T_idx"; SID_idx="idx957-sess"
mksessionfile "$T_idx" "$SID_idx"
mkblock "$T_idx" "niagara-block1.md" "2026-09-05T10:00:00"
mkdir -p "$T_idx/retros"
printf '# Index\n' > "$T_idx/retros/INDEX.md"
git -C "$T_idx" add "retros/INDEX.md"
GIT_AUTHOR_DATE="2026-09-05T12:00:00" GIT_COMMITTER_DATE="2026-09-05T12:00:00" \
  git -C "$T_idx" commit -q -m "add retros index"
_j_idx="$(mkjson "$SID_idx" "false")"
run_gate "$T_idx" "$_j_idx"
printf '%s' "$OUT" | grep -qF '"decision":"block"' \
  && ok "#957 T-idx-only: INDEX.md excluded from qualifying retros → blocks" \
  || no "#957 T-idx-only: INDEX.md should be excluded → expected block: OUT=$OUT"

# T-excluded-957: excluded retro (kit-retro: exclude marker) added this session → BLOCK.
# A retro with the opt-out marker is skipped by retro_is_excluded; gate must still block.
T_exc="$ROOT/t-exc957"; mkgit "$T_exc"; SID_exc="exc957-sess"
mksessionfile "$T_exc" "$SID_exc"
mkblock "$T_exc" "niagara-block1.md" "2026-09-05T10:00:00"
mkdir -p "$T_exc/retros"
printf '<!-- kit-retro: exclude -->\n# Client feedback — not a kit retro\n' \
  > "$T_exc/retros/2026-09-05-excluded.md"
git -C "$T_exc" add "retros/2026-09-05-excluded.md"
GIT_AUTHOR_DATE="2026-09-05T12:00:00" GIT_COMMITTER_DATE="2026-09-05T12:00:00" \
  git -C "$T_exc" commit -q -m "add excluded retro"
_j_exc="$(mkjson "$SID_exc" "false")"
run_gate "$T_exc" "$_j_exc"
printf '%s' "$OUT" | grep -qF '"decision":"block"' \
  && ok "#957 T-excluded: excluded retro (kit-retro: exclude) → still blocks" \
  || no "#957 T-excluded: excluded retro should not qualify → expected block: OUT=$OUT"

# ─── _retro_is_seedable — direct unit tests (kit issues #945, #1093 item 3) ──────────────────
# retro-gate.sh is a Stop-hook script, not meant to be sourced (it reads stdin and acts on argv
# at top level), so _retro_is_seedable is extracted with sed and evaluated in a subshell that
# also sources the real lib/retro-status.sh it now depends on — the same shared scope + PARTIAL
# logic reconcile-issues.sh, stage-retro-issues.sh, and sweep-retros.sh use.
RS_LIB="$HERE/../lib/retro-status.sh"
[ -f "$RS_LIB" ] || { echo "FATAL: lib/retro-status.sh not found: $RS_LIB" >&2; exit 2; }

# _seedable_check <retro-file> → prints 'seedable' or 'not-seedable'
_seedable_check() {
  "$BASH_BIN" -c '
    . "$1"
    _rs_func="$(sed -n "/^_retro_is_seedable() {/,/^}/p" "$2")"
    eval "$_rs_func"
    if _retro_is_seedable "$3"; then echo seedable; else echo not-seedable; fi
  ' _ "$RS_LIB" "$SUT" "$1"
}

# T-SEEDABLE-1 (kit issue #1093 item 3 — real disagreement example): 'applied · sha ·
# shipped: row 1' with NO literal PARTIAL token. The seeder (stage-retro-issues.sh, via
# retro_marker_is_partial) already treats this as PARTIAL (some rows still open); the old
# _retro_is_seedable only matched a literal '*PARTIAL*' substring, so the two tools disagreed —
# unshipped rows in this shape were never auto-seeded by the Stop hook. RED against origin/main:
# not-seedable.
f1="$ROOT/seedable-shipped-no-partial.md"
printf '<!-- review-status: applied 2026-09-16 · kit 9ac10e4 · shipped: row 1 -->\n# retro\n' > "$f1"
[ "$(_seedable_check "$f1")" = "seedable" ] \
  && ok "T-SEEDABLE-1 'shipped:' without PARTIAL token → seedable (#1093 item 3)" "()" \
  || no "T-SEEDABLE-1 'shipped:' without PARTIAL token → seedable (#1093 item 3)" "(got not-seedable)"

# T-SEEDABLE-2: dismissed always wins → not seedable.
f2="$ROOT/seedable-dismissed.md"
printf '<!-- review-status: dismissed 2026-09-16 · kit 9ac10e4 -->\n# retro\n' > "$f2"
[ "$(_seedable_check "$f2")" = "not-seedable" ] \
  && ok "T-SEEDABLE-2 dismissed → not seedable" "()" \
  || no "T-SEEDABLE-2 dismissed → not seedable" "(got seedable)"

# T-SEEDABLE-3 (kit issue #945): H1 + blank + marker (real niagara-research *-closure.md shape),
# applied with no PARTIAL/shipped → not seedable, matching the seeder's reading of the same shape.
f3="$ROOT/seedable-h1-applied.md"
printf '# §18 Retro — focus: apis\n\n<!-- review-status: applied 2026-09-24 · kit c10f9d9 -->\n' > "$f3"
[ "$(_seedable_check "$f3")" = "not-seedable" ] \
  && ok "T-SEEDABLE-3 H1 + blank + applied marker → not seedable (#945 real-corpus shape)" "()" \
  || no "T-SEEDABLE-3 H1 + blank + applied marker → not seedable (#945 real-corpus shape)" "(got seedable)"

# T-SEEDABLE-4 (kit issue #945 scope narrowing, SUPERSEDED by #1099 fail-closed): a
# properly-anchored 'dismissed' marker sitting after a SECOND heading — unrelated to the
# leading-block-plus-one-H1 shape — is out of retro_marker_scope_line's scope. Between #945 and
# #1099 this was (correctly, per #945) read as "no marker at all" and therefore seedable — but
# that shared "absent" reading was ALSO the exact fail-open shape #1099 closes: an out-of-scope
# marker (whatever word it carries) is no longer silently treated as absent. #1099 makes this
# refuse to seed instead, exactly like an out-of-scope 'applied' marker (T-SEEDABLE-6) — the
# marker's word no longer matters once it is out of scope.
f4="$ROOT/seedable-deep-dismissed.md"
printf '# retro\n\n## Notes\n\n<!-- review-status: dismissed -->\n' > "$f4"
[ "$(_seedable_check "$f4")" = "not-seedable" ] \
  && ok "T-SEEDABLE-4 dismissed marker after a SECOND heading → out-of-scope, not seedable (#945→#1099)" "()" \
  || no "T-SEEDABLE-4 dismissed marker after a SECOND heading → out-of-scope, not seedable (#945→#1099)" "(got seedable)"

# T-SEEDABLE-5: no marker at all → seedable.
f5="$ROOT/seedable-none.md"
printf '# retro\n\nno marker\n' > "$f5"
[ "$(_seedable_check "$f5")" = "seedable" ] \
  && ok "T-SEEDABLE-5 no marker at all → seedable" "()" \
  || no "T-SEEDABLE-5 no marker at all → seedable" "(got not-seedable)"

# T-SEEDABLE-6 (kit issue #1099): a marker positioned deep in the body — after a SECOND heading —
# is OUT OF SCOPE. Before #1099 this was silently conflated with "no marker at all" and read as
# seedable (fail-open shape that produced #1048-#1089). #1099 makes this fail CLOSED: not
# seedable — refuse until the marker is moved into the leading block.
f6="$ROOT/seedable-out-of-scope.md"
printf '# retro\n\n## Notes\n\n<!-- review-status: applied 2026-01-01 -->\n' > "$f6"
[ "$(_seedable_check "$f6")" = "not-seedable" ] \
  && ok "T-SEEDABLE-6 marker after a SECOND heading (out-of-scope) → not seedable (#1099)" "()" \
  || no "T-SEEDABLE-6 marker after a SECOND heading (out-of-scope) → not seedable (#1099)" "(got seedable)"

# T-SEEDABLE-7 (kit issue #1099, §7 list edges): out-of-scope marker as the LAST line, no
# trailing newline — the exact shape of verify-registry.sh's last-field bug.
f7="$ROOT/seedable-oos-last.md"
printf '# retro\n\n## Notes\n\n<!-- review-status: applied 2026-01-01 -->' > "$f7"
[ "$(_seedable_check "$f7")" = "not-seedable" ] \
  && ok "T-SEEDABLE-7 out-of-scope marker, LAST line no trailing newline → not seedable (#1099)" "()" \
  || no "T-SEEDABLE-7 out-of-scope marker, LAST line no trailing newline → not seedable (#1099)" "(got seedable)"

# T-SEEDABLE-PFX (kit issue #1130 finding 4/item 5): full end-to-end run of the REAL retro-gate.sh
# against a real out-of-scope-marker retro — the WARN retro-gate.sh itself prints must lead with
# the literal 'out-of-scope-marker: ' token (colon, no other word), the SAME shape
# stage-retro-issues.sh and reconcile-issues.sh already use. Before this fix the wording was
# 'out-of-scope-marker for <file>' (no colon, "for" instead).
TPFX="$ROOT/tpfx"; mkgit "$TPFX"; STPFX="tpfx-sess"
mksessionfile "$TPFX" "$STPFX" "202609050800"
mkblock "$TPFX" "tpfx-block1.md" "2026-09-05T10:00:00"
touch -t 202609051000 "$TPFX/tpfx-block1.md"
mkdir -p "$TPFX/retros"
# _run_issue_seeding scans EVERY retro under retros/, but the block/allow DECISION only
# verify-retro-checks the NEWEST-by-mtime retro. Two files: an OLDER one (out-of-scope marker,
# T-SEEDABLE-6's shape) that _retro_is_seedable must refuse during seeding, and a NEWER,
# fully-conforming one (in-scope pending marker) so retro-gate reaches the allow/retro-conforming
# branch and actually calls _run_issue_seeding.
printf '# Retro — test\n\n## Notes\n\n<!-- review-status: applied 2026-01-01 -->\n\n## Proposed kit deltas\n\n| # | change | target | evidence | type | priority |\n|---|---|---|---|---|---|\n| 1 | test delta | file.sh | evidence | fix | low |\n' \
  > "$TPFX/retros/2026-09-04-tpfx-oos.md"
touch -t 202609051100 "$TPFX/retros/2026-09-04-tpfx-oos.md"
mkretro "$TPFX" "2026-09-05-tpfx.md" 1
touch -t 202609051200 "$TPFX/retros/2026-09-05-tpfx.md"
# kit issue #1130 CI follow-up: _run_issue_seeding probes for `gh` BEFORE it ever reaches the
# per-retro loop (and therefore before _retro_is_seedable's out-of-scope check) — without a
# stubbed gh on PATH, it prints 'gh not found — issue-seeding skipped' and returns immediately,
# so the out-of-scope-marker WARN never fires at all. Hermetic: use the shared MOCK_GH_DIR stub
# (auth status/other calls both exit 0), the SAME convention every other gh-dependent invocation
# in this file already uses (run_gate has no PATH hook, so this bypasses it deliberately).
errf_tpfx="$ROOT/err_tpfx.$$"
OUT="$(printf '%s' "$(mkjson "$STPFX" false)" | PATH="$MOCK_GH_DIR:$PATH" "$BASH_BIN" "$SUT" "$TPFX" 2>"$errf_tpfx")"; RC=$?
ERR="$(cat "$errf_tpfx")"; rm -f "$errf_tpfx"
if printf '%s' "$ERR" | grep -q 'retro-gate: WARN: out-of-scope-marker: '; then
  ok "T-SEEDABLE-PFX: real retro-gate.sh WARN leads with the literal 'out-of-scope-marker:' token" "()"
else
  no "T-SEEDABLE-PFX: expected 'retro-gate: WARN: out-of-scope-marker: ' in stderr" "got: $ERR"
fi

# ─── #1223: nested worktree copies are not research files ────────────────────
# A Claude Code agent worktree under <target>/.claude/worktrees/<name>/ carries a full checkout
# of the corpus, so every block in it looks like a "changed research file" (and every retro
# like a candidate retro). Evidence (niagara-research, kit issue #1223): the Stop hook blocked
# on .claude/worktrees/agent-*/niagara-mental-model-bloque*.md copies although no real block of
# the target changed. Real nested `git worktree add` checkouts elsewhere under the target
# (proven by the gitdir's commondir file AND its back-pointer to the .git file, never by the gitdir
# text — see lib/block-files.sh) are excluded the same way.

# mkwtcopy <target> <reldir> <fname>: untracked block file inside a nested worktree dir.
mkwtcopy() {
  mkdir -p "$1/$2"
  printf '# Block — worktree copy\n\nContent.\n' > "$1/$2/$3"
}

# W1 (ONLY entry): the worktree copy is the only changed research file → ALLOW (no-change).
T_w1="$ROOT/t-w1"; mkgit "$T_w1"; SID_w1="w1-sess"
mksessionfile "$T_w1" "$SID_w1" "202609050800"
mkwtcopy "$T_w1" ".claude/worktrees/agent-x" "niagara-mental-model-bloque1.md"
run_gate "$T_w1" "$(mkjson "$SID_w1" false)"
[ -z "$OUT" ] \
  && ok "#1223 W1: only a .claude/worktrees copy changed → allows (no block JSON)" \
  || no "#1223 W1: .claude/worktrees copy must not count as a changed research file: $OUT"
printf '%s' "$ERR" | grep -q 'branch=no-change' \
  && ok "#1223 W1: stderr says branch=no-change" \
  || no "#1223 W1: expected branch=no-change, got: $ERR"

# W2 (FIRST and LAST positions): worktree copies on both sides of a REAL changed block — the
# real block must still be seen (the exclusion must not swallow the whole scan) → BLOCK.
T_w2="$ROOT/t-w2"; mkgit "$T_w2"; SID_w2="w2-sess"
mksessionfile "$T_w2" "$SID_w2" "202609050800"
mkwtcopy "$T_w2" ".claude/worktrees/aaa-first" "niagara-block1.md"
mkblock "$T_w2" "niagara-block2.md" "2026-09-05T10:00:00"
mkwtcopy "$T_w2" ".claude/worktrees/zzz-last" "niagara-block3.md"
run_gate "$T_w2" "$(mkjson "$SID_w2" false)"
printf '%s' "$OUT" | grep -qF '"decision":"block"' \
  && ok "#1223 W2: real block changed beside worktree copies → still blocks" \
  || no "#1223 W2: real block change must still block: OUT=$OUT ERR=$ERR"

# W3: a REAL nested `git worktree add` checkout (not under .claude/) is excluded too.
T_w3="$ROOT/t-w3"; mkgit "$T_w3"; SID_w3="w3-sess"
mksessionfile "$T_w3" "$SID_w3" "202609050800"
git -C "$T_w3" worktree add -q "$T_w3/side-wt" -b side-w3
printf '# Block — in a real worktree\n' > "$T_w3/side-wt/niagara-block1.md"
if [ -f "$T_w3/side-wt/.git" ] && grep -q 'gitdir:.*/worktrees/' "$T_w3/side-wt/.git"; then
  ok "PRECOND(#1223 W3): fixture is a real git worktree (.git file → gitdir …/worktrees/…)"
else
  no "PRECOND(#1223 W3): fixture is not a real git worktree — test would prove nothing"
fi
run_gate "$T_w3" "$(mkjson "$SID_w3" false)"
[ -z "$OUT" ] \
  && ok "#1223 W3: block inside a real nested git worktree → allows" \
  || no "#1223 W3: nested git worktree copy must not count: $OUT"

# W3b: a nested git CLONE (.git is a directory) and a submodule-style .git file are NOT
# worktrees — their research files are still the target's business → BLOCK. Guards against
# over-broad exclusion ("any dir with a .git entry").
T_w3b="$ROOT/t-w3b"; mkgit "$T_w3b"; SID_w3b="w3b-sess"
mksessionfile "$T_w3b" "$SID_w3b" "202609050800"
mkdir -p "$T_w3b/clone/.git"
printf '# Block\n' > "$T_w3b/clone/niagara-block1.md"
run_gate "$T_w3b" "$(mkjson "$SID_w3b" false)"
printf '%s' "$OUT" | grep -qF '"decision":"block"' \
  && ok "#1223 W3b: block in a nested clone (.git dir) still counts → blocks" \
  || no "#1223 W3b: nested clone must not be excluded: OUT=$OUT ERR=$ERR"
T_w3c="$ROOT/t-w3c"; mkgit "$T_w3c"; SID_w3c="w3c-sess"
mksessionfile "$T_w3c" "$SID_w3c" "202609050800"
mkdir -p "$T_w3c/sub"
printf 'gitdir: ../.git/modules/sub\n' > "$T_w3c/sub/.git"
printf '# Block\n' > "$T_w3c/sub/niagara-block1.md"
run_gate "$T_w3c" "$(mkjson "$SID_w3c" false)"
printf '%s' "$OUT" | grep -qF '"decision":"block"' \
  && ok "#1223 W3c: block under a submodule-style .git file still counts → blocks" \
  || no "#1223 W3c: submodule must not be excluded: OUT=$OUT ERR=$ERR"

# W4 (degraded mtime mode): a worktree copy newer than the retro made the retro look stale.
T_w4="$ROOT/t-w4"
mkdir -p "$T_w4/retros"
printf '# Block\n\nContent.\n' > "$T_w4/niagara-block1.md"
touch -d '-3 hours' "$T_w4/niagara-block1.md"
mkretro "$T_w4" "2026-09-05-w4.md" 1
touch -d '-2 hours' "$T_w4/retros/2026-09-05-w4.md"
mkwtcopy "$T_w4" ".claude/worktrees/agent-x" "niagara-block1.md"   # newest file in the target
run_gate "$T_w4" "$(mkjson "w4-sess" false)"
[ -z "$OUT" ] \
  && ok "#1223 W4: degraded — newer .claude/worktrees copy does not make the retro stale → allows" \
  || no "#1223 W4: degraded mode counted a worktree copy as the newest block: $OUT"

# W5: a retro that exists ONLY inside a nested worktree does not qualify → BLOCK.
T_w5="$ROOT/t-w5"; mkgit "$T_w5"; SID_w5="w5-sess"
mksessionfile "$T_w5" "$SID_w5" "202609050800"
mkblock "$T_w5" "niagara-block1.md" "2026-09-05T10:00:00"
touch -t 202609051000 "$T_w5/niagara-block1.md"
mkretro "$T_w5/.claude/worktrees/agent-x" "2026-09-05-w5.md" 1
touch -t 202609051200 "$T_w5/.claude/worktrees/agent-x/retros/2026-09-05-w5.md"
run_gate "$T_w5" "$(mkjson "$SID_w5" false)"
printf '%s' "$OUT" | grep -qF '"decision":"block"' \
  && ok "#1223 W5: a retro only inside .claude/worktrees does not qualify → blocks" \
  || no "#1223 W5: worktree-only retro was accepted as the retro: OUT=$OUT ERR=$ERR"

# W6: issue seeding must not seed a retro that lives in a nested git worktree.
T_w6="$ROOT/t-w6"; mkgit "$T_w6"; SID_w6="w6-sess"
mksessionfile "$T_w6" "$SID_w6" "202609050800"
mkblock "$T_w6" "niagara-block1.md" "2026-09-05T10:00:00"
touch -t 202609051000 "$T_w6/niagara-block1.md"
mkretro "$T_w6" "2026-09-05-real.md" 1
touch -t 202609051200 "$T_w6/retros/2026-09-05-real.md"
git -C "$T_w6" worktree add -q "$T_w6/side-wt" -b side-w6
mkretro "$T_w6/side-wt" "2026-09-05-wtcopy.md" 1
: > "$SEED_LOG_EN3"
run_fkit_gate "$T_w6" "$(mkjson "$SID_w6" false)"
if grep -q '2026-09-05-real.md' "$SEED_LOG_EN3"; then
  ok "PRECOND(#1223 W6): the real retro was seeded (seeding ran)"
else
  no "PRECOND(#1223 W6): real retro not seeded — fixture broken: ERR=$ERR"
fi
if grep -q 'wtcopy' "$SEED_LOG_EN3"; then
  no "#1223 W6: a retro inside a nested git worktree was seeded: $(cat "$SEED_LOG_EN3")"
else
  ok "#1223 W6: nested-worktree retro is not seeded"
fi

# W7 (degraded): the only retro is inside a nested worktree (marker .git file at depth 1 so
# the maxdepth-4 retro scan reaches it) → treated as "no retro" → BLOCK.
T_w7="$ROOT/t-w7"
mkdir -p "$T_w7/side-wt"
mkdir -p "$T_w7/.fakegit/worktrees/side-wt"; : > "$T_w7/.fakegit/worktrees/side-wt/commondir"   # a linked worktree's gitdir has commondir
printf 'gitdir: %s/.fakegit/worktrees/side-wt\n' "$T_w7" > "$T_w7/side-wt/.git"
printf '%s/side-wt/.git\n' "$T_w7" > "$T_w7/.fakegit/worktrees/side-wt/gitdir"   # the back-pointer (#1301)
printf '# Block\n' > "$T_w7/niagara-block1.md"; touch -d '-3 hours' "$T_w7/niagara-block1.md"
mkretro "$T_w7/side-wt" "2026-09-05-w7.md" 1;     touch -d '-1 hour' "$T_w7/side-wt/retros/2026-09-05-w7.md"
run_gate "$T_w7" "$(mkjson "w7-sess" false)"
printf '%s' "$OUT" | grep -qF '"decision":"block"' \
  && ok "#1223 W7: degraded — a retro only inside a nested worktree does not qualify → blocks" \
  || no "#1223 W7: degraded scan accepted a worktree retro: OUT=$OUT ERR=$ERR"

# W8 (session-sha mode, COMMITTED path): a retro force-added under .claude/worktrees/ since the
# session start must not qualify either → BLOCK.
T_w8="$ROOT/t-w8"; mkgit "$T_w8"; SID_w8="w8-sess"
mksessionfile "$T_w8" "$SID_w8" "202609050800"
mkblock "$T_w8" "niagara-block1.md" "2026-09-05T10:00:00"
mkretro "$T_w8/.claude/worktrees/agent-x" "2026-09-05-w8.md" 1
git -C "$T_w8" add -f ".claude/worktrees/agent-x/retros/2026-09-05-w8.md"
GIT_AUTHOR_DATE="2026-09-05T12:00:00" GIT_COMMITTER_DATE="2026-09-05T12:00:00" \
  git -C "$T_w8" commit -q -m "force-add worktree retro"
run_gate "$T_w8" "$(mkjson "$SID_w8" false)"
printf '%s' "$OUT" | grep -qF '"decision":"block"' \
  && ok "#1223 W8: a committed retro under .claude/worktrees does not qualify → blocks" \
  || no "#1223 W8: committed worktree retro was accepted: OUT=$OUT ERR=$ERR"

# W9 (review of PR #1300, B1): the target is ITSELF a linked worktree (the kit's normal agent
# layout) and carries a submodule whose gitdir is <main>/.git/worktrees/<wt>/modules/notes. That
# text contains "/worktrees/" but it is a submodule, not a worktree: a block changed only inside
# it must still BLOCK (a false ALLOW silently skips the retro).
W9_SRC="$ROOT/w9-subsrc"; W9_MAIN="$ROOT/w9-main"; T_w9="$ROOT/w9-wt"; SID_w9="w9-sess"
_w9g() { git -c protocol.file.allow=always -c user.email=t@e.com -c user.name=t -c init.defaultBranch=main "$@" >/dev/null 2>&1; }
mkdir -p "$W9_SRC" "$W9_MAIN"
_w9g -C "$W9_SRC" init -q; : > "$W9_SRC/f"; _w9g -C "$W9_SRC" add f; _w9g -C "$W9_SRC" commit -q -m i
_w9g -C "$W9_MAIN" init -q; : > "$W9_MAIN/.keep"; _w9g -C "$W9_MAIN" add .keep; _w9g -C "$W9_MAIN" commit -q -m i
_w9g -C "$W9_MAIN" submodule add "file://$W9_SRC" notes; _w9g -C "$W9_MAIN" commit -q -m sub
_w9g -C "$W9_MAIN" worktree add "$T_w9" -b w9b
_w9g -C "$T_w9" submodule update --init
mksessionfile "$T_w9" "$SID_w9" "202609050800"
printf '# Block\n' > "$T_w9/notes/niagara-block1.md"
if [ -f "$T_w9/notes/.git" ] && grep -q '/worktrees/' "$T_w9/notes/.git"; then
  ok "PRECOND(#1223 W9): fixture submodule gitdir contains /worktrees/ (the look-alike shape)"
else
  no "PRECOND(#1223 W9): fixture lacks the /worktrees/ look-alike submodule gitdir: $(cat "$T_w9/notes/.git" 2>&1)"
fi
run_gate "$T_w9" "$(mkjson "$SID_w9" false)"
printf '%s' "$OUT" | grep -qF '"decision":"block"' \
  && ok "#1223 W9: block changed inside a submodule of a linked-worktree target → still blocks" \
  || no "#1223 W9: submodule treated as a nested worktree (false ALLOW): OUT=$OUT ERR=$ERR"

# W10 (#1301 item 2): a `.git` FILE reading `gitdir: .` plus a stray `commondir` in the same dir
# passed the commondir proof, so the block beside it was dropped as a "worktree copy" (false
# ALLOW). git writes a back-pointer <gitdir>/gitdir for every linked worktree; with none, the
# directory is not a proven worktree and its research files count → BLOCK.
T_w10="$ROOT/t-w10"; mkgit "$T_w10"; SID_w10="w10-sess"
mksessionfile "$T_w10" "$SID_w10" "202609050800"
mkdir -p "$T_w10/fake"; : > "$T_w10/fake/commondir"; printf 'gitdir: .\n' > "$T_w10/fake/.git"
printf '# Block\n' > "$T_w10/fake/niagara-block1.md"
run_gate "$T_w10" "$(mkjson "$SID_w10" false)"
printf '%s' "$OUT" | grep -qF '"decision":"block"' \
  && ok "#1301 W10: 'gitdir: .' + stray commondir is not a worktree → block beside it still counts" \
  || no "#1301 W10: contrived gitdir treated as a linked worktree (false ALLOW): OUT=$OUT ERR=$ERR"
# W10b: commondir present, back-pointer file ABSENT (e.g. a half-pruned worktree) → still counts.
T_w10b="$ROOT/t-w10b"; mkgit "$T_w10b"; SID_w10b="w10b-sess"
mksessionfile "$T_w10b" "$SID_w10b" "202609050800"
mkdir -p "$T_w10b/side" "$T_w10b/.fakegit/wt"; : > "$T_w10b/.fakegit/wt/commondir"
printf 'gitdir: %s/.fakegit/wt\n' "$T_w10b" > "$T_w10b/side/.git"
printf '# Block\n' > "$T_w10b/side/niagara-block1.md"
run_gate "$T_w10b" "$(mkjson "$SID_w10b" false)"
printf '%s' "$OUT" | grep -qF '"decision":"block"' \
  && ok "#1301 W10b: worktree gitdir without a back-pointer is unprovable → its block still counts" \
  || no "#1301 W10b: back-pointer-less gitdir treated as a worktree (false ALLOW): OUT=$OUT ERR=$ERR"
# #1311 item 1: the back-pointer read of a commondir-without-gitdir directory is a decision, not an
# error — the shell's own "No such file or directory" must not leak into the Stop hook's stderr.
printf '%s' "$ERR" | grep -qi 'no such file' \
  && no "#1311 W10b-stderr: back-pointer read leaked to stderr: $ERR" \
  || ok "#1311 W10b-stderr: missing <gitdir>/gitdir emits nothing to stderr"

# ─── #1311 item 3: a DIRECTORY SYMLINK inside the target (session mode) ──────
# git tracks `corpus -> ../ext` as a blob (no .md suffix) and `find -H` never descends into a link
# met while walking, so research changed THROUGH the link was invisible → false ALLOW. The gate now
# scans each directory symlink under the target one hop deep (no -L: no loops, no double walks).
# S1: block changed through a directory symlink → BLOCK. Control: the same block in-tree blocks.
S1_EXT="$ROOT/s1-ext"; mkdir -p "$S1_EXT"; printf '# Block\n' > "$S1_EXT/niagara-block1.md"
T_s1="$ROOT/t-s1"; mkgit "$T_s1"; SID_s1="s1-sess"
mksessionfile "$T_s1" "$SID_s1" "202609050800"
ln -s "$S1_EXT" "$T_s1/corpus"
run_gate "$T_s1" "$(mkjson "$SID_s1" false)"
printf '%s' "$OUT" | grep -qF '"decision":"block"' \
  && ok "#1311 S1: block changed through a directory symlink → blocks (no false ALLOW)" \
  || no "#1311 S1: symlinked research dir false ALLOW: OUT=$OUT ERR=$ERR"
# S2: the link target holds only research OLDER than the session start → nothing changed → ALLOW.
S2_EXT="$ROOT/s2-ext"; mkdir -p "$S2_EXT"; printf '# Block\n' > "$S2_EXT/niagara-block1.md"
touch -t 202609040800 "$S2_EXT/niagara-block1.md"
T_s2="$ROOT/t-s2"; mkgit "$T_s2"; SID_s2="s2-sess"
mksessionfile "$T_s2" "$SID_s2" "202609050800"
ln -s "$S2_EXT" "$T_s2/corpus"
run_gate "$T_s2" "$(mkjson "$SID_s2" false)"
printf '%s' "$OUT" | grep -qF '"decision":"block"' \
  && no "#1311 S2: unchanged symlinked research blocked (over-block): OUT=$OUT" \
  || ok "#1311 S2: unchanged research behind a directory symlink does not block"
# S3: a symlink back to its own ancestor (a loop) terminates and, with nothing changed, allows.
T_s3="$ROOT/t-s3"; mkgit "$T_s3"; SID_s3="s3-sess"
mksessionfile "$T_s3" "$SID_s3" "202609050800"
ln -s "$T_s3" "$T_s3/loop"
run_gate "$T_s3" "$(mkjson "$SID_s3" false)"
{ [ "$RC" -eq 0 ] && ! printf '%s' "$OUT" | grep -qF '"decision":"block"'; } \
  && ok "#1311 S3: a self-referential directory symlink terminates and allows" \
  || no "#1311 S3: loop symlink mishandled RC=$RC OUT=$OUT ERR=$ERR"
# S4: a directory symlink ADDED since the session sha (committed link) is itself a change → BLOCK
# even when the link target is unreadable/old (fail toward BLOCK: the new link may expose research).
S4_EXT="$ROOT/s4-ext"; mkdir -p "$S4_EXT"; printf '# Block\n' > "$S4_EXT/niagara-block1.md"
touch -t 202609040800 "$S4_EXT/niagara-block1.md"
T_s4="$ROOT/t-s4"; mkgit "$T_s4"; SID_s4="s4-sess"
mksessionfile "$T_s4" "$SID_s4" "202609050800"
ln -s "$S4_EXT" "$T_s4/corpus"; git -C "$T_s4" add corpus
GIT_AUTHOR_DATE="2026-09-05T12:00:00" GIT_COMMITTER_DATE="2026-09-05T12:00:00" \
  git -C "$T_s4" commit -q -m "add corpus link"
run_gate "$T_s4" "$(mkjson "$SID_s4" false)"
printf '%s' "$OUT" | grep -qF '"decision":"block"' \
  && ok "#1311 S4: a directory symlink added since the session start counts as a change → blocks" \
  || no "#1311 S4: newly added directory symlink false ALLOW: OUT=$OUT ERR=$ERR"

# ─── #1311 fix round: Part C is bounded, scoped and loud ─────────────────────
# Candidate links come from git (tracked mode-120000 + untracked non-ignored), not a full `find`
# (12-16 s per Stop on a 66k-symlink corpus). Links resolving to / $HOME / an ancestor of the target
# are skipped with a typed WARN; links resolving inside the target (Parts A/B own them) or inside a
# nested worktree are skipped; an incomplete or timed-out walk is a typed WARN, never a silent zero.
REAL_GIT="$(type -P git)"
STUB_NOLS="$ROOT/stub-nols"; mkdir -p "$STUB_NOLS"     # git whose ls-files fails → find fallback
printf '#!/usr/bin/env bash\ncase " $* " in *" ls-files "*) exit 128;; esac\nexec %s "$@"\n' "$REAL_GIT" > "$STUB_NOLS/git"
STUB_TO124="$ROOT/stub-to124"; mkdir -p "$STUB_TO124"  # + timeout that expires the enumerating find
cp "$STUB_NOLS/git" "$STUB_TO124/git"
printf '#!/usr/bin/env bash\ncase " $* " in *" -xtype "*) exit 124;; esac\nshift; exec "$@"\n' > "$STUB_TO124/timeout"
STUB_TOINNER="$ROOT/stub-toinner"; mkdir -p "$STUB_TOINNER"  # timeout whose inner walk fails (rc 1)
printf '#!/usr/bin/env bash\ncase " $* " in *" -newer "*) exit 1;; esac\nshift; exec "$@"\n' > "$STUB_TOINNER/timeout"
chmod +x "$STUB_NOLS/git" "$STUB_TO124/git" "$STUB_TO124/timeout" "$STUB_TOINNER/timeout"
run_gate_path() {  # <stubdir> <target> <json>
  local errf="$ROOT/err_path.$$"
  OUT="$(printf '%s' "$3" | PATH="$1:$PATH" "$BASH_BIN" "$SUT" "$2" 2>"$errf")"; RC=$?
  ERR="$(cat "$errf")"; rm -f "$errf"
}
mkfresh() { mkdir -p "$1"; printf '# Block\n' > "$1/niagara-block1.md"; }  # mtime = now (> session)
blocks_json_s() { printf '%s' "$1" | grep -qF '"decision":"block"'; }

# S11: a TRACKED link committed BEFORE the session start (Part A sees nothing) with research
# changed behind it → BLOCK; proves the tracked mode-120000 leg of the git enumeration.
S11_EXT="$ROOT/s11-ext"; mkdir -p "$S11_EXT"
T_s11="$ROOT/t-s11"; mkgit "$T_s11"; SID_s11="s11-sess"
ln -s "$S11_EXT" "$T_s11/corpus"; git -C "$T_s11" add corpus
GIT_AUTHOR_DATE="2026-09-01T12:00:00" GIT_COMMITTER_DATE="2026-09-01T12:00:00" \
  git -C "$T_s11" commit -q -m "add corpus link"
mksessionfile "$T_s11" "$SID_s11" "202609050800"; printf '# Block\n' > "$S11_EXT/niagara-block1.md"
run_gate "$T_s11" "$(mkjson "$SID_s11" false)"
printf '%s' "$OUT" | grep -qF '"decision":"block"' \
  && ok "#1311 S11: tracked directory link (pre-session) with changed research behind it → blocks" \
  || no "#1311 S11: tracked link missed: OUT=$OUT ERR=$ERR"

# S5 (N2): a link INTO a nested worktree of this target is a worktree copy, not a change → ALLOW.
T_s5="$ROOT/t-s5"; mkgit "$T_s5"; SID_s5="s5-sess"; mksessionfile "$T_s5" "$SID_s5" "202609050800"
mkfresh "$T_s5/.claude/worktrees/agent-x"; ln -s "$T_s5/.claude/worktrees/agent-x" "$T_s5/wt"
run_gate "$T_s5" "$(mkjson "$SID_s5" false)"
blocks_json_s "$OUT" \
  && no "#1311 S5: link into a nested worktree counted as a change: OUT=$OUT" \
  || ok "#1311 S5: link into a nested worktree is not a change"
# S6 (N1): a link to an ANCESTOR of the target is skipped with a typed WARN (it would walk the
# whole parent tree); the fresh sibling block behind it must not block.
mkfresh "$ROOT/anc/sib"; T_s6="$ROOT/anc/t-s6"; mkgit "$T_s6"; SID_s6="s6-sess"
mksessionfile "$T_s6" "$SID_s6" "202609050800"; ln -s "$ROOT/anc" "$T_s6/up"
run_gate "$T_s6" "$(mkjson "$SID_s6" false)"
{ ! blocks_json_s "$OUT" && printf '%s' "$ERR" | grep -q 'WARN: directory symlink .*ancestor'; } \
  && ok "#1311 S6: link to an ancestor is skipped with a typed WARN" \
  || no "#1311 S6: ancestor link scanned or silent: OUT=$OUT ERR=$ERR"
# S7 (documented tradeoff): a GITIGNORED directory link is not enumerated (git is the candidate source).
S7_EXT="$ROOT/s7-ext"; mkfresh "$S7_EXT"
T_s7="$ROOT/t-s7"; mkgit "$T_s7"; SID_s7="s7-sess"; mksessionfile "$T_s7" "$SID_s7" "202609050800"
printf 'ign\n.claude/\n' > "$T_s7/.gitignore"; ln -s "$S7_EXT" "$T_s7/ign"
run_gate "$T_s7" "$(mkjson "$SID_s7" false)"
blocks_json_s "$OUT" \
  && no "#1311 S7: gitignored link scanned (latency tradeoff changed?): OUT=$OUT" \
  || ok "#1311 S7: gitignored directory link is not scanned (documented tradeoff)"
# S8: git cannot enumerate → bounded find fallback still finds the link (S1 shape) → BLOCK.
T_s8="$ROOT/t-s8"; mkgit "$T_s8"; SID_s8="s8-sess"; mksessionfile "$T_s8" "$SID_s8" "202609050800"
ln -s "$S1_EXT" "$T_s8/corpus"
run_gate_path "$STUB_NOLS" "$T_s8" "$(mkjson "$SID_s8" false)"
blocks_json_s "$OUT" \
  && ok "#1311 S8: git ls-files failing → bounded find fallback → blocks" \
  || no "#1311 S8: fallback missed the link: OUT=$OUT ERR=$ERR"
# S9: the fallback enumeration times out → typed WARN (never a silent zero).
T_s9="$ROOT/t-s9"; mkgit "$T_s9"; SID_s9="s9-sess"; mksessionfile "$T_s9" "$SID_s9" "202609050800"
ln -s "$S1_EXT" "$T_s9/corpus"
run_gate_path "$STUB_TO124" "$T_s9" "$(mkjson "$SID_s9" false)"
printf '%s' "$ERR" | grep -q 'WARN: directory-symlink scan timed out' \
  && ok "#1311 S9: fallback timeout → typed WARN" \
  || no "#1311 S9: timeout silent: ERR=$ERR"
# S10 (N3): an inner walk that exits non-zero is a typed WARN (incomplete), not a silent no-match.
T_s10="$ROOT/t-s10"; mkgit "$T_s10"; SID_s10="s10-sess"; mksessionfile "$T_s10" "$SID_s10" "202609050800"
ln -s "$S2_EXT" "$T_s10/corpus"
run_gate_path "$STUB_TOINNER" "$T_s10" "$(mkjson "$SID_s10" false)"
printf '%s' "$ERR" | grep -q 'WARN: directory-symlink walk incomplete' \
  && ok "#1311 S10: failing inner walk → typed WARN" \
  || no "#1311 S10: incomplete walk silent: ERR=$ERR"

# ─── #1352: Part C follow-ups (newline link names, timeout validation, untracked leg) ─────────
# S12: a link whose NAME contains a newline is one path end to end (NUL-delimited, never rejoined
# with newlines). Before the fix it was split into `a` and `b`, the walk hit a cwd-relative `b`,
# and research behind the link was missed (loud WARN, but still a false ALLOW).
S12_EXT="$ROOT/s12-ext"; mkfresh "$S12_EXT"
T_s12="$ROOT/t-s12"; mkgit "$T_s12"; SID_s12="s12-sess"; mksessionfile "$T_s12" "$SID_s12" "202609050800"
ln -s "$S12_EXT" "$T_s12/$(printf 'nl\nlink')"
run_gate "$T_s12" "$(mkjson "$SID_s12" false)"
{ blocks_json_s "$OUT" && ! printf '%s' "$ERR" | grep -q 'WARN: directory-symlink'; } \
  && ok "#1352 S12: a directory link named with a newline is walked as one path → blocks, no WARN" \
  || no "#1352 S12: newline-named link mishandled: OUT=$OUT ERR=$ERR"
# S13: the same link through the bounded-find FALLBACK (git cannot enumerate) — NUL end to end too.
T_s13="$ROOT/t-s13"; mkgit "$T_s13"; SID_s13="s13-sess"; mksessionfile "$T_s13" "$SID_s13" "202609050800"
ln -s "$S12_EXT" "$T_s13/$(printf 'nl\nlink')"
run_gate_path "$STUB_NOLS" "$T_s13" "$(mkjson "$SID_s13" false)"
{ blocks_json_s "$OUT" && ! printf '%s' "$ERR" | grep -q 'WARN: directory-symlink'; } \
  && ok "#1352 S13: newline-named link via the find fallback is walked as one path → blocks, no WARN" \
  || no "#1352 S13: newline-named link mishandled in fallback: OUT=$OUT ERR=$ERR"
# S14: RETRO_GATE_DIRLINK_TIMEOUT must be a positive number. Anything else is a typed WARN naming
# the variable and falls back to the 5 s default (never 0 = unbounded, never a per-link rc 125).
# The stub `timeout` logs the seconds it was handed, so the fallback value is observed, not assumed.
STUB_TOLOG="$ROOT/stub-tolog"; mkdir -p "$STUB_TOLOG"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$1" >> "$TOLOG"\nshift; exec "$@"\n' > "$STUB_TOLOG/timeout"; chmod +x "$STUB_TOLOG/timeout"
S14_EXT="$ROOT/s14-ext"; mkfresh "$S14_EXT"
T_s14="$ROOT/t-s14"; mkgit "$T_s14"; SID_s14="s14-sess"; mksessionfile "$T_s14" "$SID_s14" "202609050800"
ln -s "$S14_EXT" "$T_s14/corpus"
for _tv in abc 0 0.0 -3 1e3 2s; do
  TOLOG="$ROOT/tolog-$_tv"; : > "$TOLOG"; export TOLOG
  rm -f "$T_s14/.claude/.rsdd-retro-blocked-$SID_s14"
  RETRO_GATE_DIRLINK_TIMEOUT="$_tv" run_gate_path "$STUB_TOLOG" "$T_s14" "$(mkjson "$SID_s14" false)"
  { printf '%s' "$ERR" | grep -q "WARN: RETRO_GATE_DIRLINK_TIMEOUT='$_tv' is not a positive number" \
      && [ "$(head -n1 "$TOLOG")" = "5" ] && blocks_json_s "$OUT"; } \
    && ok "#1352 S14: RETRO_GATE_DIRLINK_TIMEOUT='$_tv' → typed WARN, default 5 s used, link still walked" \
    || no "#1352 S14: invalid timeout '$_tv' mishandled: first-arg=$(head -n1 "$TOLOG") ERR=$ERR"
done
# S14b: valid values (integer, decimal) pass through unchanged with NO warning; empty = unset.
for _tv in 7 2.5; do
  TOLOG="$ROOT/tolog-ok-$_tv"; : > "$TOLOG"; export TOLOG
  rm -f "$T_s14/.claude/.rsdd-retro-blocked-$SID_s14"
  RETRO_GATE_DIRLINK_TIMEOUT="$_tv" run_gate_path "$STUB_TOLOG" "$T_s14" "$(mkjson "$SID_s14" false)"
  { ! printf '%s' "$ERR" | grep -q 'RETRO_GATE_DIRLINK_TIMEOUT' && [ "$(head -n1 "$TOLOG")" = "$_tv" ]; } \
    && ok "#1352 S14b: RETRO_GATE_DIRLINK_TIMEOUT='$_tv' is used as given, no WARN" \
    || no "#1352 S14b: valid timeout '$_tv' rejected or altered: first-arg=$(head -n1 "$TOLOG") ERR=$ERR"
done
TOLOG="$ROOT/tolog-empty"; : > "$TOLOG"; export TOLOG; rm -f "$T_s14/.claude/.rsdd-retro-blocked-$SID_s14"
RETRO_GATE_DIRLINK_TIMEOUT="" run_gate_path "$STUB_TOLOG" "$T_s14" "$(mkjson "$SID_s14" false)"
{ ! printf '%s' "$ERR" | grep -q 'RETRO_GATE_DIRLINK_TIMEOUT' && [ "$(head -n1 "$TOLOG")" = "5" ]; } \
  && ok "#1352 S14b: empty RETRO_GATE_DIRLINK_TIMEOUT behaves as unset (5 s, no WARN)" \
  || no "#1352 S14b: empty timeout mishandled: first-arg=$(head -n1 "$TOLOG") ERR=$ERR"

# ─── #1301 item 3: the gate when the nested-worktree PROBE itself fails ───────
# The lib returns 2 (not a directory) or 3 (incomplete traversal); anything else is a defect. The
# gate must FAIL SAFE: keep scanning (worktree copies may then be counted → a recoverable false
# BLOCK) and say so — never turn a failed probe into an allow. PFKIT is a stub kit whose probe
# returns $PF_RC after printing the fixed .claude/worktrees root.
PFKIT="$ROOT/pfkit"; mkdir -p "$PFKIT"; cp -R "$FKIT/toolbelt" "$PFKIT/toolbelt"
cat >> "$PFKIT/toolbelt/lib/block-files.sh" << 'PFEOF'
unset -f block_files_nested_worktree_roots
block_files_nested_worktree_roots() { printf '%s\n' "${1%/}/.claude/worktrees"; return "${PF_RC:-5}"; }
PFEOF
# run_pf <rc> <target> <sid> [gate-file] → sets OUT RC ERR (clears block-once state first)
run_pf() {
  local rc="$1" tgt="$2" sid="$3" gate="${4:-$PFKIT/toolbelt/retro-gate.sh}" errf="$ROOT/pf_err.$$"
  rm -f "$tgt/.claude/.rsdd-retro-blocked-$sid"
  OUT="$(printf '%s' "$(mkjson "$sid" false)" | PF_RC="$rc" SEED_LOG="$SEED_LOG_EN3" \
    PATH="$MOCK_GH_DIR:$PATH" "$BASH_BIN" "$gate" "$tgt" 2>"$errf")"; RC=$?
  ERR="$(cat "$errf")"; rm -f "$errf"
}
cp "$SUT" "$PFKIT/toolbelt/retro-gate.sh"
T_p1="$ROOT/t-p1"; mkgit "$T_p1"; SID_p1="p1-sess"
mksessionfile "$T_p1" "$SID_p1" "202609050800"
printf '# Block\n' > "$T_p1/niagara-block1.md"
for _pfrc in 2 5 127; do
  run_pf "$_pfrc" "$T_p1" "$SID_p1"
  printf '%s' "$OUT" | grep -qF '"decision":"block"' \
    && ok "#1301 P1(rc=$_pfrc): probe failure → the gate still BLOCKS the changed block (fail safe)" \
    || no "#1301 P1(rc=$_pfrc): probe failure must not allow: OUT=$OUT ERR=$ERR"
  printf '%s' "$ERR" | grep -qF "WARN: nested-worktree probe failed (rc=$_pfrc)" \
    && ok "#1301 P1(rc=$_pfrc): typed WARN names the failed probe and its rc" \
    || no "#1301 P1(rc=$_pfrc): no typed probe-failure WARN: $ERR"
  printf '%s' "$ERR" | grep -q 'state=allow' \
    && no "#1301 P1(rc=$_pfrc): stderr claims state=allow: $ERR" \
    || ok "#1301 P1(rc=$_pfrc): stderr never claims state=allow"
done
# P2: rc 3 (incomplete traversal) is the lib's own typed WARN — the gate must not repeat it.
run_pf 3 "$T_p1" "$SID_p1"
printf '%s' "$ERR" | grep -qF 'nested-worktree probe failed' \
  && no "#1301 P2: rc=3 warned twice (the lib already warned): $ERR" \
  || ok "#1301 P2: rc=3 adds no duplicate gate-level WARN"
printf '%s' "$OUT" | grep -qF '"decision":"block"' \
  && ok "#1301 P2: rc=3 still blocks the changed block" \
  || no "#1301 P2: rc=3 must not allow: OUT=$OUT ERR=$ERR"
# P3: rc 0 control — no failure WARN.
run_pf 0 "$T_p1" "$SID_p1"
printf '%s' "$ERR" | grep -qF 'nested-worktree probe failed' \
  && no "#1301 P3: rc=0 emitted a probe-failure WARN: $ERR" \
  || ok "#1301 P3: rc=0 control emits no probe-failure WARN"

# ─── #1229: generated CATALOG.md is not a block (degraded mtime scan) ────────
# gen-catalog.py rewrites CATALOG.md seconds AFTER the retro is written; in degraded mode the
# newest-"block" mtime scan counted it and declared the retro stale (kit issue #1229).
T_c1="$ROOT/t-c1"
mkdir -p "$T_c1/retros"
printf '# Block\n' > "$T_c1/niagara-block1.md"; touch -d '-3 hours' "$T_c1/niagara-block1.md"
mkretro "$T_c1" "2026-09-05-c1.md" 1;           touch -d '-2 hours' "$T_c1/retros/2026-09-05-c1.md"
printf '# Catalog (generated)\n' > "$T_c1/CATALOG.md"; touch -d '-1 hour' "$T_c1/CATALOG.md"
run_gate "$T_c1" "$(mkjson "c1-sess" false)"
[ -z "$OUT" ] \
  && ok "#1229 C1: degraded — CATALOG.md newer than the retro does not make it stale → allows" \
  || no "#1229 C1: generated CATALOG.md counted as a changed block: $OUT"

# C2 (control): a REAL block newer than the retro, with CATALOG.md present → still BLOCK.
T_c2="$ROOT/t-c2"
mkdir -p "$T_c2/retros"
printf '# Catalog (generated)\n' > "$T_c2/CATALOG.md"; touch -d '-3 hours' "$T_c2/CATALOG.md"
mkretro "$T_c2" "2026-09-05-c2.md" 1;                  touch -d '-2 hours' "$T_c2/retros/2026-09-05-c2.md"
printf '# Block\n' > "$T_c2/niagara-block1.md";         touch -d '-1 hour' "$T_c2/niagara-block1.md"
run_gate "$T_c2" "$(mkjson "c2-sess" false)"
printf '%s' "$OUT" | grep -qF '"decision":"block"' \
  && ok "#1229 C2: degraded — real block newer than the retro still blocks (CATALOG.md does not mask it)" \
  || no "#1229 C2: real stale-retro case must still block: OUT=$OUT ERR=$ERR"

# C3 (nested CATALOG.md, only candidate besides the retro): still not a block.
T_c3="$ROOT/t-c3"
mkdir -p "$T_c3/retros" "$T_c3/corpus"
mkretro "$T_c3" "2026-09-05-c3.md" 1;                        touch -d '-2 hours' "$T_c3/retros/2026-09-05-c3.md"
printf '# Catalog (generated)\n' > "$T_c3/corpus/CATALOG.md"; touch -d '-1 hour' "$T_c3/corpus/CATALOG.md"
run_gate "$T_c3" "$(mkjson "c3-sess" false)"
[ -z "$OUT" ] \
  && ok "#1229 C3: degraded — nested CATALOG.md alone does not make the retro stale → allows" \
  || no "#1229 C3: nested generated CATALOG.md counted as a block: $OUT"

# ─── #1167 item 2: _json_escape_reason is stable across bash versions ────────
# The old inline operand "\\$_dq" inside ${s//…/…} is interpreted differently on bash < 4.3, and
# on bash >= 5.2 an unquoted '&' in a replacement expands to the match. The function now takes
# its replacement from a variable. Behaviour on THIS host is byte-identical before/after, so a
# behavioural case alone cannot go red against the pre-fix code here; two things pin the fix:
# esc_checks (values, incl. '&' and quote/backslash edges, run against any copy of the SUT) and a
# structural pin that the nested-quote operand is gone.
# esc_checks <sut-file>: prints one "FAIL:<name>" line per broken assertion.
esc_checks() {
  (
    eval "$(sed -n '/^_json_escape_reason() {/,/^}/p' "$1")"
    declare -F _json_escape_reason >/dev/null 2>&1 || { echo "FAIL:function-not-extracted"; exit 0; }
    chk() { # <name> <input> <expected>
      local got; got="$(_json_escape_reason "$2")"
      [ "$got" = "$3" ] || echo "FAIL:$1(got=[$got])"
    }
    chk quote-only        '"'          '\"'
    chk quote-first       '"ab'        '\"ab'
    chk quote-last        'ab"'        'ab\"'
    chk quote-middle      'a"b'        'a\"b'
    chk two-quotes        '""'         '\"\"'
    chk backslash         'a\b'        'a\\b'
    chk backslash-quote   'a\"b'       'a\\\"b'
    chk ampersand-only    '&'          '&'
    chk ampersand-quote   'a&"b'       'a&\"b'
    chk quote-ampersand   'a"&b'       'a\"&b'
    chk plain             'plain text' 'plain text'
    chk empty             ''           ''
    chk newline           $'a\nb'      'a\nb'
    # #1301 item 6: raw control characters are illegal inside a JSON string — escape them all.
    chk tab               $'a\tb'      'a\tb'
    chk carriage-return   $'a\rb'      'a\rb'
    chk ctrl-first        $'\x01z'     '\u0001z'
    chk ctrl-last         $'z\x1f'     'z\u001f'
    chk ctrl-backspace    $'a\x08b'    'a\u0008b'
    chk ctrl-formfeed     $'a\x0cb'    'a\u000cb'
    chk ansi-escape       $'\x1b[0m'   '\u001b[0m'
    chk ctrl-and-quote    $'"\x02"'    '\"\u0002\"'
    chk del-untouched     $'a\x7fb'    $'a\x7fb'
  )
}
esc_out="$(esc_checks "$SUT")"
[ -z "$esc_out" ] \
  && ok "#1167-2 ESC1: _json_escape_reason values hold (quote/backslash/& edges, newline, empty)" \
  || no "#1167-2 ESC1: _json_escape_reason" "$(printf '%s' "$esc_out" | tr '\n' ' ')"
# ESC2: the whole reason round-trips through a real JSON parser when it carries " \ & chars.
if command -v jq >/dev/null 2>&1; then
  _esc_probe="$(eval "$(sed -n '/^_json_escape_reason() {/,/^}/p' "$SUT")"; printf '{"reason":"%s"}' "$(_json_escape_reason 'x "q" \ & y')")"
  [ "$(printf '%s' "$_esc_probe" | jq -r .reason 2>/dev/null)" = 'x "q" \ & y' ] \
    && ok "#1167-2 ESC2: escaped reason round-trips through jq" \
    || no "#1167-2 ESC2: escaped reason did not round-trip: $_esc_probe"
else
  printf '  SKIP  #1167-2 ESC2: jq not available — round-trip case not run\n'
fi
# ESC2b (#1301 item 6): a reason carrying tab, CR and other C0 bytes still parses as JSON and
# round-trips (the raw bytes made the whole decision unparseable for the hook runner).
if command -v jq >/dev/null 2>&1; then
  _esc_cc=$'t\tc\rx\x01y\x1bz'
  _esc_probe2="$(eval "$(sed -n '/^_json_escape_reason() {/,/^}/p' "$SUT")"; printf '{"reason":"%s"}' "$(_json_escape_reason "$_esc_cc")")"
  [ "$(printf '%s' "$_esc_probe2" | jq -r .reason 2>/dev/null)" = "$_esc_cc" ] \
    && ok "#1301-6 ESC2b: reason with control characters round-trips through jq" \
    || no "#1301-6 ESC2b: control characters broke the JSON: $(printf '%s' "$_esc_probe2" | od -c | head -3)"
else
  printf '  SKIP  #1301-6 ESC2b: jq not available — round-trip case not run\n'
fi
# ESC3 (structural pin): no nested-quote replacement operand inside ${s//…/…}.
# esc_pin_ok <sut-file>: 0 when the inline nested-quote operand is absent.
esc_pin_ok() { ! grep -qF '"\\$_dq"' "$1"; }
if ! esc_pin_ok "$SUT"; then
  no "#1167-2 ESC3: SUT still uses the inline nested-quote operand (bash < 4.3 differs)"
else
  ok "#1167-2 ESC3: no inline nested-quote replacement operand in _json_escape_reason"
fi

# ─── #1301 item 1: a target registered through a SYMLINK is scanned, not skipped ──
# `find <symlink>` without -H lists the link itself and descends into nothing, so every scan of
# $TARGET silently saw an EMPTY tree: Part B found no uncommitted research file and the gate said
# `state=allow branch=no-change` (a false ALLOW, no retro demanded). The scans now use `find -H`.
# Each case has a CONTROL on the real directory so the fixture is proven to be a changed corpus.

# L1 (Part B, plain file): uncommitted block under a symlinked target → BLOCK.
T_l1="$ROOT/t-l1"; mkgit "$T_l1"; SID_l1="l1-sess"
mksessionfile "$T_l1" "$SID_l1" "202609050800"
mkdir -p "$T_l1/research"; printf '# Block\n' > "$T_l1/research/niagara-block1.md"
ln -s "$T_l1" "$ROOT/t-l1-link"
run_gate "$T_l1" "$(mkjson "$SID_l1" false)"
printf '%s' "$OUT" | grep -qF '"decision":"block"' \
  && ok "PRECOND(#1301 L1): real-path target with an uncommitted block → blocks (fixture is a changed corpus)" \
  || no "PRECOND(#1301 L1): control did not block — fixture broken: OUT=$OUT ERR=$ERR"
rm -f "$T_l1/.claude/.rsdd-retro-blocked-$SID_l1"
run_gate "$ROOT/t-l1-link" "$(mkjson "$SID_l1" false)"
printf '%s' "$OUT" | grep -qF '"decision":"block"' \
  && ok "#1301 L1: the same corpus via a symlinked target → blocks (no false ALLOW)" \
  || no "#1301 L1: symlinked target false ALLOW: OUT=$OUT ERR=$ERR"
printf '%s' "$ERR" | grep -q 'branch=no-change' \
  && no "#1301 L1: symlinked target reported branch=no-change: $ERR" \
  || ok "#1301 L1: symlinked target does not report branch=no-change"

# L2 (Part B inside a SUBMODULE): block changed only inside a submodule of a symlinked target.
L2_SRC="$ROOT/l2-subsrc"; L2_MAIN="$ROOT/l2-main"; SID_l2="l2-sess"
mkdir -p "$L2_SRC" "$L2_MAIN"
_w9g -C "$L2_SRC" init -q; : > "$L2_SRC/f"; _w9g -C "$L2_SRC" add f; _w9g -C "$L2_SRC" commit -q -m i
_w9g -C "$L2_MAIN" init -q; : > "$L2_MAIN/.keep"; _w9g -C "$L2_MAIN" add .keep; _w9g -C "$L2_MAIN" commit -q -m i
_w9g -C "$L2_MAIN" submodule add "file://$L2_SRC" notes; _w9g -C "$L2_MAIN" commit -q -m sub
mksessionfile "$L2_MAIN" "$SID_l2" "202609050800"
printf '# Block\n' > "$L2_MAIN/notes/niagara-block1.md"
ln -s "$L2_MAIN" "$ROOT/l2-link"
run_gate "$L2_MAIN" "$(mkjson "$SID_l2" false)"
printf '%s' "$OUT" | grep -qF '"decision":"block"' \
  && ok "PRECOND(#1301 L2): real-path target, block changed inside a submodule → blocks" \
  || no "PRECOND(#1301 L2): control did not block — fixture broken: OUT=$OUT ERR=$ERR"
rm -f "$L2_MAIN/.claude/.rsdd-retro-blocked-$SID_l2"
run_gate "$ROOT/l2-link" "$(mkjson "$SID_l2" false)"
printf '%s' "$OUT" | grep -qF '"decision":"block"' \
  && ok "#1301 L2: submodule block via a symlinked target → blocks" \
  || no "#1301 L2: symlinked target + submodule false ALLOW: OUT=$OUT ERR=$ERR"

# L3 (DEGRADED mtime scans): conforming retro newer than the block, target via symlink → ALLOW.
# Without -H both degraded scans saw nothing, so the gate claimed "no retro at all" (false BLOCK).
T_l3="$ROOT/t-l3"; mkdir -p "$T_l3/retros"
printf '# Block\n\nContent.\n' > "$T_l3/niagara-block1.md"; touch -d '-3 hours' "$T_l3/niagara-block1.md"
mkretro "$T_l3" "2026-09-05-l3.md" 1;                       touch -d '-1 hour'  "$T_l3/retros/2026-09-05-l3.md"
ln -s "$T_l3" "$ROOT/t-l3-link"
run_gate "$T_l3" "$(mkjson "l3-sess" false)"
[ -z "$OUT" ] \
  && ok "PRECOND(#1301 L3): real-path degraded target with a newer conforming retro → allows" \
  || no "PRECOND(#1301 L3): control did not allow — fixture broken: OUT=$OUT"
run_gate "$ROOT/t-l3-link" "$(mkjson "l3-sess" false)"
[ -z "$OUT" ] \
  && ok "#1301 L3: degraded scans follow a symlinked target → allows" \
  || no "#1301 L3: degraded scans skipped the symlinked target (false BLOCK): OUT=$OUT"

# L5 (DEGRADED, block NEWER than the retro): via a symlink the stale retro must still BLOCK.
# Both degraded scans were blind pre-fix, so the "no retro at all" branch blocked by accident;
# this case pins the STALE branch itself and is what bites a mutant that blinds only the
# degraded block-mtime scan (see TOOTH l-degraded-block-scan).
T_l5="$ROOT/t-l5"; mkdir -p "$T_l5/retros"
printf '# Block\n\nContent.\n' > "$T_l5/niagara-block1.md"; touch -d '-1 hour'  "$T_l5/niagara-block1.md"
mkretro "$T_l5" "2026-09-05-l5.md" 1;                       touch -d '-3 hours' "$T_l5/retros/2026-09-05-l5.md"
ln -s "$T_l5" "$ROOT/t-l5-link"
run_gate "$ROOT/t-l5-link" "$(mkjson "l5-sess" false)"
printf '%s' "$OUT" | grep -qF 'is OLDER than newest changed block'   && ok "#1301 L5: degraded stale retro via a symlinked target → blocks as OLDER than the block"   || no "#1301 L5: stale-retro branch not reached via the symlinked target: OUT=$OUT ERR=$ERR"

# L4 (issue seeding): the retro scan of _run_issue_seeding must also follow the symlink.
T_l4="$ROOT/t-l4"; mkgit "$T_l4"; SID_l4="l4-sess"
mksessionfile "$T_l4" "$SID_l4" "202609050800"
mkblock "$T_l4" "niagara-block1.md" "2026-09-05T10:00:00"
touch -t 202609051000 "$T_l4/niagara-block1.md"
mkretro "$T_l4" "2026-09-05-l4real.md" 1
touch -t 202609051200 "$T_l4/retros/2026-09-05-l4real.md"
ln -s "$T_l4" "$ROOT/t-l4-link"
: > "$SEED_LOG_EN3"
run_fkit_gate "$ROOT/t-l4-link" "$(mkjson "$SID_l4" false)"
grep -q 'l4real' "$SEED_LOG_EN3" \
  && ok "#1301 L4: the retro under a symlinked target is seeded" \
  || no "#1301 L4: seeding scan skipped the symlinked target (retro never seeded): ERR=$ERR"

# ─── #1161: hermetic bin builder — skip glob, first-wins, no per-file fork ───
# hb_checks <function-source>: eval the builder text in a subshell and run it against a fixture
# PATH of three dirs: a/ (alpha, jq), skipme/ (beta), b/ (alpha dup, gamma). Prints one
# "FAIL:<name>" per broken assertion. Used for the real builder AND each mutant.
hb_checks() {
  (
    eval "$1"
    declare -F build_hermetic_nojq_bin >/dev/null 2>&1 || { echo "FAIL:function-not-defined"; exit 0; }
    h="$(mktemp -d)"; trap 'rm -rf "$h"' EXIT
    mkdir -p "$h/a" "$h/skipme" "$h/b" "$h/out"
    for t in a/alpha a/jq skipme/beta b/alpha b/gamma; do
      printf '#!/bin/sh\necho %s\n' "$t" > "$h/$t"; chmod +x "$h/$t"
    done
    HERMETIC_BIN_SKIP_GLOB="$h/skipme*" build_hermetic_nojq_bin "$h/a:$h/skipme:$h/b:$h/nonexistent" "$h/out" 2>"$h/builder.err"
    # a builder that tries to re-link a name it already mirrored (first-wins lost) makes ln
    # complain; ln refuses to overwrite, so the symlink target alone would not reveal it.
    [ -s "$h/builder.err" ] && echo "FAIL:builder-stderr-must-be-empty"
    [ -x "$h/out/alpha" ] || echo "FAIL:alpha-reachable"
    [ -x "$h/out/gamma" ] || echo "FAIL:gamma-reachable-from-later-dir"
    [ -e "$h/out/jq" ] && echo "FAIL:jq-must-be-hidden"
    [ -e "$h/out/beta" ] && echo "FAIL:skipped-dir-must-not-be-mirrored"
    [ "$(readlink "$h/out/alpha" 2>/dev/null)" = "$h/a/alpha" ] || echo "FAIL:first-wins(alpha→a/)"
    # no skip glob match → the dir IS mirrored (the skip is a glob, not a blanket drop)
    rm -rf "$h/out2"; mkdir -p "$h/out2"
    HERMETIC_BIN_SKIP_GLOB="/nonexistent-prefix/*" build_hermetic_nojq_bin "$h/skipme" "$h/out2"
    [ -x "$h/out2/beta" ] || echo "FAIL:non-matching-glob-still-mirrors"
    # empty dir and empty src_path: no error, no links
    rm -rf "$h/out3"; mkdir -p "$h/out3" "$h/empty"
    build_hermetic_nojq_bin "$h/empty" "$h/out3" 2>/dev/null || echo "FAIL:empty-dir-rc"
    build_hermetic_nojq_bin "" "$h/out3" 2>/dev/null || echo "FAIL:empty-path-rc"
    [ -z "$(ls -A "$h/out3")" ] || echo "FAIL:empty-dir-no-links"
  )
}
HB_SRC="$(sed -n '/^build_hermetic_nojq_bin() {/,/^}/p' "${BASH_SOURCE[0]}")"
[ -n "$HB_SRC" ] || no "#1161 HB0: could not extract build_hermetic_nojq_bin from this file"
hb_out="$(hb_checks "$HB_SRC")"
[ -z "$hb_out" ] \
  && ok "#1161 HB1: builder — skip glob, first-wins, jq hidden, edge dirs (empty / absent / later-dir-only)" \
  || no "#1161 HB1: builder" "$(printf '%s' "$hb_out" | tr '\n' ' ')"
# HB2: the default skip glob is the WSL Windows mount ('/mnt/*'); pinned because no /mnt dir
# can be fabricated here without root.
case "$HB_SRC" in
  *'HERMETIC_BIN_SKIP_GLOB:-/mnt/*'*) ok "#1161 HB2: default skip glob is /mnt/* (WSL Windows mounts)" ;;
  *) no "#1161 HB2: default skip glob is not /mnt/*" ;;
esac
# HB3: the builder no longer forks basename per executable.
case "$HB_SRC" in
  *'basename'*) no "#1161 HB3: builder still forks basename per executable" ;;
  *) ok "#1161 HB3: no basename fork per executable (\${_exe##*/})" ;;
esac

# ─── #1258: Stop-branch log (.claude/.rsdd-retro-gate-stops.log) + seeding evidence ─
# Every Stop appends ONE line (UTC timestamp, target, branch, seeding evidence) to a log under the
# target's .claude/ state dir — never in the corpus content. Bounded; a write failure is a typed
# WARN and never changes the verdict or the exit code.
SL_NAME=".rsdd-retro-gate-stops.log"
sl_lines() { if [ -f "$1/.claude/$SL_NAME" ]; then wc -l < "$1/.claude/$SL_NAME" | tr -d ' '; else echo 0; fi; }
sl_last() { tail -n 1 "$1/.claude/$SL_NAME" 2>/dev/null; }
mk_sl_conforming() {  # <target> <sid> → conforming retro newer than the block
  mkgit "$1"; mksessionfile "$1" "$2" "202609050800"
  mkblock "$1" "niagara-block1.md" "2026-09-05T10:00:00"
  touch -t 202609051000 "$1/niagara-block1.md"
  mkretro "$1" "2026-09-05-sl.md" 1; touch -t 202609051200 "$1/retros/2026-09-05-sl.md"
}
blocks_json() { printf '%s' "$1" | grep -qF '"decision":"block"'; }

# SL1: no-change Stop → exactly one typed line
TSL1="$ROOT/sl1"; mkgit "$TSL1"; mksessionfile "$TSL1" "sl1" "202609050800"
run_gate "$TSL1" "$(mkjson sl1 false)"
[ "$(sl_lines "$TSL1")" = "1" ] && ok "#1258 SL1a: no-change Stop → one log line under .claude/" \
  || no "#1258 SL1a: want 1 log line, got $(sl_lines "$TSL1")"
_sl="$(sl_last "$TSL1")"
case "$_sl" in
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T*Z\ *"target=sl1"*"branch=no-change"*) ok "#1258 SL1b: line carries UTC timestamp, target, branch=no-change" ;;
  *) no "#1258 SL1b: log line shape wrong: $_sl" ;;
esac
[ -z "$(git -C "$TSL1" status --porcelain -- . ':!.claude' 2>/dev/null)" ] && ok "#1258 SL1c: nothing written outside .claude/ (corpus untouched)" \
  || no "#1258 SL1c: files outside .claude/ changed"

# SL2: second Stop appends (not overwrites); loop-safety branch is logged too
run_gate "$TSL1" "$(mkjson sl1 true)"
if [ "$(sl_lines "$TSL1")" = "2" ] && sl_last "$TSL1" | grep -qF 'branch=loop-safety'; then
  ok "#1258 SL2: second Stop appends a branch=loop-safety line"
else no "#1258 SL2: $(cat "$TSL1/.claude/$SL_NAME")"; fi

# SL3: block path → branch=retro-pending, verdict unchanged
TSL3="$ROOT/sl3"; mkgit "$TSL3"; mksessionfile "$TSL3" "sl3" "202609050800"
mkblock "$TSL3" "niagara-block1.md" "2026-09-05T10:00:00"
run_gate "$TSL3" "$(mkjson sl3 false)"
if blocks_json "$OUT" && sl_last "$TSL3" | grep -qF 'branch=retro-pending'; then
  ok "#1258 SL3: block verdict intact and logged as branch=retro-pending"
else no "#1258 SL3: out=$OUT log=$(sl_last "$TSL3")"; fi
run_gate "$TSL3" "$(mkjson sl3 false)"
sl_last "$TSL3" | grep -qF 'branch=block-once' && ok "#1258 SL3b: block-once branch logged" \
  || no "#1258 SL3b: $(sl_last "$TSL3")"

# SL4: conforming retro + seeding → summary: line on stderr AND in the log
TSL4="$ROOT/sl4"; mk_sl_conforming "$TSL4" sl4
rm -f "$SEED_LOG_EN3"; run_fkit_gate "$TSL4" "$(mkjson sl4 false)"
printf '%s\n' "$ERR" | grep -qE 'summary: created=0 skipped-duplicate=0' \
  && ok "#1258 SL4a: seeder summary: line surfaced on hook stderr" || no "#1258 SL4a: $ERR"
_sl="$(sl_last "$TSL4")"
case "$_sl" in
  *"branch=retro-conforming"*"summary: created=0 skipped-duplicate=0"*) ok "#1258 SL4b: log line holds branch=retro-conforming + the seeder summary" ;;
  *) no "#1258 SL4b: $_sl" ;;
esac
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && ok "#1258 SL4c: verdict unchanged (exit 0, no stdout)" || no "#1258 SL4c: rc=$RC out=$OUT"

# SL5: seeding skipped (gh not authenticated) → typed reason in the log, never silent
TSL5="$ROOT/sl5"; mk_sl_conforming "$TSL5" sl5
run_gate_nogh "$TSL5" "$(mkjson sl5 false)"
sl_last "$TSL5" | grep -qF 'seeding=skipped:gh-not-authenticated' \
  && ok "#1258 SL5: gh-not-authenticated skip is logged typed" || no "#1258 SL5: $(sl_last "$TSL5")"

# SL6: seeder degraded (unregistered target, exit 1) → typed seeder-degraded note
FKIT_DEG="$ROOT/fkitdeg"; cp -r "$FKIT" "$FKIT_DEG"
printf '#!/usr/bin/env bash\nprintf "degraded: target not registered in TARGETS.md\\n"\nexit 1\n' > "$FKIT_DEG/toolbelt/stage-retro-issues.sh"
cp "$SUT" "$FKIT_DEG/toolbelt/retro-gate.sh"
TSL6="$ROOT/sl6"; mk_sl_conforming "$TSL6" sl6
OUT="$(printf '%s' "$(mkjson sl6 false)" | PATH="$MOCK_GH_DIR:$PATH" "$BASH_BIN" "$FKIT_DEG/toolbelt/retro-gate.sh" "$TSL6" 2>/dev/null)"; RC=$?
if sl_last "$TSL6" | grep -qF 'seeder-degraded' && [ "$RC" -eq 0 ]; then
  ok "#1258 SL6: seeder 'degraded:' is logged typed; exit stays 0"
else no "#1258 SL6: rc=$RC $(sl_last "$TSL6")"; fi

# SL7: bounded — a 700-line log is truncated to the tail, newest line kept
TSL7="$ROOT/sl7"; mkgit "$TSL7"; mksessionfile "$TSL7" "sl7" "202609050800"
for _i in $(seq 1 700); do printf 'old line %s\n' "$_i"; done > "$TSL7/.claude/$SL_NAME"
run_gate "$TSL7" "$(mkjson sl7 false)"
_n="$(sl_lines "$TSL7")"
if [ "$_n" -le 300 ] && [ "$_n" -ge 100 ] && sl_last "$TSL7" | grep -qF 'branch=no-change'; then
  ok "#1258 SL7: log bounded ($_n lines) and keeps the newest line"
else no "#1258 SL7: lines=$_n last=$(sl_last "$TSL7")"; fi

# SL8: write failure (.claude is a regular file) → typed WARN, verdict + exit code unchanged
TSL8="$ROOT/sl8"; mkgit "$TSL8"; printf 'x' > "$TSL8/.claude"
run_gate "$TSL8" "$(mkjson sl8 false)"
if [ "$RC" -eq 0 ] && printf '%s' "$ERR" | grep -qF 'retro-gate: WARN: stop-log write failed'; then
  ok "#1258 SL8a: unwritable state dir → typed stderr WARN, exit 0"
else no "#1258 SL8a: rc=$RC err=$ERR"; fi
TSL8B="$ROOT/sl8b"; mkgit "$TSL8B"; mkblock "$TSL8B" "niagara-block1.md" "2026-09-05T10:00:00"
printf 'x' > "$TSL8B/.claude"
run_gate "$TSL8B" "$(mkjson sl8b false)"
blocks_json "$OUT" && ok "#1258 SL8b: block verdict still emitted when the log cannot be written" \
  || no "#1258 SL8b: out=$OUT err=$ERR"

# SL9: jq-missing degraded exit is logged as branch=degraded
TSL9="$ROOT/sl9"; mkgit "$TSL9"
run_gate_nojq "$TSL9" "$(mkjson sl9 false)"
sl_last "$TSL9" | grep -qF 'branch=degraded' && ok "#1258 SL9: jq-missing degraded Stop is logged" \
  || no "#1258 SL9: $(sl_last "$TSL9")"

# SL10 (B1): the log must be covered by the `.claude/.rsdd-*` ignore rule real targets already carry
# (they track .claude/ and ignore only the .rsdd-* state files) — else every Stop dirties the tree.
TSL10="$ROOT/sl10"; mkgit "$TSL10"; mksessionfile "$TSL10" "sl10" "202609050800"
printf '.claude/.rsdd-*\n' > "$TSL10/.gitignore"; printf 'k\n' > "$TSL10/.claude/tracked.txt"
git -C "$TSL10" add .gitignore .claude/tracked.txt; git -C "$TSL10" commit -q -m "ignore rule"
run_gate "$TSL10" "$(mkjson sl10 false)"
if [ -f "$TSL10/.claude/$SL_NAME" ] && git -C "$TSL10" check-ignore -q ".claude/$SL_NAME" \
   && [ -z "$(git -C "$TSL10" status --porcelain)" ]; then
  ok "#1258 SL10: log is ignored by '.claude/.rsdd-*' — the target's git tree stays clean after a Stop"
else no "#1258 SL10: log missing or not ignored; status=$(git -C "$TSL10" status --porcelain)"; fi

# SL11 (N1): rotation uses a per-process temp name. Structural pin + a concurrent-Stop stress.
if grep -qF '"$f.tmp.$$"' "$SUT" && ! grep -qF '"$f.tmp"' "$SUT"; then
  ok "#1258 SL11a: rotation temp file is per-process (no shared \$f.tmp)"
else no "#1258 SL11a: rotation still uses a shared temp name"; fi
sl_race() {  # <gate-path> <target> → prints the number of rounds whose log ended up empty
  local g="$1" t="$2" bad=0 k
  for _ in 1 2 3 4 5 6 7 8; do
    for k in $(seq 1 450); do printf 'old %s\n' "$k"; done > "$t/.claude/$SL_NAME"
    for k in 1 2 3 4; do printf '%s' "$(mkjson slr false)" | "$BASH_BIN" "$g" "$t" >/dev/null 2>&1 & done
    wait
    [ -s "$t/.claude/$SL_NAME" ] || bad=$((bad+1))
  done
  echo "$bad"
}
TSL11="$ROOT/sl11"; mkgit "$TSL11"; mksessionfile "$TSL11" "slr" "202609050800"
[ "$(sl_race "$SUT" "$TSL11")" = "0" ] && ok "#1258 SL11b: concurrent Stops never leave the log empty" \
  || no "#1258 SL11b: a concurrent rotation emptied the log"

# SL12 (N2): a helper-load failure (TARGET already resolved) is logged as branch=error-helper
FKIT_NH="$ROOT/fkitnh"; mkdir -p "$FKIT_NH/toolbelt"; cp "$SUT" "$FKIT_NH/toolbelt/retro-gate.sh"
TSL12="$ROOT/sl12"; mkgit "$TSL12"
OUT="$(printf '%s' "$(mkjson sl12 false)" | "$BASH_BIN" "$FKIT_NH/toolbelt/retro-gate.sh" "$TSL12" 2>/dev/null)"; RC=$?
if [ "$RC" -eq 0 ] && sl_last "$TSL12" | grep -qF 'branch=error-helper'; then
  ok "#1258 SL12: missing helper → exit 0 and a branch=error-helper line"
else no "#1258 SL12: rc=$RC log=$(sl_last "$TSL12")"; fi

# SL13 (N3): a degraded check (no session-start sha) is marked on the line
TSL13="$ROOT/sl13"; mkgit "$TSL13"
run_gate "$TSL13" "$(mkjson sl13 false)"
sl_last "$TSL13" | grep -qF 'mode=degraded' && ok "#1258 SL13a: no session sha → line carries mode=degraded" \
  || no "#1258 SL13a: $(sl_last "$TSL13")"
sl_last "$TSL1" | grep -qF 'mode=degraded' && no "#1258 SL13b: a healthy Stop must not be marked degraded: $(sl_last "$TSL1")" \
  || ok "#1258 SL13b: a session-sha Stop is not marked degraded"

# SL14 (N5): the REAL stage-retro-issues.sh on an unregistered target -> exit 1 'degraded:' reaches
# the log. HERMETIC (§7): the seeder reads TARGETS.md from ITS OWN kit root, so run a copy of the real
# seeder + libs inside a fixture kit whose TARGETS.md has one row (resolving to a temp dir) and does
# NOT register the sl14 target — independent of $HOME / $RESEARCH_HOME and of the real registry.
SL14KIT="$ROOT/sl14kit"; mkdir -p "$SL14KIT/research-sdd/toolbelt" "$ROOT/sl14reg"
cp -r "$HERE/../lib" "$SL14KIT/research-sdd/toolbelt/lib"
cp "$HERE/../stage-retro-issues.sh" "$HERE/../verify-retro.sh" "$SL14KIT/research-sdd/toolbelt/"
cp "$SUT" "$SL14KIT/research-sdd/toolbelt/retro-gate.sh"
printf '| # | Target | Path |\n|---|---|---|\n| 1 | fixture-target | `%s` |\n' "$ROOT/sl14reg" > "$SL14KIT/research-sdd/TARGETS.md"
TSL14="$ROOT/sl14"; mk_sl_conforming "$TSL14" sl14
mkdir -p "$ROOT/sl14bin"   # gh stub: auth ok, dedup search -> empty JSON array, everything else exit 0
printf '#!/usr/bin/env bash\ncase "${1:-} ${2:-}" in "issue list") echo "[]";; esac\nexit 0\n' > "$ROOT/sl14bin/gh"; chmod +x "$ROOT/sl14bin/gh"
OUT="$(printf '%s' "$(mkjson sl14 false)" | env -u RESEARCH_HOME HOME="$ROOT/sl14home" RESEARCH_SDD_ISSUE_REPO=o/r PATH="$ROOT/sl14bin:$PATH" "$BASH_BIN" "$SL14KIT/research-sdd/toolbelt/retro-gate.sh" "$TSL14" 2>"$ROOT/sl14.err")"; RC=$?
if [ "$RC" -eq 0 ] && sl_last "$TSL14" | grep -qF 'seeder-degraded:2026-09-05-sl.md:degraded: target'; then
  ok "#1258 SL14: real seeder's unregistered-target degraded is logged typed; exit 0 (hermetic kit, no HOME)"
else no "#1258 SL14: rc=$RC log=$(sl_last "$TSL14") err=$(cat "$ROOT/sl14.err")"; fi

# ─── #1167 item 7 / case-count stability ─────────────────────────────────────
# The suite's case count must not silently differ between hosts. Conditional cases are:
#   * TOOTH 12 (running as root → 2 cases) — already emits two '  SKIP  ' lines;
#   * the teeth git-clean guard (live tree not under git → was ONE silently missing case,
#     the 146-vs-147 difference observed between hosts) — now emits a '  SKIP  ' line;
#   * the jq round-trip case above (jq absent).
# Every conditional case therefore appears as PASS/FAIL or as a counted '  SKIP  ' line.

# ─── TEETH (--prove-teeth) ───────────────────────────────────────────────────
PROVE_TEETH="${1:-}"
[ "$PROVE_TEETH" != "--prove-teeth" ] && {
  echo
  echo "== $pass passed · $fail failed =="
  [ "$fail" -eq 0 ] && exit 0 || exit 1
}

echo
echo "-- TEETH: mutation controls --"

# Capture git state before any teeth mutation so the git-clean guard can diff
_GIT_BEFORE_TEETH=""
_GIT_ROOT_FOR_TEETH="$(git -C "$HERE" rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$_GIT_ROOT_FOR_TEETH" ] && _GIT_BEFORE_TEETH="$(git -C "$_GIT_ROOT_FOR_TEETH" status --porcelain 2>/dev/null || true)"

# Kit sandbox for mutants: mutant must live under a toolbelt/ dir so that
# SELF_DIR-relative lib paths (lib/block-files.sh, lib/retro-status.sh,
# verify-retro.sh) resolve correctly — the same constraint the real SUT has.
MUT_KIT="$ROOT/mutkit"
mkdir -p "$MUT_KIT/toolbelt/lib"
cp "$HERE/../lib/block-files.sh"   "$MUT_KIT/toolbelt/lib/"
cp "$HERE/../lib/retro-status.sh"  "$MUT_KIT/toolbelt/lib/"
cp "$HERE/../lib/retro-grammar.sh" "$MUT_KIT/toolbelt/lib/"
cp "$VR" "$MUT_KIT/toolbelt/verify-retro.sh"
# stage-retro-issues.sh (the seeder) must exist too — _run_issue_seeding bails out before
# reaching its retro loop (and therefore before _retro_is_seedable's WARN) when it is absent.
cp "$HERE/../stage-retro-issues.sh" "$MUT_KIT/toolbelt/stage-retro-issues.sh"

# mkmutant <name> <from-sentinel> <to-sentinel>: remove sentinel block from SUT
mkmutant() {
  local name="$1" from="$2" to="$3"
  local m="$MUT_KIT/toolbelt/mutant-${name}.sh"
  sed "/# ${from}/,/# ${to}/d" "$SUT" > "$m"; chmod +x "$m"
  printf '%s' "$m"
}

# ── TOOTH 1: blocks-twice — mutant ignores block-once state file ──────────────
M1="$(mkmutant 'blocks-twice' 'SENTINEL-BLOCK-ONCE-START' 'SENTINEL-BLOCK-ONCE-END')"
TM1="$ROOT/m1"; mkgit "$TM1"; SM1="m1-sess"
mksessionfile "$TM1" "$SM1" "202609050800"
mkblock "$TM1" "niagara-block1.md" "2026-09-05T10:00:00"
_jm1="$(mkjson "$SM1" "false")"
# First call: should block and create state file
run_mutant "$M1" "$TM1" "$_jm1"
# Second call: mutant ignores state file → should block again (RED = expected)
run_mutant "$M1" "$TM1" "$_jm1"
printf '%s' "$OUT" | grep -qF '"decision":"block"' \
  && ok "TOOTH blocks-twice: mutant blocks second call (RED as expected)" \
  || no "TOOTH blocks-twice: mutant should have blocked second call but did not"

# ── TOOTH 2: allows-unmarked — mutant skips verify-retro check ───────────────
M2="$(mkmutant 'allows-unmarked' 'SENTINEL-VERIFY-RETRO-START' 'SENTINEL-VERIFY-RETRO-END')"
TM2="$ROOT/m2"; mkgit "$TM2"; SM2="m2-sess"
mksessionfile "$TM2" "$SM2" "202609050800"
mkblock "$TM2" "niagara-block1.md" "2026-09-05T10:00:00"
touch -t 202609051000 "$TM2/niagara-block1.md"
mkretro "$TM2" "2026-09-05-bad-retro.md" 0
touch -t 202609051200 "$TM2/retros/2026-09-05-bad-retro.md"
_jm2="$(mkjson "$SM2" "false")"
run_mutant "$M2" "$TM2" "$_jm2"
# Mutant allows even though retro is non-conforming → should NOT block (RED = allows)
printf '%s' "$OUT" | grep -qF '"decision":"block"' \
  && no "TOOTH allows-unmarked: mutant should ALLOW non-conforming retro (RED) but it blocked" \
  || ok "TOOTH allows-unmarked: mutant allows non-conforming retro (RED as expected)"

# ── TOOTH 3: ignores-stop_hook_active — mutant skips loop-breaker ────────────
M3="$(mkmutant 'ignores-stop_hook_active' 'SENTINEL-STOP-HOOK-ACTIVE-START' 'SENTINEL-STOP-HOOK-ACTIVE-END')"
TM3="$ROOT/m3"; mkgit "$TM3"; SM3="m3-sess"
mksessionfile "$TM3" "$SM3" "202609050800"
mkblock "$TM3" "niagara-block1.md" "2026-09-05T10:00:00"
_jm3="$(mkjson "$SM3" "true")"  # stop_hook_active=true
run_mutant "$M3" "$TM3" "$_jm3"
# Mutant should block despite stop_hook_active=true (RED = expected)
printf '%s' "$OUT" | grep -qF '"decision":"block"' \
  && ok "TOOTH ignores-stop_hook_active: mutant blocks despite stop_hook_active=true (RED as expected)" \
  || no "TOOTH ignores-stop_hook_active: mutant should block but allowed; check SENTINEL placement"

# ── TOOTH 4: reason-not-actionable — mutant reduces reason to bare text ───────
# awk keeps sentinel boundary comments, replaces content between them with a bare
# reason. Both SENTINEL-ACTIONABLE-REASON blocks get the bare assignment; the test
# uses the _nr_mtime==0 branch (no retro), so only the first assignment runs.
M4="$MUT_KIT/toolbelt/mutant-reason.sh"
# Sentinels inside if-blocks are indented (2 spaces) — match without ^ anchor
awk '
  /# SENTINEL-ACTIONABLE-REASON-START/ { in_r=1; print; print "  _block_reason=\"retro pending\""; next }
  /# SENTINEL-ACTIONABLE-REASON-END/ { in_r=0; print; next }
  in_r { next }
  { print }
' "$SUT" > "$M4"; chmod +x "$M4"
TM4="$ROOT/m4"; mkgit "$TM4"; SM4="m4-sess"
mksessionfile "$TM4" "$SM4" "202609050800"
mkblock "$TM4" "niagara-block1.md" "2026-09-05T10:00:00"
_jm4="$(mkjson "$SM4" "false")"
run_mutant "$M4" "$TM4" "$_jm4"
# Mutant reason lacks template reference (RED = expected: not actionable)
printf '%s' "$OUT" | grep -qF 'retro.template.md' \
  && no "TOOTH reason-not-actionable: mutant should lack template ref but it was present" \
  || ok "TOOTH reason-not-actionable: mutant reason lacks template ref (RED as expected)"

# ── TOOTH 5: degraded-stderr-dropped — mutant removes jq probe (no degraded line) ─
# Mutant: SENTINEL-JQ-PROBE-START…END removed → no degraded stderr on no-jq path.
# Precondition guard: NOJQ_PATH must hide jq or the mutant runs with jq present and
# the assertion is vacuous (mutant behaves normally, not silently).
M5="$(mkmutant 'degraded-stderr-dropped' 'SENTINEL-JQ-PROBE-START' 'SENTINEL-JQ-PROBE-END')"
TM5="$ROOT/m5"; mkgit "$TM5"; SM5="m5-sess"
mksessionfile "$TM5" "$SM5" "202609050800"
mkblock "$TM5" "niagara-block1.md" "2026-09-05T10:00:00"
_jm5="$(mkjson "$SM5" "false")"
if PATH="$NOJQ_PATH" command -v jq >/dev/null 2>&1; then
  no "PRECOND(TOOTH5): NOJQ_PATH still resolves jq — simulation broken, TOOTH 5 skipped"
else
  run_mutant_nojq "$M5" "$TM5" "$_jm5"
  # Mutant has no probe → no 'branch=degraded' in stderr (RED as expected)
  printf '%s' "$ERR" | grep -q 'branch=degraded' \
    && no "TOOTH degraded-stderr-dropped: mutant should NOT emit degraded line but it did" \
    || ok "TOOTH degraded-stderr-dropped: mutant silent (no degraded stderr) — RED as expected"
fi

# ── TOOTH 6: jq-emitter-reverted — mutant removes both probe+emitter sentinels ──
# Mutant: no probe (no early exit on jq-absent) AND reverts to jq-cn emitter.
# With jq absent, the reverted jq-cn fails silently → no block JSON on stdout.
# Precondition guard: NOJQ_PATH must hide jq or the mutant runs jq-cn successfully
# and the assertion is vacuous (block JSON present when it should be absent).
M6="$MUT_KIT/toolbelt/mutant-jq-emitter.sh"
sed "/# SENTINEL-JQ-PROBE-START/,/# SENTINEL-JQ-PROBE-END/d" "$SUT" | \
awk '
  /# SENTINEL-PURE-BASH-EMITTER-START/ { in_e=1; print; next }
  /# SENTINEL-PURE-BASH-EMITTER-END/ { in_e=0;
    print "  jq -cn --arg reason \"$_block_reason\" '"'"'{\"decision\":\"block\",\"reason\":$reason}'"'"'";
    print; next }
  in_e { next }
  { print }
' > "$M6"; chmod +x "$M6"
TM6="$ROOT/m6"; mkgit "$TM6"; SM6="m6-sess"
mksessionfile "$TM6" "$SM6" "202609050800"
mkblock "$TM6" "niagara-block1.md" "2026-09-05T10:00:00"
_jm6="$(mkjson "$SM6" "false")"
if PATH="$NOJQ_PATH" command -v jq >/dev/null 2>&1; then
  no "PRECOND(TOOTH6): NOJQ_PATH still resolves jq — simulation broken, TOOTH 6 skipped"
else
  run_mutant_nojq "$M6" "$TM6" "$_jm6"
  # Mutant: jq-cn fails silently → no block JSON on stdout (RED = silent allow)
  printf '%s' "$OUT" | grep -qF '"decision":"block"' \
    && no "TOOTH jq-emitter-reverted: mutant should produce no block JSON (no jq) but it did" \
    || ok "TOOTH jq-emitter-reverted: mutant silent block (no jq-cn output) — RED as expected"
fi

# ── EN3 TOOTH 7: seeding-not-called — mutant removes seeding call sentinel ────
# Mutant: SENTINEL-SEEDING-CALL-START…END removed → _run_issue_seeding never invoked
# → stub not called → seed log stays empty → RED as expected.
M7="$(mkmutant 'seeding-not-called' 'SENTINEL-SEEDING-CALL-START' 'SENTINEL-SEEDING-CALL-END')"
# Add stub seeder and mock gh to MUT_KIT so SELF_DIR-relative KIT path resolves
cat > "$MUT_KIT/toolbelt/stage-retro-issues.sh" << 'STUBEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${SEED_LOG:-/dev/null}"
exit 0
STUBEOF
chmod +x "$MUT_KIT/toolbelt/stage-retro-issues.sh"
mkdir -p "$ROOT/mockbin2"
cat > "$ROOT/mockbin2/gh" << 'GHEOF'
#!/usr/bin/env bash
exit 0
GHEOF
chmod +x "$ROOT/mockbin2/gh"
TM7="$ROOT/m7"; mkgit "$TM7"; SM7="m7-sess"
mksessionfile "$TM7" "$SM7" "202609050800"
mkblock "$TM7" "niagara-block1.md" "2026-09-05T10:00:00"
touch -t 202609051000 "$TM7/niagara-block1.md"
mkretro "$TM7" "2026-09-05-good-retro.md" 1
touch -t 202609051200 "$TM7/retros/2026-09-05-good-retro.md"
_jm7="$(mkjson "$SM7" "false")"
_seed_log7="$ROOT/seed7.log"; rm -f "$_seed_log7"
errf_m7="$ROOT/merr_m7"
OUT="$(printf '%s' "$_jm7" | SEED_LOG="$_seed_log7" \
  PATH="$ROOT/mockbin2:$PATH" "$BASH_BIN" "$M7" "$TM7" 2>"$errf_m7")"; RC=$?
rm -f "$errf_m7"
# Mutant has no seeding call → stub not called → seed log absent/empty
if [ -f "$_seed_log7" ] && grep -qF -- '--apply' "$_seed_log7"; then
  no "TOOTH seeding-not-called: mutant should NOT call stub but --apply found in log"
else
  ok "TOOTH seeding-not-called: mutant seed log empty — RED as expected"
fi

# ── EN3 TOOTH 8: gh-probe-dropped — mutant removes gh probe sentinel ──────────
# Mutant: SENTINEL-GH-PROBE-START…END removed → no WARN emitted when gh unavailable
# → EN3-c WARN assertion fails → RED as expected.
M8="$(mkmutant 'gh-probe-dropped' 'SENTINEL-GH-PROBE-START' 'SENTINEL-GH-PROBE-END')"
TM8="$ROOT/m8"; mkgit "$TM8"; SM8="m8-sess"
mksessionfile "$TM8" "$SM8" "202609050800"
mkblock "$TM8" "niagara-block1.md" "2026-09-05T10:00:00"
touch -t 202609051000 "$TM8/niagara-block1.md"
mkretro "$TM8" "2026-09-05-good-retro.md" 1
touch -t 202609051200 "$TM8/retros/2026-09-05-good-retro.md"
_jm8="$(mkjson "$SM8" "false")"
# MUT_KIT stub seeder (already added above) exits 0 regardless of gh state
errf_m8="$ROOT/merr_m8"
_seed_log8="$ROOT/seed8.log"; rm -f "$_seed_log8"
# Use fail-auth gh: with probe removed, no WARN from the hook itself
OUT="$(printf '%s' "$_jm8" | SEED_LOG="$_seed_log8" \
  PATH="$FAIL_AUTH_GH_DIR:$PATH" "$BASH_BIN" "$M8" "$TM8" 2>"$errf_m8")"; RC=$?
ERR_M8="$(cat "$errf_m8")"; rm -f "$errf_m8"
# Mutant: no probe → no 'retro-gate: WARN: gh' on stderr
printf '%s' "$ERR_M8" | grep -qF 'retro-gate: WARN: gh' \
  && no "TOOTH gh-probe-dropped: mutant should NOT emit gh WARN but it did: $ERR_M8" \
  || ok "TOOTH gh-probe-dropped: mutant emits no gh WARN — RED as expected"

# ── TOOTH 9: nojq-path-dirname-leak — dirname logic leaks jq via duplicate dirs ──
# Reproduce the CI condition: jq is reachable through TWO PATH entries that resolve
# to the same underlying directory (like /bin→/usr/bin on Ubuntu).
# Shows: old dirname-only logic leaks jq (RED); new hermetic logic hides it (GREEN);
# and the precondition guard fires against the leaky PATH (mutation evidence).
_T9_REAL="$ROOT/tooth9_real"   # real dir with jq stub + an unrelated tool
_T9_LINK="$ROOT/tooth9_link"   # symlink → same dir, simulating /bin→/usr/bin
mkdir -p "$_T9_REAL"
ln -s "$_T9_REAL" "$_T9_LINK"
printf '#!/usr/bin/env bash\necho stub-jq\n' > "$_T9_REAL/jq"; chmod +x "$_T9_REAL/jq"
printf '#!/usr/bin/env bash\necho stub-grep\n' > "$_T9_REAL/grep"; chmod +x "$_T9_REAL/grep"

# Simulated PATH: jq accessible via both _T9_REAL and _T9_LINK (same underlying dir)
_T9_PATH="$_T9_REAL:$_T9_LINK"

# OLD logic: dirname removal strips only _T9_REAL; _T9_LINK (same dir) still leaks jq
_T9_OLD_PATH=""
_oifs="$IFS"; IFS=':'
for _pd in $_T9_PATH; do
  IFS="$_oifs"
  [ "$_pd" = "$_T9_REAL" ] && continue
  _T9_OLD_PATH="${_T9_OLD_PATH:+$_T9_OLD_PATH:}$_pd"
done
IFS="$_oifs"

# Old logic should leak jq through _T9_LINK (RED = precondition fires = old logic broken)
if PATH="$_T9_OLD_PATH" command -v jq >/dev/null 2>&1; then
  ok "TOOTH nojq-path-dirname-leak: old dirname logic leaks jq via duplicate dir (RED as expected)"
else
  no "TOOTH nojq-path-dirname-leak: old logic should leak jq but did not — tooth broken"
fi

# NEW hermetic logic: call the shared build_hermetic_nojq_bin function against the duplicate-dir
# fixture (_T9_PATH).  TOOTH 9 exercises the real function — not its own inline copy — so any
# regression in the builder is caught here (#910 refactor: one function, two call sites).
_T9_NEW_BIN="$ROOT/tooth9_new_bin"
mkdir -p "$_T9_NEW_BIN"
build_hermetic_nojq_bin "$_T9_PATH" "$_T9_NEW_BIN"

# New logic must hide jq (GREEN)
if PATH="$_T9_NEW_BIN" command -v jq >/dev/null 2>&1; then
  no "TOOTH nojq-path-dirname-leak: new hermetic logic should hide jq but leaked"
else
  ok "TOOTH nojq-path-dirname-leak: new hermetic logic hides jq — GREEN as expected"
fi

# Precondition guard fires against old leaky PATH (mutation evidence):
# if we were to run test 7 with _T9_OLD_PATH instead of NOJQ_PATH, the guard triggers
if PATH="$_T9_OLD_PATH" command -v jq >/dev/null 2>&1; then
  ok "TOOTH nojq-path-dirname-leak: precondition guard would fire on old dirname PATH (mutation confirms)"
else
  no "TOOTH nojq-path-dirname-leak: old dirname PATH unexpectedly hides jq — mutation check broken"
fi

# ── TOOTH 10: seeder-rc-swallowed — awk replaces SENTINEL-SEEDER-RC block with '|| true' ─
# Mutant: the entire sentinel block (rc check, counting, WARN) is replaced by a bare
# '|| true' seeder call — seeder rc is swallowed, counts are never taken, WARN never emitted.
M10_FIXED="$ROOT/mut_tooth10.sh"
awk '
  /# SENTINEL-SEEDER-RC-START/ { skip=1; print "    seed_out=\"$(bash \"$seeder\" \"$rf\" --apply 2>&1)\" || true"; next }
  /# SENTINEL-SEEDER-RC-END/   { skip=0; next }
  skip { next }
  { print }
' "$SUT" > "$M10_FIXED"
chmod +x "$M10_FIXED"

# Pre-check: awk must have changed the file; a byte-identical diff means the sentinel was not found.
if diff -q "$SUT" "$M10_FIXED" >/dev/null 2>&1; then
  no "TOOTH 10 pre-check: mutant identical to SUT — awk did not match SENTINEL-SEEDER-RC-START"
else
  ok "TOOTH 10 pre-check: mutant differs from SUT (sentinel found and replaced)"
fi

# Sabotage: renaming the sentinel in a SUT copy must make the awk produce no change.
# This proves the tooth would FAIL (diff empty → sentinel rename breaks the mutant).
SUT_SAB10="$ROOT/sut_sabotage_t10.sh"
MUT_SAB10="$ROOT/mut_sabotage_t10.sh"
# Rename BOTH sentinels so the awk matches neither; diff must be empty (no-op rewrite).
sed 's/SENTINEL-SEEDER-RC-START/SENTINEL-SEEDER-RC-GONE/;
     s/SENTINEL-SEEDER-RC-END/SENTINEL-SEEDER-RC-GONE-END/' "$SUT" > "$SUT_SAB10"
awk '
  /# SENTINEL-SEEDER-RC-START/ { skip=1; print "    seed_out=\"$(bash \"$seeder\" \"$rf\" --apply 2>&1)\" || true"; next }
  /# SENTINEL-SEEDER-RC-END/   { skip=0; next }
  skip { next }
  { print }
' "$SUT_SAB10" > "$MUT_SAB10"
if diff -q "$SUT_SAB10" "$MUT_SAB10" >/dev/null 2>&1; then
  ok "TOOTH 10 sabotage: renamed sentinels → awk produces no diff (tooth would fail as expected)"
else
  no "TOOTH 10 sabotage: renamed sentinels → awk still matched — sabotage test is broken"
fi

# Deploy mutant and run with failing seeder
cp "$M10_FIXED" "$MUT_KIT/toolbelt/retro-gate-m10.sh"
cat > "$MUT_KIT/toolbelt/stage-retro-issues.sh" << 'FAILEOF2'
#!/usr/bin/env bash
printf 'seeder: error: API rate limit exceeded\n' >&2
exit 1
FAILEOF2
chmod +x "$MUT_KIT/toolbelt/stage-retro-issues.sh"

TM10="$ROOT/m10"; mkgit "$TM10"; SM10="m10-sess"
mksessionfile "$TM10" "$SM10" "202609050800"
mkblock "$TM10" "niagara-block1.md" "2026-09-05T10:00:00"
touch -t 202609051000 "$TM10/niagara-block1.md"
mkretro "$TM10" "2026-09-05-m10.md" 1
touch -t 202609051200 "$TM10/retros/2026-09-05-m10.md"
_jm10="$(mkjson "$SM10" "false")"
errf_m10="$ROOT/merr_m10"
OUT="$(printf '%s' "$_jm10" | PATH="$ROOT/mockbin2:$PATH" \
  "$BASH_BIN" "$MUT_KIT/toolbelt/retro-gate-m10.sh" "$TM10" 2>"$errf_m10")"; RC=$?
ERR_M10="$(cat "$errf_m10")"; rm -f "$errf_m10"
# Positive: loop ran and emitted the issue-seeding: summary line (loop-reached proof)
if printf '%s' "$ERR_M10" | grep -q 'issue-seeding:'; then
  ok "TOOTH seeder-rc-swallowed: loop ran and reached issue-seeding: summary"
else
  no "TOOTH seeder-rc-swallowed: issue-seeding: line absent — mutant exited before the loop"
fi
# Positive: mutant shows failed=0 — EN3-e 'failed=1' assertion would go RED
if printf '%s' "$ERR_M10" | grep -q 'failed=0'; then
  ok "TOOTH seeder-rc-swallowed: mutant shows failed=0 (EN3-e failed=1 assertion would fail — RED)"
else
  no "TOOTH seeder-rc-swallowed: mutant shows failed≠0 — tooth has no bite"
fi
# Absence: mutant must not emit WARN — EN3-e WARN assertion would go RED
if printf '%s' "$ERR_M10" | grep -q 'WARN.*seeder failed'; then
  no "TOOTH seeder-rc-swallowed: mutant emitted WARN — tooth has no bite"
else
  ok "TOOTH seeder-rc-swallowed: mutant did NOT emit WARN (EN3-e WARN assertion would fail — RED)"
fi

# ── TOOTH 11: aggregate-warn-dropped — mkmutant removes SENTINEL-AGGREGATE-WARN block ─
# Mutant: aggregate WARN block is removed → when multiple seeders fail, gate emits
# no aggregate WARN → EN3-944 'issue create(s) failed across N retro(s)' assertion would go RED.
M11="$(mkmutant 'aggregate-warn-dropped' 'SENTINEL-AGGREGATE-WARN-START' 'SENTINEL-AGGREGATE-WARN-END')"

# Pre-check: sentinel found → mutant differs from SUT
if diff -q "$SUT" "$M11" >/dev/null 2>&1; then
  no "TOOTH 11 pre-check: mutant identical to SUT — SENTINEL-AGGREGATE-WARN-START not found"
else
  ok "TOOTH 11 pre-check: mutant differs from SUT (sentinel found)"
fi

# Sabotage: rename both sentinels → awk produces no diff
SUT_SAB11="$ROOT/sut_sab11.sh"
MUT_SAB11="$ROOT/mut_sab11.sh"
sed 's/SENTINEL-AGGREGATE-WARN-START/SENTINEL-AGGREGATE-WARN-GONE/;
     s/SENTINEL-AGGREGATE-WARN-END/SENTINEL-AGGREGATE-WARN-GONE-END/' "$SUT" > "$SUT_SAB11"
sed "/# SENTINEL-AGGREGATE-WARN-START/,/# SENTINEL-AGGREGATE-WARN-END/d" "$SUT_SAB11" > "$MUT_SAB11"
if diff -q "$SUT_SAB11" "$MUT_SAB11" >/dev/null 2>&1; then
  ok "TOOTH 11 sabotage: renamed sentinels → no diff (tooth would fail — as expected)"
else
  no "TOOTH 11 sabotage: renamed sentinels → awk still matched — sabotage broken"
fi

# Deploy mutant with 2-retro target: both seeders fail → aggregate WARN expected on real SUT
cat > "$MUT_KIT/toolbelt/stage-retro-issues.sh" << 'FAILEOF3'
#!/usr/bin/env bash
printf 'seeder: error: no auth\n' >&2
exit 1
FAILEOF3
chmod +x "$MUT_KIT/toolbelt/stage-retro-issues.sh"
cp "$M11" "$MUT_KIT/toolbelt/retro-gate-m11.sh"

TM11="$ROOT/m11"; mkgit "$TM11"; SM11="m11-sess"
mksessionfile "$TM11" "$SM11" "202609050800"
mkblock "$TM11" "niagara-block11.md" "2026-09-05T10:00:00"
touch -t 202609051000 "$TM11/niagara-block11.md"
mkretro "$TM11" "2026-09-05-m11a.md" 1
mkretro "$TM11" "2026-09-05-m11b.md" 1
touch -t 202609051200 "$TM11/retros/2026-09-05-m11a.md"
touch -t 202609051200 "$TM11/retros/2026-09-05-m11b.md"
_jm11="$(mkjson "$SM11" "false")"
errf_m11="$ROOT/merr_m11"
OUT="$(printf '%s' "$_jm11" | PATH="$ROOT/mockbin2:$PATH" \
  "$BASH_BIN" "$MUT_KIT/toolbelt/retro-gate-m11.sh" "$TM11" 2>"$errf_m11")"; RC=$?
ERR_M11="$(cat "$errf_m11")"; rm -f "$errf_m11"
# Mutant: no aggregate WARN → gate emits no 'issue create(s) failed across' line
if printf '%s' "$ERR_M11" | grep -q 'issue create(s) failed across'; then
  no "TOOTH 11 aggregate-warn-dropped: mutant emitted aggregate WARN — tooth has no bite"
else
  ok "TOOTH 11 aggregate-warn-dropped: mutant did NOT emit aggregate WARN (RED as expected)"
fi
# Positive: mutant still emits issue-seeding: summary (loop ran)
if printf '%s' "$ERR_M11" | grep -q 'issue-seeding:'; then
  ok "TOOTH 11 aggregate-warn-dropped: mutant still emits issue-seeding: summary (loop ran)"
else
  no "TOOTH 11 aggregate-warn-dropped: issue-seeding: absent — mutant may have crashed"
fi

# ── TOOTH 12: find-stderr-suppressed — awk adds 2>/dev/null to find invocation ─
# Mutant: find stderr is suppressed → traversal errors (§7 signals) silently swallowed.
# Note: main-body find calls already carry 2>/dev/null; only the seeding find propagates errors.
# Behavioral test: inaccessible subdir under target retros → seeding find emits Permission denied.
#   Real SUT (no 2>/dev/null): error in gate stderr.
#   Mutant (2>/dev/null added): error suppressed → RED.
# Skipped when running as root (chmod 000 does not protect root access).

# Mutant: adds 2>/dev/null inside the seeding find process substitution.
# Targets the -iname line (last line of the find, ends with ')') that has no
# existing 2>/dev/null — leaves find working while suppressing traversal errors.
M12="$ROOT/mut_tooth12.sh"
awk '
  /-iname/ && !/2>\/dev\/null/ { sub(/\)$/, " 2>/dev/null)"); print; next }
  { print }
' "$SUT" > "$M12"
chmod +x "$M12"

# Pre-check: awk matched the find line → mutant differs from SUT
if diff -q "$SUT" "$M12" >/dev/null 2>&1; then
  no "TOOTH 12 pre-check: mutant identical to SUT — awk did not match -iname line"
else
  ok "TOOTH 12 pre-check: mutant differs from SUT (-iname line matched)"
fi

# Sabotage: rename -iname → awk produces no diff (proves the awk targets -iname)
SUT_SAB12="$ROOT/sut_sab12.sh"
MUT_SAB12="$ROOT/mut_sab12.sh"
sed 's/-iname/-INAME-GONE/g' "$SUT" > "$SUT_SAB12"
awk '
  /-iname/ && !/2>\/dev\/null/ { sub(/\)$/, " 2>/dev/null)"); print; next }
  { print }
' "$SUT_SAB12" > "$MUT_SAB12"
if diff -q "$SUT_SAB12" "$MUT_SAB12" >/dev/null 2>&1; then
  ok "TOOTH 12 sabotage: -iname renamed → no diff (tooth would fail — as expected)"
else
  no "TOOTH 12 sabotage: -iname renamed → awk still matched — sabotage broken"
fi

if [ "$(id -u)" -ne 0 ]; then
  TM12="$ROOT/m12"; mkgit "$TM12"; SM12="m12-sess"
  mksessionfile "$TM12" "$SM12" "202609050800"
  mkblock "$TM12" "niagara-block12.md" "2026-09-05T10:00:00"
  touch -t 202609051000 "$TM12/niagara-block12.md"
  mkretro "$TM12" "2026-09-05-m12.md" 1
  touch -t 202609051200 "$TM12/retros/2026-09-05-m12.md"
  # Inaccessible subdir: seeding find (no 2>/dev/null) will emit Permission denied for it
  mkdir -p "$TM12/retros/inaccessible-tooth12"
  chmod 000 "$TM12/retros/inaccessible-tooth12"
  _jm12="$(mkjson "$SM12" "false")"
  cat > "$MUT_KIT/toolbelt/stage-retro-issues.sh" << 'SUMEOF3'
#!/usr/bin/env bash
printf 'summary: created=0 skipped-duplicate=0 skipped-shipped=0 skipped-wrong-kit=0\n'
exit 0
SUMEOF3
  chmod +x "$MUT_KIT/toolbelt/stage-retro-issues.sh"
  # Real SUT: seeding find error propagates to gate stderr
  cp "$SUT" "$MUT_KIT/toolbelt/retro-gate-m12-sut.sh"
  errf_m12_sut="$ROOT/merr_m12_sut"
  OUT="$(printf '%s' "$_jm12" | PATH="$ROOT/mockbin2:$PATH" \
    "$BASH_BIN" "$MUT_KIT/toolbelt/retro-gate-m12-sut.sh" "$TM12" 2>"$errf_m12_sut")"; RC=$?
  ERR_M12_SUT="$(cat "$errf_m12_sut")"; rm -f "$errf_m12_sut"
  if printf '%s' "$ERR_M12_SUT" | grep -qi 'permission denied\|inaccessible'; then
    ok "TOOTH 12 find-stderr-suppressed: real SUT — find traversal error in gate stderr (precondition)"
  else
    no "TOOTH 12 find-stderr-suppressed: real SUT — traversal error absent; tooth setup broken; got: $ERR_M12_SUT"
  fi
  # Mutant: seeding find error suppressed by 2>/dev/null
  cp "$M12" "$MUT_KIT/toolbelt/retro-gate-m12.sh"
  errf_m12="$ROOT/merr_m12"
  OUT="$(printf '%s' "$_jm12" | PATH="$ROOT/mockbin2:$PATH" \
    "$BASH_BIN" "$MUT_KIT/toolbelt/retro-gate-m12.sh" "$TM12" 2>"$errf_m12")"; RC=$?
  ERR_M12="$(cat "$errf_m12")"; rm -f "$errf_m12"
  if printf '%s' "$ERR_M12" | grep -qi 'permission denied\|inaccessible'; then
    no "TOOTH 12 find-stderr-suppressed: mutant — traversal error still in stderr; 2>/dev/null had no effect"
  else
    ok "TOOTH 12 find-stderr-suppressed: mutant suppresses seeding find stderr (RED as expected)"
  fi
  # Cleanup inaccessible dir (restore permissions before rmdir)
  chmod 755 "$TM12/retros/inaccessible-tooth12" 2>/dev/null || true
  rmdir "$TM12/retros/inaccessible-tooth12" 2>/dev/null || true
else
  printf '  SKIP  TOOTH 12 find-stderr-suppressed (running as root — chmod 000 does not protect)\n'
  printf '  SKIP  TOOTH 12 find-stderr-suppressed: mutant suppresses seeding find stderr\n'
fi

# ── TOOTH 13: typed-outcome-dropped — mkmutant removes SENTINEL-TYPED-OUTCOME block ─
# Mutant: typed-outcome recognition removed → absent-input: falls through to else
# (absent-summary WARN branch), absent counter stays 0 → EN3-absent assertions go RED.
# Stub emits absent-input: to stderr (real seeder: search absent-input: retro not found).
M13="$(mkmutant 'typed-outcome-dropped' 'SENTINEL-TYPED-OUTCOME-START' 'SENTINEL-TYPED-OUTCOME-END')"

# Pre-check: sentinel found → mutant differs from SUT
if diff -q "$SUT" "$M13" >/dev/null 2>&1; then
  no "TOOTH 13 pre-check: mutant identical to SUT — SENTINEL-TYPED-OUTCOME-START not found"
else
  ok "TOOTH 13 pre-check: mutant differs from SUT (sentinel found)"
fi

# Bash-n syntax check: mutant must be valid shell (mkmutant sed delete)
if ! bash -n "$M13" 2>/dev/null; then
  no "TOOTH 13 pre-check: mutant fails bash -n — sentinel removal broke shell syntax"
else
  ok "TOOTH 13 pre-check: mutant passes bash -n (valid shell)"
fi

# Sabotage: rename both sentinels → mkmutant produces no diff
SUT_SAB13="$ROOT/sut_sab13.sh"
MUT_SAB13="$ROOT/mut_sab13.sh"
sed 's/SENTINEL-TYPED-OUTCOME-START/SENTINEL-TYPED-OUTCOME-GONE/;
     s/SENTINEL-TYPED-OUTCOME-END/SENTINEL-TYPED-OUTCOME-GONE-END/' "$SUT" > "$SUT_SAB13"
sed "/# SENTINEL-TYPED-OUTCOME-START/,/# SENTINEL-TYPED-OUTCOME-END/d" "$SUT_SAB13" > "$MUT_SAB13"
if diff -q "$SUT_SAB13" "$MUT_SAB13" >/dev/null 2>&1; then
  ok "TOOTH 13 sabotage: renamed sentinels → no diff (tooth would fail — as expected)"
else
  no "TOOTH 13 sabotage: renamed sentinels → sed still matched — sabotage broken"
fi

# Behavioral: absent-input: stub (stderr, cite: absent-input: retro not found) →
# mutant drops typed-outcome check → absent counter stays 0, wrong WARN fires →
# EN3-absent assertions go RED.
cat > "$MUT_KIT/toolbelt/stage-retro-issues.sh" << 'ABSENTIN13'
#!/usr/bin/env bash
# absent-input path — real seeder: search absent-input: retro not found
printf 'absent-input: retro not found: retro.md\n' >&2
exit 1
ABSENTIN13
chmod +x "$MUT_KIT/toolbelt/stage-retro-issues.sh"
cp "$M13" "$MUT_KIT/toolbelt/retro-gate-m13.sh"
TM13="$ROOT/m13"; mkgit "$TM13"; SM13="m13-sess"
mksessionfile "$TM13" "$SM13" "202609050800"
mkblock "$TM13" "niagara-block13.md" "2026-09-05T10:00:00"
touch -t 202609051000 "$TM13/niagara-block13.md"
mkretro "$TM13" "2026-09-05-m13.md" 1
touch -t 202609051200 "$TM13/retros/2026-09-05-m13.md"
_jm13="$(mkjson "$SM13" "false")"
errf_m13="$ROOT/merr_m13"
OUT="$(printf '%s' "$_jm13" | PATH="$ROOT/mockbin2:$PATH" \
  "$BASH_BIN" "$MUT_KIT/toolbelt/retro-gate-m13.sh" "$TM13" 2>"$errf_m13")"; RC=$?
ERR_M13="$(cat "$errf_m13")"; rm -f "$errf_m13"
# Positive: loop ran and emitted issue-seeding: summary (crash → no output → this FAILS tooth)
if printf '%s' "$ERR_M13" | grep -q 'issue-seeding:'; then
  ok "TOOTH 13 typed-outcome-dropped: loop ran and emitted issue-seeding: summary (loop-reached proof)"
else
  no "TOOTH 13 typed-outcome-dropped: issue-seeding: absent — mutant may have crashed (tooth invalid)"
fi
# Positive: mutant emits wrong WARN ('no summary:' or 'seeder failed') not absent-input WARN
if printf '%s' "$ERR_M13" | grep -q 'WARN.*absent-input'; then
  no "TOOTH 13 typed-outcome-dropped: mutant emits absent-input WARN — tooth has no bite"
else
  ok "TOOTH 13 typed-outcome-dropped: mutant does NOT emit absent-input WARN (wrong path — RED as expected)"
fi
# Negative: absent=1 must NOT appear in mutant output (absent counter not incremented)
if printf '%s' "$ERR_M13" | grep -q 'absent=1'; then
  no "TOOTH 13 typed-outcome-dropped: mutant reports absent=1 — tooth has no bite"
else
  ok "TOOTH 13 typed-outcome-dropped: mutant does not report absent=1 (EN3-absent assertion would fail — RED)"
fi

# ── TOOTH 14: absent-not-failed-guard-removed — sed removes '&& [ "$_absent_typed" -eq 0 ]' ──
# Mutant: absent guard stripped from the if-condition → absent-input (exits 1, _absent_typed=1)
# counted in failed and emits seeder-failed WARN; in SUT absent is skipped (failed stays 0).
# Fine-grained sed mutant: cannot use mkmutant (which removes the entire block body too).
# Guard text: '&& [ "$_absent_typed" -eq 0 ]' (cite: SENTINEL-ABSENT-NOT-FAILED-START)
M14="$ROOT/m14_guard.sh"
# Remove only the guard clause, leave the if-body intact
sed 's/ && \[ "\$_absent_typed" -eq 0 \]//' "$SUT" > "$M14"

# Pre-check: sed matched → mutant differs from SUT
if diff -q "$SUT" "$M14" >/dev/null 2>&1; then
  no "TOOTH 14 pre-check: mutant identical to SUT — guard pattern not found in SUT"
else
  ok "TOOTH 14 pre-check: mutant differs from SUT (guard removed)"
fi

# Bash-n syntax check: mutant must be valid shell
if ! bash -n "$M14" 2>/dev/null; then
  no "TOOTH 14 pre-check: mutant fails bash -n — guard removal broke shell syntax"
else
  ok "TOOTH 14 pre-check: mutant passes bash -n (valid shell)"
fi

# Sabotage: rename guard variable in SUT copy so the production mutant sed no longer matches → no diff
SUT_SAB14="$ROOT/sut_sab14.sh"
MUT_SAB14="$ROOT/mut_sab14.sh"
# Rename _absent_typed → _absent_typed_gone in the SUT copy
sed 's/_absent_typed/_absent_typed_gone/g' "$SUT" > "$SUT_SAB14"
# Run the ORIGINAL mutant pattern (targets _absent_typed, not _gone) against the renamed copy
sed 's/ && \[ "\$_absent_typed" -eq 0 \]//' "$SUT_SAB14" > "$MUT_SAB14"
# Pattern can't match → MUT_SAB14 identical to SUT_SAB14 → no diff → tooth would fail
if diff -q "$SUT_SAB14" "$MUT_SAB14" >/dev/null 2>&1; then
  ok "TOOTH 14 sabotage: renamed guard variable → no diff (tooth would fail — as expected)"
else
  no "TOOTH 14 sabotage: renamed guard variable → sed still matched — sabotage broken"
fi

# Deploy mutant with absent-input stub (exits 1, absent-input: to stderr)
cat > "$MUT_KIT/toolbelt/stage-retro-issues.sh" << 'ABSENTIN14'
#!/usr/bin/env bash
# absent-input path — real seeder: search absent-input: retro not found
printf 'absent-input: retro not found: retro.md\n' >&2
exit 1
ABSENTIN14
chmod +x "$MUT_KIT/toolbelt/stage-retro-issues.sh"
cp "$M14" "$MUT_KIT/toolbelt/retro-gate-m14.sh"

TM14="$ROOT/m14"; mkgit "$TM14"; SM14="m14-sess"
mksessionfile "$TM14" "$SM14" "202609050800"
mkblock "$TM14" "niagara-block14.md" "2026-09-05T10:00:00"
touch -t 202609051000 "$TM14/niagara-block14.md"
mkretro "$TM14" "2026-09-05-m14.md" 1
touch -t 202609051200 "$TM14/retros/2026-09-05-m14.md"
_jm14="$(mkjson "$SM14" "false")"
errf_m14="$ROOT/merr_m14"
OUT="$(printf '%s' "$_jm14" | PATH="$ROOT/mockbin2:$PATH" \
  "$BASH_BIN" "$MUT_KIT/toolbelt/retro-gate-m14.sh" "$TM14" 2>"$errf_m14")"; RC=$?
ERR_M14="$(cat "$errf_m14")"; rm -f "$errf_m14"

# Positive: loop ran (loop-reached proof)
if printf '%s' "$ERR_M14" | grep -q 'issue-seeding:'; then
  ok "TOOTH 14 absent-not-failed-dropped: loop ran and emitted issue-seeding: summary"
else
  no "TOOTH 14 absent-not-failed-dropped: issue-seeding: absent — mutant may have crashed (tooth invalid)"
fi
# On mutant: absent-input counted as failed=1 (guard removed → skip-failed branch never fires)
if printf '%s' "$ERR_M14" | grep -qE 'failed=1( |$)'; then
  ok "TOOTH 14 absent-not-failed-dropped: mutant reports failed=1 (guard removed — RED as expected)"
else
  no "TOOTH 14 absent-not-failed-dropped: mutant does NOT report failed=1 — tooth has no bite"
fi
# On mutant: seeder-failed WARN fires (absent counted in failed branch)
if printf '%s' "$ERR_M14" | grep -q 'WARN.*seeder failed'; then
  ok "TOOTH 14 absent-not-failed-dropped: mutant emits seeder-failed WARN (guard removed — RED as expected)"
else
  no "TOOTH 14 absent-not-failed-dropped: mutant does NOT emit seeder-failed WARN — tooth has no bite"
fi

# ── TOOTH 15: diff-filter-A-drop — mutant drops --diff-filter=A so renames appear as qualifying ─
# Proves the --diff-filter=A guard bites: without it, a git mv'd old retro bypasses the gate.
# Fixture: T-git-mv (old retro renamed after session start; only added (A) files qualify).
# Normal SUT: rename has diff-filter R not A → excluded → no qualifying retro → BLOCK.
# Mutant (--diff-filter=A removed): git diff returns renamed file → treated as added → ALLOW (RED).
# cite: SENTINEL-RETRO-SESSION-START/END (anchors the mutation target; never use line numbers)
M15_path="$MUT_KIT/toolbelt/mutant-retro-diff-filter.sh"
awk '
  /# SENTINEL-RETRO-SESSION-START/ { in_s=1 }
  /# SENTINEL-RETRO-SESSION-END/   { in_s=0 }
  in_s && /--diff-filter=A/ { gsub(/--diff-filter=A[[:space:]]*/,""); print; next }
  { print }
' "$SUT" > "$M15_path"; chmod +x "$M15_path"
# Pre-check: sentinel exists in SUT
if ! grep -q 'SENTINEL-RETRO-SESSION-START' "$SUT"; then
  no "TOOTH 15 pre-check: SENTINEL-RETRO-SESSION-START not found in SUT — tooth fixture invalid"
else
  ok "TOOTH 15 pre-check: SENTINEL-RETRO-SESSION-START found in SUT"
fi
# Sabotage check: renamed sentinel → awk produces no diff
_M15_sab="$MUT_KIT/toolbelt/mutant-retro-diff-filter-sab.sh"
awk '{ gsub(/SENTINEL-RETRO-SESSION-START/,"SENTINEL-RETRO-SESSION-XSTART"); print }' "$SUT" \
  > "$_M15_sab"; chmod +x "$_M15_sab"
awk '
  /# SENTINEL-RETRO-SESSION-START/ { in_s=1 }
  /# SENTINEL-RETRO-SESSION-END/   { in_s=0 }
  in_s && /--diff-filter=A/ { gsub(/--diff-filter=A[[:space:]]*/,""); print; next }
  { print }
' "$_M15_sab" > "$MUT_KIT/toolbelt/mutant-retro-diff-filter-sab2.sh"
if diff -q "$_M15_sab" "$MUT_KIT/toolbelt/mutant-retro-diff-filter-sab2.sh" > /dev/null 2>&1; then
  ok "TOOTH 15 sabotage: renamed sentinel → no diff (tooth would fail — as expected)"
else
  no "TOOTH 15 sabotage: sabotage check produced unexpected diff — sentinel may be wrong"
fi
# Use T-git-mv fixture; clear any block-once state from the previous T-git-mv run
TM15="$T_gmv"
_jm15="$(mkjson "$SID_gmv" "false")"
rm -f "$TM15/.claude/.rsdd-retro-blocked-${SID_gmv}" 2>/dev/null || true
run_mutant "$M15_path" "$TM15" "$_jm15"
# Mutant drops --diff-filter=A: rename appears in diff output → treated as qualifying → ALLOW (RED)
[ -z "$OUT" ] \
  && ok "TOOTH 15 diff-filter-A-drop: mutant allows git-mv'd retro (--diff-filter=A removed — RED as expected)" \
  || no "TOOTH 15 diff-filter-A-drop: mutant should have allowed (renamed retro admitted) but blocked — tooth ineffective"

# ── TOOTH 16: find-renames-drop — mutant drops the explicit -M so rename detection depends on
#    the target repo's ambient diff.renames config again (#984) ────────────────────────────────
# Proves -M is load-bearing on a repo that explicitly sets diff.renames=false: with -M removed,
# git no longer forces rename detection, so the T-git-mv-diff-renames-false fixture's `git mv`
# reports as a plain D+A pair instead of R — the Added half qualifies as a "new" retro — and the
# gate wrongly ALLOWS. Normal SUT: -M forces R regardless of config → BLOCK (case #984 above).
# Mutant (-M removed): falls back to the repo's diff.renames=false → D+A → ALLOW (RED).
# cite: SENTINEL-RETRO-SESSION-START/END (anchors the mutation target; never use line numbers)
# The mutation program is defined ONCE (R2: a previous revision duplicated this verbatim
# between the mutant build and the sabotage check) and reused for both.
_M16_AWK_PROG='
  /# SENTINEL-RETRO-SESSION-START/ { in_s=1 }
  /# SENTINEL-RETRO-SESSION-END/   { in_s=0 }
  in_s && /--diff-filter=A -M/ { gsub(/--diff-filter=A -M/,"--diff-filter=A"); print; next }
  { print }
'
M16_path="$MUT_KIT/toolbelt/mutant-retro-find-renames.sh"
awk "$_M16_AWK_PROG" "$SUT" > "$M16_path"; chmod +x "$M16_path"
# Sabotage check: renamed sentinel → the SAME mutation program produces no diff (same
# technique as TOOTH 15) — proving the program's bite depends on the sentinel name, not luck.
_M16_sab="$MUT_KIT/toolbelt/mutant-retro-find-renames-sab.sh"
awk '{ gsub(/SENTINEL-RETRO-SESSION-START/,"SENTINEL-RETRO-SESSION-XSTART"); print }' "$SUT" \
  > "$_M16_sab"; chmod +x "$_M16_sab"
awk "$_M16_AWK_PROG" "$_M16_sab" > "$MUT_KIT/toolbelt/mutant-retro-find-renames-sab2.sh"
if diff -q "$_M16_sab" "$MUT_KIT/toolbelt/mutant-retro-find-renames-sab2.sh" > /dev/null 2>&1; then
  ok "TOOTH 16 sabotage: renamed sentinel → no diff (tooth would fail — as expected)"
else
  no "TOOTH 16 sabotage: sabotage check produced unexpected diff — sentinel may be wrong"
fi
# Use the T-git-mv-diff-renames-false fixture (diff.renames=false pinned); clear any block-once
# state left over from the earlier (blocking) run of this fixture.
TM16="$T_gmvdr"
_jm16="$(mkjson "$SID_gmvdr" "false")"
rm -f "$TM16/.claude/.rsdd-retro-blocked-${SID_gmvdr}" 2>/dev/null || true
run_mutant "$M16_path" "$TM16" "$_jm16"
# Mutant drops -M: on a diff.renames=false repo the rename reports as D+A → treated as
# qualifying → ALLOW (RED)
[ -z "$OUT" ] \
  && ok "TOOTH 16 find-renames-drop: mutant allows git-mv'd retro under diff.renames=false (-M removed — RED as expected)" \
  || no "TOOTH 16 find-renames-drop: mutant should have allowed (renamed retro admitted) but blocked — tooth ineffective"

# ── TOOTH 17-SEEDABLE (kit issue #1093 item 3): neuter the retro_marker_is_partial call in
#    _retro_is_seedable — 'applied' must then always resolve to not-seedable regardless of
#    PARTIAL/shipped content, proving T-SEEDABLE-1 has teeth.
echo "-- teeth T17-seedable: neuter retro_marker_is_partial call in _retro_is_seedable --"
anchor_t17s='      retro_marker_is_partial "$sline" && return 0 || return 1 ;;'
sut_content_gate="$(cat "$SUT")"
if [[ "$sut_content_gate" == *"$anchor_t17s"* ]]; then
  mutant_t17s="$MUT_KIT/toolbelt/mutant-retro-seedable-t17.sh"
  printf '%s\n' "${sut_content_gate/"$anchor_t17s"/      return 1 ;;  # teeth-t17-seedable-partial-check-removed}" \
    > "$mutant_t17s"
  bash -n "$mutant_t17s" 2>/dev/null || { no "T17-seedable teeth: mutant failed bash -n" ""; }
  out_t17s="$("$BASH_BIN" -c '
    . "$1"
    _rs_func="$(sed -n "/^_retro_is_seedable() {/,/^}/p" "$2")"
    eval "$_rs_func"
    if _retro_is_seedable "$3"; then echo seedable; else echo not-seedable; fi
  ' _ "$RS_LIB" "$mutant_t17s" "$f1" 2>&1)"
  if [ "$out_t17s" = "not-seedable" ]; then
    ok "T17-seedable teeth: is_partial call neutered → T-SEEDABLE-1 flips to not-seedable (has teeth)" "()"
  else
    no "T17-seedable teeth: is_partial call neutered → should flip to not-seedable" "got [$out_t17s] — THEATER"
  fi
else
  no "T17-seedable teeth: locate retro_marker_is_partial call anchor" "anchor not found — SUT drifted?"
fi

# ── TOOTH 18-SEEDABLE (kit issue #945, signal UPDATED by #1099): revert _retro_is_seedable to
#    reading the raw marker line via retro_marker_scope_line's H1-tolerant scan disabled — reuse
#    the SAME H1-skip-removed mutant technique as lib/retro-status.sh's own teeth SC1, but
#    exercised THROUGH retro-gate.sh, proving T-SEEDABLE-3 has teeth end to end (not just at the
#    lib layer). Before #1099, removing the H1-skip made the marker silently read as absent and
#    flipped the final answer to seedable (fail-open). Since #1099, _retro_is_seedable's own
#    out-of-scope-marker guard independently re-derives "marker present but scope missed it" via
#    retro_marker_line's whole-file fallback (same mutant lib, unaffected by the H1-skip removal)
#    and refuses to seed anyway — so the FINAL not-seedable/seedable verdict no longer flips, by
#    design (defense in depth). The mutation still has teeth: it is observable in the REASON —
#    the out-of-scope-marker WARN fires with the mutation and does not without it.
echo "-- teeth T18-seedable: drop H1-skip rules in the shared lib; T-SEEDABLE-3's out-of-scope-marker WARN must appear --"
if grep -qF 'RETRO_MARKER_SCOPE_H1_SKIP' "$RS_LIB"; then
  mutant_lib_t18s="$MUT_KIT/toolbelt/lib/retro-status-t18.sh"
  sed '/NR==1 && \/\^\[\[:space:\]\]\*#/d' "$RS_LIB" > "$mutant_lib_t18s"
  bash -n "$mutant_lib_t18s" 2>/dev/null || { no "T18-seedable teeth: mutant lib failed bash -n" ""; }
  out_t18s="$("$BASH_BIN" -c '
    . "$1"
    _rs_func="$(sed -n "/^_retro_is_seedable() {/,/^}/p" "$2")"
    eval "$_rs_func"
    if _retro_is_seedable "$3"; then echo seedable; else echo not-seedable; fi
  ' _ "$mutant_lib_t18s" "$SUT" "$f3" 2>&1)"
  # With the H1-skip removed, retro_marker_scope_line goes blind on T-SEEDABLE-3's fixture (same
  # mutant SC1 already proves at the lib layer) — but retro_marker_out_of_scope's whole-file
  # fallback (unaffected by the H1-skip removal) still finds the marker and fires the
  # out-of-scope-marker guard, keeping the final verdict not-seedable via a DIFFERENT, still-safe
  # code path. The tooth's signal is that fallback firing, not a flipped final verdict.
  if printf '%s' "$out_t18s" | grep -q 'out-of-scope-marker' && printf '%s' "$out_t18s" | grep -q 'not-seedable'; then
    ok "T18-seedable teeth: H1-skip removed → out-of-scope-marker fallback fires, still not-seedable (has teeth)" "()"
  else
    no "T18-seedable teeth: H1-skip removed → out-of-scope-marker fallback should fire" "got [$out_t18s] — THEATER"
  fi
else
  no "T18-seedable teeth: locate RETRO_MARKER_SCOPE_H1_SKIP anchor" "anchor not found — lib drifted?"
fi

# ── TOOTH 19-SEEDABLE (kit issue #1099): neuter the out-of-scope-marker guard added to
#    _retro_is_seedable. T-SEEDABLE-6's out-of-scope fixture must then flip back to seedable,
#    reproducing the exact #1048-#1089 fail-open shape #1099 fixes.
echo "-- teeth T19-seedable: neuter the out-of-scope-marker guard in _retro_is_seedable --"
anchor_t19s='  if [ -z "$sline" ] && retro_marker_out_of_scope "$rf"; then'
if [[ "$sut_content_gate" == *"$anchor_t19s"* ]]; then
  mutant_t19s="$MUT_KIT/toolbelt/mutant-retro-seedable-t19.sh"
  printf '%s\n' "${sut_content_gate/"$anchor_t19s"/  if false; then}" > "$mutant_t19s"
  bash -n "$mutant_t19s" 2>/dev/null || { no "T19-seedable teeth: mutant failed bash -n" ""; }
  out_t19s="$("$BASH_BIN" -c '
    . "$1"
    _rs_func="$(sed -n "/^_retro_is_seedable() {/,/^}/p" "$2")"
    eval "$_rs_func"
    if _retro_is_seedable "$3"; then echo seedable; else echo not-seedable; fi
  ' _ "$RS_LIB" "$mutant_t19s" "$f6" 2>&1)"
  if [ "$out_t19s" = "seedable" ]; then
    ok "T19-seedable teeth: out-of-scope-marker guard neutered → T-SEEDABLE-6 flips to seedable (has teeth)" "()"
  else
    no "T19-seedable teeth: out-of-scope-marker guard neutered → should flip to seedable" "got [$out_t19s] — THEATER"
  fi
else
  no "T19-seedable teeth: locate out-of-scope-marker guard anchor" "anchor not found — SUT drifted?"
fi

# ── TOOTH 20 (kit issue #1129 finding 1): neuter the 'unclassifiable:' case PATTERN so that
#    arm can never match. EN3-unclassifiable's fixture must then fall through to the generic
#    "no summary: line" WARN and unclassifiable must stay 0 — reproducing the exact
#    silent-fallthrough this finding fixes.
echo "-- teeth T20-unclassifiable: neuter the unclassifiable: case pattern; EN3-unclassifiable must fall through to the generic WARN --"
anchor_t20_line="        *\$'\\n'unclassifiable:*)"
if [[ "$sut_content_gate" == *"$anchor_t20_line"* ]]; then
  mutant_t20="$MUT_KIT/toolbelt/mutant-retro-unclassifiable-t20.sh"
  printf '%s\n' "${sut_content_gate/"$anchor_t20_line"/        *NEVER-MATCHES-XX*)}" > "$mutant_t20"
  bash -n "$mutant_t20" 2>/dev/null || { no "T20-unclassifiable teeth: mutant failed bash -n" ""; }
  FKIT_T20="$ROOT/fkit_t20"
  mkdir -p "$FKIT_T20/toolbelt/lib"
  cp "$HERE/../lib/block-files.sh"    "$FKIT_T20/toolbelt/lib/"
  cp "$HERE/../lib/retro-status.sh"   "$FKIT_T20/toolbelt/lib/"
  cp "$HERE/../lib/retro-grammar.sh"  "$FKIT_T20/toolbelt/lib/"
  cp "$HERE/../verify-retro.sh"       "$FKIT_T20/toolbelt/"
  cat > "$FKIT_T20/toolbelt/stage-retro-issues.sh" << 'FT20EOF'
#!/usr/bin/env bash
printf 'unclassifiable: delta section found but not in row-table form in retro.md — needs manual review, no issue auto-staged\n' >&2
exit 0
FT20EOF
  chmod +x "$FKIT_T20/toolbelt/stage-retro-issues.sh"
  cp "$mutant_t20" "$FKIT_T20/toolbelt/retro-gate.sh"
  T20="$ROOT/t20"; mkgit "$T20"; ST20="t20-sess"
  mksessionfile "$T20" "$ST20" "202609050800"
  mkblock "$T20" "t20-block1.md" "2026-09-05T10:00:00"
  touch -t 202609051000 "$T20/t20-block1.md"
  mkretro "$T20" "2026-09-05-t20.md" 1
  touch -t 202609051200 "$T20/retros/2026-09-05-t20.md"
  _jt20="$(mkjson "$ST20" "false")"
  errf_t20="$ROOT/err_t20.$$"
  printf '%s' "$_jt20" | PATH="$MOCK_GH_DIR:$PATH" \
    "$BASH_BIN" "$FKIT_T20/toolbelt/retro-gate.sh" "$T20" >"$ROOT/out_t20.$$" 2>"$errf_t20"
  ERR_T20="$(cat "$errf_t20")"; rm -f "$errf_t20" "$ROOT/out_t20.$$"
  if printf '%s' "$ERR_T20" | grep -q 'unclassifiable=0' \
     && printf '%s' "$ERR_T20" | grep -q 'no summary: line'; then
    ok "T20-unclassifiable teeth: case arm removed → falls through to generic WARN, unclassifiable=0 (has teeth)" "()"
  else
    no "T20-unclassifiable teeth: case arm removed → should fall through to generic WARN" "got [$ERR_T20] — EN3-unclassifiable is THEATER"
  fi
else
  no "T20-unclassifiable teeth: locate the unclassifiable: case arm" "anchor not found — SUT drifted?"
fi

# ── TOOTH PFX1 (kit issue #1130 finding 4/item 5): revert the out-of-scope-marker WARN wording
# printed by retro-gate.sh itself from the unified 'out-of-scope-marker: %s' shape back to the
# pre-#1130 'out-of-scope-marker for %s' shape. T-SEEDABLE-PFX must then go red (the colon
# form is what it greps for).
echo "-- teeth PFX1: revert retro-gate.sh's out-of-scope-marker WARN wording; T-SEEDABLE-PFX must go red --"
anchor_pfx1_gate="printf 'retro-gate: WARN: out-of-scope-marker: %s — a review-status marker exists but sits outside the leading-block scope; refusing to seed (kit issue #1099)\n' \\"
if [[ "$sut_content_gate" == *"$anchor_pfx1_gate"* ]]; then
  reverted_pfx1_gate="printf 'retro-gate: WARN: out-of-scope-marker for %s — a review-status marker exists but sits outside the leading-block scope; refusing to seed (kit issue #1099)\n' \\"
  mutant_pfx1_gate="$MUT_KIT/toolbelt/mutant-retro-pfx1.sh"
  printf '%s\n' "${sut_content_gate/"$anchor_pfx1_gate"/"$reverted_pfx1_gate"}" > "$mutant_pfx1_gate"
  bash -n "$mutant_pfx1_gate" 2>/dev/null || { no "teeth PFX1: mutant failed bash -n" ""; }
  errf_pfx1="$ROOT/err_pfx1.$$"
  # Same hermetic gh stub as T-SEEDABLE-PFX above — without it, _run_issue_seeding's own gh
  # presence probe short-circuits before the retro loop, and this mutant would never reach the
  # out-of-scope-marker line at all (RIGHT reason for a different failure, still THEATER-blind).
  printf '{"session_id":"%s","stop_hook_active":false,"hook_event_name":"Stop","cwd":"/tmp"}' "$STPFX" \
    | PATH="$MOCK_GH_DIR:$PATH" "$BASH_BIN" "$mutant_pfx1_gate" "$TPFX" >"$ROOT/out_pfx1.$$" 2>"$errf_pfx1"
  ERR_PFX1="$(cat "$errf_pfx1")"; rm -f "$errf_pfx1" "$ROOT/out_pfx1.$$"
  if ! printf '%s' "$ERR_PFX1" | grep -q 'WARN: out-of-scope-marker: ' \
     && printf '%s' "$ERR_PFX1" | grep -q 'out-of-scope-marker for'; then
    ok "teeth PFX1: wording reverted → T-SEEDABLE-PFX's colon-prefixed grep no longer matches (has teeth)" "()"
  else
    no "teeth PFX1: wording reverted → T-SEEDABLE-PFX should stop matching" "got=[$ERR_PFX1] — THEATER"
  fi
else
  no "teeth PFX1: locate the unified out-of-scope-marker WARN wording in SUT" "anchor not found — SUT drifted?"
fi

# ── TEETH NW / CAT / ESC (kit issues #1223, #1229, #1167): every mutant is built from the REAL
# SUT, asserted to DIFFER from it (a no-op mutation is theater), then run against the fixture
# whose test above must go red under it.
# nwmutant <name> <sed-script> → sets NWM to the mutant path (no command substitution: the
# failure line must reach the suite output, not be captured). Returns 1 + a FAIL line when the
# sed script was a no-op.
nwmutant() {
  local name="$1" script="$2" m
  m="$MUT_KIT/toolbelt/mutant-${name}.sh"
  sed "$script" "$SUT" > "$m"; chmod +x "$m"
  NWM="$m"
  if cmp -s "$SUT" "$m"; then
    no "TOOTH $name: mutant identical to SUT — sed matched nothing (tooth not built)"
    return 1
  fi
  return 0
}
# blocks_json <var-output>: 0 when stdout carries a block decision.
blocks_json() { printf '%s' "$1" | grep -qF '"decision":"block"'; }
# rmblocked <target> <session_id>: clear the block-once state so a mutant run is judged on the
# scan logic, not suppressed by the original fixture run's "already blocked this session" file.
rmblocked() { rm -f "$1/.claude/.rsdd-retro-blocked-$2"; }

# NW1: guard in _is_research_file removed → a .claude/worktrees copy counts again (W1 → block).
if nwmutant 'nw-guard-removed' '/SENTINEL-NESTED-WORKTREE-GUARD-START/,/SENTINEL-NESTED-WORKTREE-GUARD-END/d'; then M_NW1="$NWM"
  run_mutant "$M_NW1" "$T_w1" "$(mkjson "$SID_w1" false)"
  blocks_json "$OUT" \
    && ok "TOOTH nw-guard-removed: mutant blocks on a worktree-only change (RED as expected)" \
    || no "TOOTH nw-guard-removed: mutant should block (W1 fixture) but did not: ERR=$ERR"
fi
# NW2: probe removed → roots stay empty → nothing is excluded (W1 → block, W3 → block).
if nwmutant 'nw-probe-removed' '/SENTINEL-NESTED-WORKTREE-PROBE-START/,/SENTINEL-NESTED-WORKTREE-PROBE-END/d'; then M_NW2="$NWM"
  rmblocked "$T_w1" "$SID_w1"; run_mutant "$M_NW2" "$T_w1" "$(mkjson "$SID_w1" false)"
  _nw2a=0; blocks_json "$OUT" && _nw2a=1
  run_mutant "$M_NW2" "$T_w3" "$(mkjson "$SID_w3" false)"
  _nw2b=0; blocks_json "$OUT" && _nw2b=1
  [ "$_nw2a$_nw2b" = "11" ] \
    && ok "TOOTH nw-probe-removed: mutant blocks on both .claude/worktrees and git-worktree copies (RED)" \
    || no "TOOTH nw-probe-removed: expected both fixtures to block, got $_nw2a$_nw2b"
fi
# NW3..NW6: each retro-scan guard removed on its own → its fixture stops blocking / seeds the copy.
# W5 (untracked path), W8 (committed path), W7 (degraded path) → ALLOW instead of BLOCK.
if nwmutant 'nw-retro-untracked' '/NW-RETRO-GUARD-UNTRACKED/d'; then M_NW3="$NWM"
  rmblocked "$T_w5" "$SID_w5"; run_mutant "$M_NW3" "$T_w5" "$(mkjson "$SID_w5" false)"
  blocks_json "$OUT" \
    && no "TOOTH nw-retro-untracked: mutant still blocks W5 — guard not load-bearing" \
    || ok "TOOTH nw-retro-untracked: mutant accepts the worktree retro (untracked path) — RED"
fi

if nwmutant 'nw-retro-committed' '/NW-RETRO-GUARD-COMMITTED/d'; then M_NW4="$NWM"
  rmblocked "$T_w8" "$SID_w8"; run_mutant "$M_NW4" "$T_w8" "$(mkjson "$SID_w8" false)"
  blocks_json "$OUT" \
    && no "TOOTH nw-retro-committed: mutant still blocks W8 — guard not load-bearing" \
    || ok "TOOTH nw-retro-committed: mutant accepts the worktree retro (committed path) — RED"
fi
if nwmutant 'nw-retro-degraded' '/NW-RETRO-GUARD-DEGRADED/d'; then M_NW5="$NWM"
  rmblocked "$T_w7" "w7-sess"; run_mutant "$M_NW5" "$T_w7" "$(mkjson "w7-sess" false)"
  blocks_json "$OUT" \
    && no "TOOTH nw-retro-degraded: mutant still blocks W7 — guard not load-bearing" \
    || ok "TOOTH nw-retro-degraded: mutant accepts the worktree retro (degraded path) — RED"
fi
if nwmutant 'nw-retro-seed' '/NW-RETRO-GUARD-SEED/d'; then M_NW6="$NWM"
  cp "$M_NW6" "$FKIT/toolbelt/mutant-nw-seed.sh"
  : > "$SEED_LOG_EN3"
  _errf_nw6="$ROOT/err_nw6.$$"
  rmblocked "$T_w6" "$SID_w6"; printf "%s" "$(mkjson "$SID_w6" false)" | SEED_LOG="$SEED_LOG_EN3" PATH="$MOCK_GH_DIR:$PATH" \
    "$BASH_BIN" "$FKIT/toolbelt/mutant-nw-seed.sh" "$T_w6" >/dev/null 2>"$_errf_nw6"
  rm -f "$_errf_nw6"
  grep -q 'wtcopy' "$SEED_LOG_EN3" \
    && ok "TOOTH nw-retro-seed: mutant seeds the nested-worktree retro — RED" \
    || no "TOOTH nw-retro-seed: mutant did not seed the worktree retro — guard not load-bearing"
fi
# NW7 (review of PR #1300, B1): the lib's worktree proofs dropped (commondir AND, since #1301, the
# back-pointer — a real submodule fails both, so one alone is no longer load-bearing for W9) → a
# submodule of a linked-worktree target is excluded again → W9 stops blocking (false ALLOW). The mutant is the
# LIB (the SUT is unchanged), so mutate MUT_KIT's lib copy for this one run and restore it.
cp "$SUT" "$MUT_KIT/toolbelt/mutant-proofs.sh"; chmod +x "$MUT_KIT/toolbelt/mutant-proofs.sh"
_lib_mk="$MUT_KIT/toolbelt/lib/block-files.sh"; cp "$_lib_mk" "$_lib_mk.orig"
sed '/SENTINEL-COMMONDIR-START/,/SENTINEL-COMMONDIR-END/d;/SENTINEL-BACKPOINTER-START/,/SENTINEL-BACKPOINTER-END/d' "$_lib_mk.orig" > "$_lib_mk"
if cmp -s "$_lib_mk" "$_lib_mk.orig"; then
  no "TOOTH nw-proofs-dropped: lib mutant identical to original — sentinel missing (tooth not built)"
else
  rmblocked "$T_w9" "$SID_w9"; run_mutant "$MUT_KIT/toolbelt/mutant-proofs.sh" "$T_w9" "$(mkjson "$SID_w9" false)"
  blocks_json "$OUT" \
    && no "TOOTH nw-proofs-dropped: mutant still blocks W9 — worktree proofs (commondir + back-pointer) not load-bearing" \
    || ok "TOOTH nw-proofs-dropped: mutant excludes the submodule (false ALLOW) — RED as expected"
fi
mv "$_lib_mk.orig" "$_lib_mk"
# NW8 (#1301 item 2): only the back-pointer proof dropped → W10 (gitdir: . + stray commondir) and
# W10b (commondir, no back-pointer) are excluded as worktrees again → both stop blocking.
cp "$_lib_mk" "$_lib_mk.orig"
sed '/SENTINEL-BACKPOINTER-START/,/SENTINEL-BACKPOINTER-END/d' "$_lib_mk.orig" > "$_lib_mk"
if cmp -s "$_lib_mk" "$_lib_mk.orig"; then
  no "TOOTH nw-backpointer-dropped: lib mutant identical to original — sentinel missing (tooth not built)"
else
  _nw8=""
  rmblocked "$T_w10" "$SID_w10"; run_mutant "$MUT_KIT/toolbelt/mutant-proofs.sh" "$T_w10" "$(mkjson "$SID_w10" false)"
  blocks_json "$OUT" || _nw8="${_nw8}W10 "
  rmblocked "$T_w10b" "$SID_w10b"; run_mutant "$MUT_KIT/toolbelt/mutant-proofs.sh" "$T_w10b" "$(mkjson "$SID_w10b" false)"
  blocks_json "$OUT" || _nw8="${_nw8}W10b "
  [ "$_nw8" = "W10 W10b " ] \
    && ok "TOOTH nw-backpointer-dropped: mutant allows both contrived fixtures (false ALLOW) — RED as expected" \
    || no "TOOTH nw-backpointer-dropped: expected W10 and W10b to stop blocking, only [$_nw8] did"
fi
mv "$_lib_mk.orig" "$_lib_mk"
# NW9 (#1311 item 1): the back-pointer read without the braces → the shell's own "No such file"
# leaks to stderr again on W10b (a commondir-only directory).
cp "$_lib_mk" "$_lib_mk.orig"
sed 's|{ IFS= read -r _bp < "$_gd/gitdir"; } 2>/dev/null|IFS= read -r _bp < "$_gd/gitdir" 2>/dev/null|' "$_lib_mk.orig" > "$_lib_mk"
if cmp -s "$_lib_mk" "$_lib_mk.orig"; then
  no "TOOTH bp-read-unbraced: lib mutant identical to original — sed matched nothing (tooth not built)"
else
  rmblocked "$T_w10b" "$SID_w10b"; run_mutant "$MUT_KIT/toolbelt/mutant-proofs.sh" "$T_w10b" "$(mkjson "$SID_w10b" false)"
  printf '%s' "$ERR" | grep -qi 'no such file' \
    && ok "TOOTH bp-read-unbraced: mutant leaks 'No such file' to stderr — RED as expected" \
    || no "TOOTH bp-read-unbraced: mutant stayed quiet — braces not load-bearing: ERR=$ERR"
fi
mv "$_lib_mk.orig" "$_lib_mk"
# DL1 (#1311 item 3): Part C removed → S1 (block changed through a directory symlink) allows.
if nwmutant 'dirlink-scan-removed' '/SENTINEL-DIRLINK-SCAN-START/,/SENTINEL-DIRLINK-SCAN-END/d'; then M_DL1="$NWM"
  rmblocked "$T_s1" "$SID_s1"; run_mutant "$M_DL1" "$T_s1" "$(mkjson "$SID_s1" false)"
  blocks_json "$OUT" \
    && no "TOOTH dirlink-scan-removed: mutant still blocks S1 — Part C not load-bearing" \
    || ok "TOOTH dirlink-scan-removed: mutant allows the symlinked block (false ALLOW) — RED as expected"
fi
# DL2: the added-link rule removed → S4 (committed directory symlink) allows.
if nwmutant 'dirlink-added-removed' '/SENTINEL-DIRLINK-ADDED-START/,/SENTINEL-DIRLINK-ADDED-END/d'; then M_DL2="$NWM"
  rmblocked "$T_s4" "$SID_s4"; run_mutant "$M_DL2" "$T_s4" "$(mkjson "$SID_s4" false)"
  blocks_json "$OUT" \
    && no "TOOTH dirlink-added-removed: mutant still blocks S4 — added-link rule not load-bearing" \
    || ok "TOOTH dirlink-added-removed: mutant allows the added link (false ALLOW) — RED as expected"
fi
# DL3: Part C over-scoped to ignore the session mtime (every research file under the link counts) →
# S2 (old research behind a link) blocks → over-block caught.
if nwmutant 'dirlink-ignores-mtime' '/SENTINEL-DIRLINK-SCAN-START/,/SENTINEL-DIRLINK-SCAN-END/s/-newer "\$_session_file" //'; then M_DL3="$NWM"
  rmblocked "$T_s2" "$SID_s2"; run_mutant "$M_DL3" "$T_s2" "$(mkjson "$SID_s2" false)"
  blocks_json "$OUT" \
    && ok "TOOTH dirlink-ignores-mtime: mutant over-blocks unchanged symlinked research — RED as expected" \
    || no "TOOTH dirlink-ignores-mtime: mutant did not over-block S2 — mtime filter not load-bearing"
fi
# DL4 (N1): ancestor skip removed → S6 walks the parent tree and blocks on the sibling block.
if nwmutant 'dirlink-ancestor-removed' '/SENTINEL-DIRLINK-ANCESTOR-START/,/SENTINEL-DIRLINK-ANCESTOR-END/d'; then M_DL4="$NWM"
  rmblocked "$T_s6" "$SID_s6"; run_mutant "$M_DL4" "$T_s6" "$(mkjson "$SID_s6" false)"
  blocks_json "$OUT" \
    && ok "TOOTH dirlink-ancestor-removed: mutant walks the ancestor and blocks — RED as expected" \
    || no "TOOTH dirlink-ancestor-removed: mutant still allows S6 — ancestor skip not load-bearing"
fi
# DL5 (N2): inside-target / nested-worktree skip removed → S5 counts the worktree copy and blocks.
if nwmutant 'dirlink-inside-removed' '/SENTINEL-DIRLINK-INSIDE-START/,/SENTINEL-DIRLINK-INSIDE-END/d'; then M_DL5="$NWM"
  rmblocked "$T_s5" "$SID_s5"; run_mutant "$M_DL5" "$T_s5" "$(mkjson "$SID_s5" false)"
  blocks_json "$OUT" \
    && ok "TOOTH dirlink-inside-removed: mutant counts the worktree copy — RED as expected" \
    || no "TOOTH dirlink-inside-removed: mutant still allows S5 — skip not load-bearing"
fi
# DL6 (N3): walk-failure WARN removed → S10 goes silent.
if nwmutant 'dirlink-walkwarn-removed' '/SENTINEL-DIRLINK-WALK-WARN-START/,/SENTINEL-DIRLINK-WALK-WARN-END/d'; then M_DL6="$NWM"
  rmblocked "$T_s10" "$SID_s10"; PATH="$STUB_TOINNER:$PATH" run_mutant "$M_DL6" "$T_s10" "$(mkjson "$SID_s10" false)"
  printf '%s' "$ERR" | grep -q 'directory-symlink walk incomplete' \
    && no "TOOTH dirlink-walkwarn-removed: mutant still warns — WARN not load-bearing" \
    || ok "TOOTH dirlink-walkwarn-removed: mutant is silent on a failed walk — RED as expected"
fi
# DL7: timeout branch removed (124 handled as a generic rc) → S9 loses its 'timed out' wording.
if nwmutant 'dirlink-timeout-branch' 's/"\$_dl_rc" -eq 124/"$_dl_rc" -eq 999/'; then M_DL7="$NWM"
  rmblocked "$T_s9" "$SID_s9"; PATH="$STUB_TO124:$PATH" run_mutant "$M_DL7" "$T_s9" "$(mkjson "$SID_s9" false)"
  printf '%s' "$ERR" | grep -q 'scan timed out' \
    && no "TOOTH dirlink-timeout-branch: mutant still reports a timeout" \
    || ok "TOOTH dirlink-timeout-branch: mutant loses the timeout WARN — RED as expected"
fi
# DL8: git-enumeration failure ignored (no fallback) → S8 finds no link and allows.
if nwmutant 'dirlink-no-fallback' 's|ls-files -s -z > "\$_dl_f1" 2>/dev/null|ls-files -s -z > "$_dl_f1" 2>/dev/null \|\| true|;s|ls-files -o --exclude-standard -z > "\$_dl_f2" 2>/dev/null|ls-files -o --exclude-standard -z > "$_dl_f2" 2>/dev/null \|\| true|'; then M_DL8="$NWM"
  rmblocked "$T_s8" "$SID_s8"; PATH="$STUB_NOLS:$PATH" run_mutant "$M_DL8" "$T_s8" "$(mkjson "$SID_s8" false)"
  blocks_json "$OUT" \
    && no "TOOTH dirlink-no-fallback: mutant still blocks S8 — fallback not load-bearing" \
    || ok "TOOTH dirlink-no-fallback: mutant misses the link when git fails — RED as expected"
fi
# DL9: tracked leg of the enumeration broken (wrong mode filter) → S11 (tracked pre-session link) allows.
if nwmutant 'dirlink-tracked-leg' "s|grep -z '\\^120000 '|grep -z '^999999 '|"; then M_DL9="$NWM"
  rmblocked "$T_s11" "$SID_s11"; run_mutant "$M_DL9" "$T_s11" "$(mkjson "$SID_s11" false)"
  blocks_json "$OUT" \
    && no "TOOTH dirlink-tracked-leg: mutant still blocks S11 — tracked leg not load-bearing" \
    || ok "TOOTH dirlink-tracked-leg: mutant misses the tracked link — RED as expected"
fi
# DL10 (#1352 item 4): the UNTRACKED `ls-files -o` leg dropped → S1 (untracked, non-ignored link) allows.
if nwmutant 'dirlink-untracked-leg' 's|; cat "\$_dl_f2")|; true)|'; then M_DL10="$NWM"
  rmblocked "$T_s1" "$SID_s1"; run_mutant "$M_DL10" "$T_s1" "$(mkjson "$SID_s1" false)"
  blocks_json "$OUT" \
    && no "TOOTH dirlink-untracked-leg: mutant still blocks S1 — untracked leg not load-bearing" \
    || ok "TOOTH dirlink-untracked-leg: mutant misses the untracked link — RED as expected"
fi
# DL11 (#1352 item 3): the timeout validation removed → 'abc' is handed to timeout unchanged, no WARN.
if nwmutant 'dirlink-timeout-validation' '/SENTINEL-DIRLINK-TIMEOUT-START/,/SENTINEL-DIRLINK-TIMEOUT-END/d'; then M_DL11="$NWM"
  rm -f "$T_s14/.claude/.rsdd-retro-blocked-$SID_s14"
  TOLOG="$ROOT/tolog-m11"; : > "$TOLOG"; export TOLOG
  _sut_save="$SUT"; SUT="$M_DL11"
  RETRO_GATE_DIRLINK_TIMEOUT=abc run_gate_path "$STUB_TOLOG" "$T_s14" "$(mkjson "$SID_s14" false)"
  SUT="$_sut_save"
  { ! printf '%s' "$ERR" | grep -q 'RETRO_GATE_DIRLINK_TIMEOUT' && [ "$(head -n1 "$TOLOG")" = "abc" ]; } \
    && ok "TOOTH dirlink-timeout-validation: mutant passes 'abc' through with no WARN — RED as expected" \
    || no "TOOTH dirlink-timeout-validation: validation not load-bearing: ERR=$ERR first-arg=$(head -n1 "$TOLOG")"
fi
# DL12 (#1352 item 1): candidates word-split on newlines again → S12 (newline-named link) misses.
if nwmutant 'dirlink-newline-split' 's|for _lnk in \${_dl_cands\[@\]+"\${_dl_cands\[@\]}"}|for _lnk in $(printf "%s\\n" ${_dl_cands[@]+"${_dl_cands[@]}"})|'; then M_DL12="$NWM"
  rmblocked "$T_s12" "$SID_s12"; run_mutant "$M_DL12" "$T_s12" "$(mkjson "$SID_s12" false)"
  blocks_json "$OUT" \
    && no "TOOTH dirlink-newline-split: mutant still blocks S12 — NUL-delimiting not load-bearing" \
    || ok "TOOTH dirlink-newline-split: mutant misses the newline-named link — RED as expected"
fi
# DL13 (#1352 item 1): the fallback enumeration reverts to newline output → S13 misses.
if nwmutant 'dirlink-fallback-print' 's|-type l -xtype d -print0|-type l -xtype d -print|'; then M_DL13="$NWM"
  rmblocked "$T_s13" "$SID_s13"; _sut_save="$SUT"; SUT="$M_DL13"
  run_gate_path "$STUB_NOLS" "$T_s13" "$(mkjson "$SID_s13" false)"; SUT="$_sut_save"
  blocks_json "$OUT" \
    && no "TOOTH dirlink-fallback-print: mutant still blocks S13 — fallback -print0 not load-bearing" \
    || ok "TOOTH dirlink-fallback-print: mutant misses the newline-named fallback link — RED as expected"
fi
# CAT1: CATALOG.md exclusion removed → C1 and C3 block again.
if nwmutant 'catalog-not-excluded' '/SENTINEL-GENERATED-CATALOG-START/,/SENTINEL-GENERATED-CATALOG-END/d'; then M_CAT1="$NWM"
  rmblocked "$T_c1" "c1-sess"; run_mutant "$M_CAT1" "$T_c1" "$(mkjson "c1-sess" false)"
  _c1m=0; blocks_json "$OUT" && _c1m=1
  rmblocked "$T_c3" "c3-sess"; run_mutant "$M_CAT1" "$T_c3" "$(mkjson "c3-sess" false)"
  _c3m=0; blocks_json "$OUT" && _c3m=1
  [ "$_c1m$_c3m" = "11" ] \
    && ok "TOOTH catalog-not-excluded: mutant blocks C1 and C3 (RED as expected)" \
    || no "TOOTH catalog-not-excluded: expected both fixtures to block, got $_c1m$_c3m"
fi
# HB mutants (#1161): the builder lives in THIS file, so mutate its extracted text.
hb_mutant() { # <label> <sed-script> <expected FAIL: token>
  local label="$1" script="$2" want="$3" mtxt mout
  mtxt="$(printf '%s\n' "$HB_SRC" | sed "$script")"
  if [ "$mtxt" = "$HB_SRC" ]; then
    no "TOOTH $label: mutant identical to the builder — sed matched nothing (tooth not built)"; return
  fi
  mout="$(hb_checks "$mtxt" 2>/dev/null)"
  if printf '%s\n' "$mout" | grep -qF "FAIL:$want"; then
    ok "TOOTH $label: mutant trips FAIL:$want (RED as expected)"
  else
    no "TOOTH $label: mutant did NOT trip FAIL:$want — got [$(printf '%s' "$mout" | tr '\n' ' ')]"
  fi
}
hb_mutant "hb-skip-removed (skip glob ignored)" \
  '/SENTINEL-HB-SKIP-START/,/SENTINEL-HB-SKIP-END/d' "skipped-dir-must-not-be-mirrored"
hb_mutant "hb-firstwins-removed (re-link of a mirrored name)" \
  '/SENTINEL-HB-FIRSTWINS/d' "builder-stderr-must-be-empty"
hb_mutant "hb-jq-visible (excluded name no longer skipped)" \
  's/\[ "\$_n" = "jq" \] && continue/:/' "jq-must-be-hidden"
hb_mutant "hb-batch-dropped (no ln after a dir)" \
  's/if \[ "\${#_batch\[@\]}" -gt 0 \]; then ln -s -t "\$out_dir" -- "\${_batch\[@\]}"; fi/:/' "alpha-reachable"

# ── #1301 teeth: one mutant PER `find -H` site (list edges: each site is an independent scan).
# Built with the shared helper (lib/mutant.sh): a mutant that did not apply, is empty, is invalid
# bash, or would land in the live tree is REFUSED, so a green tooth cannot be a no-op.
# shellcheck source=lib/mutant.sh
. "$HERE/lib/mutant.sh"
FMUT="$ROOT/fmutkit"; mkdir -p "$FMUT"; cp -R "$FKIT/toolbelt" "$FMUT/toolbelt"
# l_tooth <name> <sed-expr> <case-fn>: build the mutant into the stub kit, then <case-fn> <mutant>
# must return 0 when the mutant misbehaves (its L-case assertion would FAIL).
l_tooth() {
  local name="$1" expr="$2" fn="$3" m="$FMUT/toolbelt/retro-gate.sh" mrc
  mutant_sed "$SUT" "$m" "$expr"; mrc=$?
  if [ "$mrc" -ne 0 ]; then no "TOOTH $name: mutant refused by lib/mutant.sh (rc=$mrc) — tooth not built"; return; fi
  if "$fn" "$m"; then ok "TOOTH $name: mutant misbehaves (RED as expected)"; else no "TOOTH $name: mutant behaved like the real SUT — no teeth"; fi
}
# l_run <mutant> <target> <sid>: run the mutant kit's gate, clearing block-once state first.
l_run() {
  local errf="$ROOT/lmut_err.$$"
  rm -f "$2"/.claude/.rsdd-retro-blocked-"$3" 2>/dev/null
  OUT="$(printf '%s' "$(mkjson "$3" false)" | SEED_LOG="$SEED_LOG_EN3" PATH="$MOCK_GH_DIR:$PATH" "$BASH_BIN" "$1" "$2" 2>"$errf")"; RC=$?
  ERR="$(cat "$errf")"; rm -f "$errf"
}
lc_partb()   { l_run "$1" "$ROOT/t-l1-link" "$SID_l1"; [ -z "$OUT" ] && printf '%s' "$ERR" | grep -q 'branch=no-change'; }
lc_deg_blk() { l_run "$1" "$ROOT/t-l5-link" "l5-sess"; ! printf '%s' "$OUT" | grep -qF 'is OLDER than newest changed block'; }
lc_deg_rtr() { l_run "$1" "$ROOT/t-l3-link" "l3-sess"; printf '%s' "$OUT" | grep -qF '"decision":"block"'; }
lc_seed()    { : > "$SEED_LOG_EN3"; l_run "$1" "$ROOT/t-l4-link" "$SID_l4"; ! grep -q 'l4real' "$SEED_LOG_EN3"; }
l_tooth "l-partb-scan (find -H dropped from the Part B scan)" \
  's/find -H "\$TARGET" -newer/find "$TARGET" -newer/' lc_partb
l_tooth "l-degraded-block-scan (find -H dropped from the degraded block-mtime scan)" \
  's/find -H "\$TARGET" -type f -name/find "$TARGET" -type f -name/' lc_deg_blk
l_tooth "l-degraded-retro-scan (find -H dropped from the degraded retro scan)" \
  's/find -H "\$TARGET" -maxdepth 4/find "$TARGET" -maxdepth 4/' lc_deg_rtr
l_tooth "l-seeding-scan (find -H dropped from the issue-seeding scan)" \
  's/find -H "\$target" -maxdepth 4/find "$target" -maxdepth 4/' lc_seed

# ── #1301 item 3 teeth: the probe-failure handling. The mutant replaces the gate inside PFKIT
# (the stub kit whose probe returns $PF_RC), so P1/P2 run against exactly the mutated bytes.
# p_tooth <name> <sed-expr> <case-fn> — <case-fn> returns 0 when the mutant misbehaves.
p_tooth() {
  local name="$1" expr="$2" fn="$3" m="$PFKIT/toolbelt/retro-gate.sh" mrc
  mutant_sed "$SUT" "$m" "$expr"; mrc=$?
  if [ "$mrc" -ne 0 ]; then no "TOOTH $name: mutant refused by lib/mutant.sh (rc=$mrc) — tooth not built"; return; fi
  if "$fn"; then ok "TOOTH $name: mutant misbehaves (RED as expected)"; else no "TOOTH $name: mutant behaved like the real SUT — no teeth"; fi
}
pc_allows()  { run_pf 5 "$T_p1" "$SID_p1"; [ -z "$OUT" ]; }
pc_nowarn()  { run_pf 5 "$T_p1" "$SID_p1"; ! printf '%s' "$ERR" | grep -qF 'nested-worktree probe failed (rc=5)'; }
pc_rc3warn() { run_pf 3 "$T_p1" "$SID_p1"; printf '%s' "$ERR" | grep -qF 'nested-worktree probe failed'; }
p_tooth "p-failopen (a failed probe exits 0 → false ALLOW)" \
  's/^if \[ "\$_nw_rc" -ne 0 \] && \[ "\$_nw_rc" -ne 3 \]; then$/&\n  exit 0/' pc_allows
p_tooth "p-warn-dropped (probe failure is silent)" \
  '/SENTINEL-NW-PROBE-FAIL-START/,/SENTINEL-NW-PROBE-FAIL-END/d' pc_nowarn
p_tooth "p-rc3-double-warn (rc 3 no longer exempt from the gate-level WARN)" \
  's/"\$_nw_rc" -ne 3 \]/"$_nw_rc" -ne 99 ]/' pc_rc3warn

# ESC mutants: build from the SUT text in bash (no sed-escaping of quote characters).
_esc_orig='s=${s//$_dq/"$_esc_dq"}'
_sut_text="$(cat "$SUT")"
case "$_sut_text" in
  *"$_esc_orig"*) : ;;
  *) no "TOOTH ESC: anchor line for _json_escape_reason not found in SUT (drifted?)" ;;
esac
# ESC-A: replacement carries an '&' (expands to the match on bash >= 5.2) → ESC1 values break.
_esc_a='s="${s//$_dq/\\\"&}"'
printf '%s\n' "${_sut_text/"$_esc_orig"/"$_esc_a"}" > "$MUT_KIT/toolbelt/mutant-esc-amp.sh"
if cmp -s "$SUT" "$MUT_KIT/toolbelt/mutant-esc-amp.sh"; then
  no "TOOTH esc-amp: mutant identical to SUT (tooth not built)"
elif [ -n "$(esc_checks "$MUT_KIT/toolbelt/mutant-esc-amp.sh")" ]; then
  ok "TOOTH esc-amp: '&' in the replacement operand breaks esc_checks (RED as expected)"
else
  no "TOOTH esc-amp: esc_checks stayed green under an '&' replacement — no teeth"
fi
# ESC-B: quote escaping dropped entirely → ESC1 values break.
_esc_b=': # quote escaping removed'
printf '%s\n' "${_sut_text/"$_esc_orig"/"$_esc_b"}" > "$MUT_KIT/toolbelt/mutant-esc-drop.sh"
if cmp -s "$SUT" "$MUT_KIT/toolbelt/mutant-esc-drop.sh"; then
  no "TOOTH esc-drop: mutant identical to SUT (tooth not built)"
elif [ -n "$(esc_checks "$MUT_KIT/toolbelt/mutant-esc-drop.sh")" ]; then
  ok "TOOTH esc-drop: removing the quote escape breaks esc_checks (RED as expected)"
else
  no "TOOTH esc-drop: esc_checks stayed green with the quote escape removed — no teeth"
fi
# ESC-D (#1301 item 6): the control-character block removed → the new ESC1 cases go red. And a
# partial mutant — the LAST code point (31) dropped from the loop list — proves the edge is checked.
mutant_sed "$SUT" "$MUT_KIT/toolbelt/mutant-esc-ctrl.sh" '/SENTINEL-ESC-CTRL-START/,/SENTINEL-ESC-CTRL-END/d'; _escd_rc=$?
if [ "$_escd_rc" -ne 0 ]; then
  no "TOOTH esc-ctrl: mutant refused by lib/mutant.sh (rc=$_escd_rc) — tooth not built"
elif [ -n "$(esc_checks "$MUT_KIT/toolbelt/mutant-esc-ctrl.sh")" ]; then
  ok "TOOTH esc-ctrl: removing the control-character escape breaks esc_checks (RED as expected)"
else
  no "TOOTH esc-ctrl: esc_checks stayed green without the control-character escape — no teeth"
fi
mutant_sed "$SUT" "$MUT_KIT/toolbelt/mutant-esc-ctrl31.sh" 's/ 30 31; do/ 30; do/'; _escd_rc=$?
if [ "$_escd_rc" -ne 0 ]; then
  no "TOOTH esc-ctrl-last: mutant refused by lib/mutant.sh (rc=$_escd_rc) — tooth not built"
elif esc_checks "$MUT_KIT/toolbelt/mutant-esc-ctrl31.sh" | grep -qF 'FAIL:ctrl-last'; then
  ok "TOOTH esc-ctrl-last: dropping 0x1f from the loop trips the ctrl-last edge (RED as expected)"
else
  no "TOOTH esc-ctrl-last: ctrl-last edge stayed green with 0x1f unescaped — no teeth"
fi
# ESC-C: the pre-#1167 inline nested-quote operand restored → the structural pin (ESC3) goes red.
_esc_c='s="${s//$_dq/"\\$_dq"}"'
printf '%s\n' "${_sut_text/"$_esc_orig"/"$_esc_c"}" > "$MUT_KIT/toolbelt/mutant-esc-old.sh"
if cmp -s "$SUT" "$MUT_KIT/toolbelt/mutant-esc-old.sh"; then
  no "TOOTH esc-old: mutant identical to SUT (tooth not built)"
elif ! esc_pin_ok "$MUT_KIT/toolbelt/mutant-esc-old.sh"; then
  ok "TOOTH esc-old: restoring the inline nested-quote operand trips the ESC3 pin (RED as expected)"
else
  no "TOOTH esc-old: ESC3 pin stayed green with the old operand restored — no teeth"
fi

# ── #1258 teeth: the Stop-branch log and its seeding evidence ────────────────
# slmut <name> <sed-expr>: build a mutant (refused by lib/mutant.sh if empty/identical/broken) and
# leave its path in SLM; returns non-zero when the mutant could not be built.
slmut() {
  SLM="$MUT_KIT/toolbelt/mutant-sl-$1.sh"
  mutant_sed "$SUT" "$SLM" "$2"; _slm_rc=$?
  [ "$_slm_rc" -eq 0 ] || no "TOOTH sl-$1: mutant refused by lib/mutant.sh (rc=$_slm_rc) — tooth not built"
  return "$_slm_rc"
}
# trap dropped → no line is ever written
if slmut trap-dropped 's/^trap _stop_log_write EXIT$/:/'; then
  _t="$ROOT/slt1"; mkgit "$_t"; mksessionfile "$_t" slt1 "202609050800"
  run_mutant "$SLM" "$_t" "$(mkjson slt1 false)"
  [ "$(sl_lines "$_t")" = "0" ] && ok "TOOTH sl-trap-dropped: without the EXIT trap no Stop is logged (SL1a goes RED)" \
    || no "TOOTH sl-trap-dropped: log still written without the trap — no teeth"
fi
# rotation dropped → the log grows without bound
if slmut no-rotation 's/-gt "\$_STOP_LOG_MAX"/-gt 999999999/'; then
  _t="$ROOT/slt2"; mkgit "$_t"; mksessionfile "$_t" slt2 "202609050800"
  for _i in $(seq 1 700); do printf 'old line %s\n' "$_i"; done > "$_t/.claude/$SL_NAME"
  run_mutant "$SLM" "$_t" "$(mkjson slt2 false)"
  [ "$(sl_lines "$_t")" -gt 300 ] && ok "TOOTH sl-no-rotation: without rotation the log keeps growing (SL7 goes RED)" \
    || no "TOOTH sl-no-rotation: log still bounded without rotation — no teeth"
fi
# gh-not-authenticated skip note dropped → skip becomes silent in the log
if slmut skip-note-dropped '/_seed_note "skipped:gh-not-authenticated"/d'; then
  _t="$ROOT/slt3"; mk_sl_conforming "$_t" slt3
  OUT="$(printf '%s' "$(mkjson slt3 false)" | PATH="$FAIL_AUTH_GH_DIR:$PATH" "$BASH_BIN" "$SLM" "$_t" 2>/dev/null)"
  sl_last "$_t" | grep -qF 'branch=retro-conforming' || no "TOOTH sl-skip-note-dropped: positive control — mutant did not reach retro-conforming"
  sl_last "$_t" | grep -qF 'skipped:gh-not-authenticated' \
    && no "TOOTH sl-skip-note-dropped: skip reason still logged — no teeth" \
    || ok "TOOTH sl-skip-note-dropped: dropping the note makes the skip silent (SL5 goes RED)"
fi
# summary note dropped → the seeder's summary: line never reaches the log
if slmut summary-dropped '/_seed_note "\$(basename "\$rf") \$_summary"/d'; then
  _t="$ROOT/slt4"; mk_sl_conforming "$_t" slt4
  mkdir -p "$ROOT/slt4kit"; cp -r "$FKIT/toolbelt" "$ROOT/slt4kit/"; cp "$SLM" "$ROOT/slt4kit/toolbelt/retro-gate.sh"
  OUT="$(printf '%s' "$(mkjson slt4 false)" | PATH="$MOCK_GH_DIR:$PATH" "$BASH_BIN" "$ROOT/slt4kit/toolbelt/retro-gate.sh" "$_t" 2>/dev/null)"
  sl_last "$_t" | grep -qF 'branch=retro-conforming' || no "TOOTH sl-summary-dropped: positive control — mutant did not reach retro-conforming"
  sl_last "$_t" | grep -qF 'summary: created=' \
    && no "TOOTH sl-summary-dropped: summary still logged — no teeth" \
    || ok "TOOTH sl-summary-dropped: dropping the note loses the seeder summary (SL4b goes RED)"
fi
# degraded typed as plain failure → the typed note loses its name
if slmut degraded-untyped 's/_seed_note "seeder-degraded:/_seed_note "seeder-x:/'; then
  _t="$ROOT/slt5"; mk_sl_conforming "$_t" slt5
  mkdir -p "$ROOT/slt5kit"; cp -r "$FKIT_DEG/toolbelt" "$ROOT/slt5kit/"; cp "$SLM" "$ROOT/slt5kit/toolbelt/retro-gate.sh"
  OUT="$(printf '%s' "$(mkjson slt5 false)" | PATH="$MOCK_GH_DIR:$PATH" "$BASH_BIN" "$ROOT/slt5kit/toolbelt/retro-gate.sh" "$_t" 2>/dev/null)"
  sl_last "$_t" | grep -qF 'branch=retro-conforming' || no "TOOTH sl-degraded-untyped: positive control — mutant did not reach retro-conforming"
  sl_last "$_t" | grep -qF 'seeder-degraded' \
    && no "TOOTH sl-degraded-untyped: typed note still present — no teeth" \
    || ok "TOOTH sl-degraded-untyped: renaming the note loses the typed degraded reason (SL6 goes RED)"
fi
# shared rotation temp name restored → the SL11a pin goes RED
if slmut tmp-shared 's/"\$f\.tmp\.\$\$"/"$f.tmp"/g'; then
  grep -qF '"$f.tmp.$$"' "$SLM" && no "TOOTH sl-tmp-shared: per-process temp still present — mutant not effective" \
    || ok "TOOTH sl-tmp-shared: shared temp name restored loses the per-process pin (SL11a goes RED)"
fi
# error-helper branch dropped → helper-load failures are unlogged again
if slmut helper-unlogged 's/^_STOP_BRANCH="error-helper"/_STOP_BRANCH=""/'; then
  mkdir -p "$ROOT/slt8kit/toolbelt"; cp "$SLM" "$ROOT/slt8kit/toolbelt/retro-gate.sh"
  _t="$ROOT/slt8"; mkgit "$_t"
  printf '%s' "$(mkjson slt8 false)" | "$BASH_BIN" "$ROOT/slt8kit/toolbelt/retro-gate.sh" "$_t" >/dev/null 2>&1
  [ -n "$(sl_last "$_t")" ] || no "TOOTH sl-helper-unlogged: positive control — no log line written"
  sl_last "$_t" | grep -qF 'branch=error-helper' && no "TOOTH sl-helper-unlogged: still error-helper — no teeth" \
    || ok "TOOTH sl-helper-unlogged: dropping the branch name leaves helper failures unclassified (SL12 goes RED)"
fi
# mode=degraded dropped
if slmut mode-dropped 's/ mode=degraded//'; then
  _t="$ROOT/slt7"; mkgit "$_t"
  run_mutant "$SLM" "$_t" "$(mkjson slt7 false)"
  sl_last "$_t" | grep -qF 'branch=' || no "TOOTH sl-mode-dropped: positive control — no log line written"
  sl_last "$_t" | grep -qF 'mode=degraded' && no "TOOTH sl-mode-dropped: still marked degraded — no teeth" \
    || ok "TOOTH sl-mode-dropped: dropping the marker hides a degraded check (SL13a goes RED)"
fi
# write failure leaks into the exit code
if slmut rc-leak "s/^\\(    printf 'retro-gate: WARN: stop-log write failed.*>&2\\)\$/\\1; exit 1/"; then
  _t="$ROOT/slt6"; mkgit "$_t"; printf 'x' > "$_t/.claude"
  run_mutant "$SLM" "$_t" "$(mkjson slt6 false)"
  [ "$RC" -ne 0 ] && ok "TOOTH sl-rc-leak: a write failure that exits non-zero is caught (SL8a goes RED)" \
    || no "TOOTH sl-rc-leak: exit code still 0 — mutant not effective"
fi

# ─── git-clean guard: teeth must not leak mutant files into the live tree ─────
# When the live tree is not under git the guard cannot run: that used to drop ONE case silently
# (the 146-vs-147 host difference in kit issue #1167 item 7); now it is a counted SKIP.
if [ -n "$_GIT_ROOT_FOR_TEETH" ]; then
  _GIT_AFTER_TEETH="$(git -C "$_GIT_ROOT_FOR_TEETH" status --porcelain 2>/dev/null || true)"
  if [ "$_GIT_BEFORE_TEETH" = "$_GIT_AFTER_TEETH" ]; then
    ok "TEETH git-clean: live tree unchanged during teeth run"
  else
    no "TEETH git-clean: live tree modified during teeth: before=$(printf '%s' "$_GIT_BEFORE_TEETH" | head -3) after=$(printf '%s' "$_GIT_AFTER_TEETH" | head -3)"
  fi
else
  printf '  SKIP  TEETH git-clean: live tree is not under git — guard cannot run on this host\n'
fi

# ─── Summary ─────────────────────────────────────────────────────────────────
echo
echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] && exit 0 || exit 1
