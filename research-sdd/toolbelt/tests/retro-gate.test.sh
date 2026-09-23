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
build_hermetic_nojq_bin() {
  local src_path="$1" out_dir="$2" _oifs _pd _exe _n
  _oifs="$IFS"; IFS=':'
  for _pd in $src_path; do
    IFS="$_oifs"
    [ -d "$_pd" ] || continue
    while IFS= read -r -d '' _exe; do
      _n="$(basename "$_exe")"
      [ "$_n" = "jq" ] && continue
      [ -e "$out_dir/$_n" ] && continue
      ln -s "$_exe" "$out_dir/$_n"
    done < <(find "$_pd" -maxdepth 1 \( -type f -o -type l \) -executable -print0 2>/dev/null)
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
# Stub seeder: logs "<retro> <flags>" to SEED_LOG, then exits 0
cat > "$FKIT/toolbelt/stage-retro-issues.sh" << 'STUBEOF'
#!/usr/bin/env bash
# EN3 test stub: log all arguments to SEED_LOG (env var)
printf '%s\n' "$*" >> "${SEED_LOG:-/dev/null}"
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
# Partial seeder: creates 1 issue then hits rate limit
printf 'created issue: https://github.com/test/repo/issues/42\n'
printf 'partial: rate limit exceeded after 1 issue\n' >&2
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

# ─── EN3-f: _safe_grep_count rc≥2 path ──────────────────────────────────────
# Verifies that a grep rc=2 (ENOMEM/SIGPIPE) produces a WARN and falls back to 0.
# Hermetic: a PATH-prepended stub intercepts 'grep -c created issue' and exits 2;
# all other grep invocations pass through to /usr/bin/grep.
FKIT_GRCERR="$ROOT/fkit_grcerr"
mkdir -p "$FKIT_GRCERR/toolbelt/lib"
cp "$HERE/../lib/block-files.sh"    "$FKIT_GRCERR/toolbelt/lib/"
cp "$HERE/../lib/retro-status.sh"   "$FKIT_GRCERR/toolbelt/lib/"
cp "$HERE/../lib/retro-grammar.sh"  "$FKIT_GRCERR/toolbelt/lib/"
cp "$HERE/../verify-retro.sh"       "$FKIT_GRCERR/toolbelt/"
cat > "$FKIT_GRCERR/toolbelt/stage-retro-issues.sh" << 'GRCSEEDEOF'
#!/usr/bin/env bash
printf 'created issue: https://github.com/test/repo/issues/99\n'
exit 0
GRCSEEDEOF
chmod +x "$FKIT_GRCERR/toolbelt/stage-retro-issues.sh"
cp "$SUT" "$FKIT_GRCERR/toolbelt/retro-gate.sh"
# Stub grep: exit 2 for '-c created issue' only; all other calls pass through
MOCKBIN_GRC="$ROOT/mockbin_grc"
mkdir -p "$MOCKBIN_GRC"
cat > "$MOCKBIN_GRC/grep" << 'GREPSTUBEOF'
#!/usr/bin/env bash
if [ "$1" = "-c" ] && [ "$2" = "created issue" ]; then
  exit 2
fi
exec /usr/bin/grep "$@"
GREPSTUBEOF
chmod +x "$MOCKBIN_GRC/grep"
TGRC="$ROOT/tgrc"; mkgit "$TGRC"; SGRC="grc-sess"
mksessionfile "$TGRC" "$SGRC" "202609050800"
mkblock "$TGRC" "grc-block1.md" "2026-09-05T10:00:00"
touch -t 202609051000 "$TGRC/grc-block1.md"
mkretro "$TGRC" "2026-09-05-grc.md" 1
touch -t 202609051200 "$TGRC/retros/2026-09-05-grc.md"
_jgrc="$(mkjson "$SGRC" "false")"
errf_grc="$ROOT/err_grc.$$"
printf '%s' "$_jgrc" | PATH="$MOCKBIN_GRC:$MOCK_GH_DIR:$PATH" \
  "$BASH_BIN" "$FKIT_GRCERR/toolbelt/retro-gate.sh" "$TGRC" >"$ROOT/out_grc.$$" 2>"$errf_grc"
ERR_GRC="$(cat "$errf_grc")"; rm -f "$errf_grc" "$ROOT/out_grc.$$"
printf '%s' "$ERR_GRC" | grep -q 'grep error (rc=2)' \
  && ok "EN3-f: grep rc=2 in _safe_grep_count → WARN emitted" \
  || no "EN3-f: grep rc=2 in _safe_grep_count → expected 'grep error (rc=2)' in stderr; got: $ERR_GRC"
printf '%s' "$ERR_GRC" | grep -q 'created=0' \
  && ok "EN3-f: grep rc=2 fallback → created=0 in summary" \
  || no "EN3-f: grep rc=2 fallback → expected 'created=0' in summary; got: $ERR_GRC"

# ─── TEETH (--prove-teeth) ───────────────────────────────────────────────────
PROVE_TEETH="${1:-}"
[ "$PROVE_TEETH" != "--prove-teeth" ] && {
  echo
  echo "== $pass passed · $fail failed =="
  [ "$fail" -eq 0 ] && exit 0 || exit 1
}

echo
echo "-- TEETH: mutation controls --"

# Kit sandbox for mutants: mutant must live under a toolbelt/ dir so that
# SELF_DIR-relative lib paths (lib/block-files.sh, lib/retro-status.sh,
# verify-retro.sh) resolve correctly — the same constraint the real SUT has.
MUT_KIT="$ROOT/mutkit"
mkdir -p "$MUT_KIT/toolbelt/lib"
cp "$HERE/../lib/block-files.sh"   "$MUT_KIT/toolbelt/lib/"
cp "$HERE/../lib/retro-status.sh"  "$MUT_KIT/toolbelt/lib/"
cp "$HERE/../lib/retro-grammar.sh" "$MUT_KIT/toolbelt/lib/"
cp "$VR" "$MUT_KIT/toolbelt/verify-retro.sh"

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

# ─── Summary ─────────────────────────────────────────────────────────────────
echo
echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] && exit 0 || exit 1
