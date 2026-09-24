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
M16_path="$MUT_KIT/toolbelt/mutant-retro-find-renames.sh"
awk '
  /# SENTINEL-RETRO-SESSION-START/ { in_s=1 }
  /# SENTINEL-RETRO-SESSION-END/   { in_s=0 }
  in_s && /--diff-filter=A -M/ { gsub(/--diff-filter=A -M/,"--diff-filter=A"); print; next }
  { print }
' "$SUT" > "$M16_path"; chmod +x "$M16_path"
# Sabotage check: renamed sentinel → awk produces no diff (same technique as TOOTH 15)
_M16_sab="$MUT_KIT/toolbelt/mutant-retro-find-renames-sab.sh"
awk '{ gsub(/SENTINEL-RETRO-SESSION-START/,"SENTINEL-RETRO-SESSION-XSTART"); print }' "$SUT" \
  > "$_M16_sab"; chmod +x "$_M16_sab"
awk '
  /# SENTINEL-RETRO-SESSION-START/ { in_s=1 }
  /# SENTINEL-RETRO-SESSION-END/   { in_s=0 }
  in_s && /--diff-filter=A -M/ { gsub(/--diff-filter=A -M/,"--diff-filter=A"); print; next }
  { print }
' "$_M16_sab" > "$MUT_KIT/toolbelt/mutant-retro-find-renames-sab2.sh"
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

# ─── git-clean guard: teeth must not leak mutant files into the live tree ─────
if [ -n "$_GIT_ROOT_FOR_TEETH" ]; then
  _GIT_AFTER_TEETH="$(git -C "$_GIT_ROOT_FOR_TEETH" status --porcelain 2>/dev/null || true)"
  if [ "$_GIT_BEFORE_TEETH" = "$_GIT_AFTER_TEETH" ]; then
    ok "TEETH git-clean: live tree unchanged during teeth run"
  else
    no "TEETH git-clean: live tree modified during teeth: before=$(printf '%s' "$_GIT_BEFORE_TEETH" | head -3) after=$(printf '%s' "$_GIT_AFTER_TEETH" | head -3)"
  fi
fi

# ─── Summary ─────────────────────────────────────────────────────────────────
echo
echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] && exit 0 || exit 1
