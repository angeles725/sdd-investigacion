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
cp "$HERE/../lib/block-files.sh" "$MUT_KIT/toolbelt/lib/"
cp "$HERE/../lib/retro-status.sh" "$MUT_KIT/toolbelt/lib/"
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

# ─── Summary ─────────────────────────────────────────────────────────────────
echo
echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] && exit 0 || exit 1
