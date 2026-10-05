#!/usr/bin/env bash
# hook-wiring.test.sh — regression harness for lib/hook-wiring.sh (kit issue #1108/#1109): the
# single source of truth for "is this target's Stop hook registered to run retro-gate?", shared
# by sweep-retros.sh's WIRING-STATUS fleet pass, verify-registry.sh's 'hook yes' claim check, and
# research-sdd-status.sh's per-target self-report line.
#
# Two entry points are pinned:
#   hook_stop_wiring_state_var <dir>  — sets $HOOK_WIRING_STATE, no subshell fork. sweep-retros.sh
#                                        uses this in its per-target WIRING-STATUS loop (kit issue
#                                        #1108 round 2: a redundant fork per fleet target measured
#                                        as a real RSDD_PROFILE regression).
#   hook_stop_wiring_state <dir>      — convenience wrapper, echoes the state for $(...) capture.
#                                        Used where the caller only needs the state once.
#
# Mutation teeth mutate a COPY of the LIB FILE on disk and source THAT (never a hand-redefined
# stand-in function called directly) — a stand-in only proves the test file's own inline logic
# runs, not that the real implementation reacts to a real mutation (kit issue #1108 round 2 RDD
# finding: the prior teeth here redefined hook_stop_wiring_state() as a constant and called it
# directly, which is circular — it could not have caught a real regression in the sourced lib).
#
# HERMETICITY (kit issue #1140 round-2 review, Blocking 4): the git-root walk-up in
# lib/hook-wiring.sh climbs from a target all the way to `/` unless RSDD_HOOK_WIRING_CEILING is
# set. `$ROOT` below comes from `mktemp -d`, which honors `$TMPDIR` — if `$TMPDIR` ever points
# inside a REAL git repository (this kit checkout is one), every fixture in this suite meant to
# model "clean git root" or "no git repo at all" would silently pick up the ENCLOSING repo's real
# `.git` instead. The ceiling is set once, globally, right after `$ROOT` is created, so this is not
# a per-fixture concern for the rest of the suite; cases 13a/13b below reproduce the bug and prove
# the ceiling is what fixes it, with $TMPDIR genuinely pointed inside a repo.
#
# Usage: hook-wiring.test.sh [--prove-teeth]
# Exit: 0 = every assertion held · 1 = a regression · 2 = harness error.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="$HERE/../lib/hook-wiring.sh"
[ -f "$LIB" ] || { echo "FATAL: lib not found: $LIB" >&2; exit 2; }
BASH_BIN="$(type -P bash)"; [ -n "$BASH_BIN" ] || { echo "FATAL: bash not on PATH" >&2; exit 2; }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
RSDD_HOOK_WIRING_CEILING="$(dirname "$ROOT")"
export RSDD_HOOK_WIRING_CEILING
pass=0; fail=0
ok() { printf '  PASS  %-58s %s\n' "$1" "${2:-}"; pass=$((pass+1)); }
no() { printf '  FAIL  %-58s %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

echo "== hook-wiring.test.sh =="

# shellcheck source=../lib/hook-wiring.sh
. "$LIB"
declare -F hook_stop_wiring_state >/dev/null 2>&1 || { echo "FATAL: $LIB did not define hook_stop_wiring_state" >&2; exit 2; }
declare -F hook_stop_wiring_state_var >/dev/null 2>&1 || { echo "FATAL: $LIB did not define hook_stop_wiring_state_var" >&2; exit 2; }

# wire_settings <dir> <json> : write <dir>/.claude/settings.json
wire_settings() { mkdir -p "$1/.claude"; printf '%s' "$2" > "$1/.claude/settings.json"; }

# assert_state <case-label> <dir> <expected>
# Runs BOTH entry points against the same fixture and requires them to agree — the wrapper is a
# thin pass-through, so any disagreement means the wrapper drifted from the fork-free core.
assert_state() {
  local label="$1" d="$2" want="$3" got_wrap got_var
  got_wrap="$(hook_stop_wiring_state "$d")"
  hook_stop_wiring_state_var "$d"; got_var="$HOOK_WIRING_STATE"
  if [ "$got_wrap" = "$want" ] && [ "$got_var" = "$want" ]; then
    ok "$label"
  else
    no "$label" "wrapper=[$got_wrap] var=[$got_var] want=[$want]"
  fi
}

# 1 — no .claude/settings.json at all → absent-settings.
d="$ROOT/t1"; mkdir -p "$d"
assert_state "1 no settings.json → absent-settings" "$d" "absent-settings"

# 2 — settings.json registers retro-gate under Stop → wired.
d="$ROOT/t2"; mkdir -p "$d"
wire_settings "$d" '{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"/x/.claude/hooks/retro-gate-stop.sh"}]}]}}'
assert_state "2 Stop registers retro-gate → wired" "$d" "wired"

# 3 — settings.json exists but no retro-gate anywhere → unwired.
d="$ROOT/t3"; mkdir -p "$d"
wire_settings "$d" '{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"/x/other-hook.sh"}]}]}}'
assert_state "3 Stop present, no retro-gate → unwired" "$d" "unwired"

# 4 — retro-gate appears ONLY under SessionStart (not Stop) → unwired (scoped strictly to Stop).
d="$ROOT/t4"; mkdir -p "$d"
wire_settings "$d" '{"hooks":{"SessionStart":[{"matcher":"","hooks":[{"type":"command","command":"/x/retro-gate.sh"}]}]}}'
assert_state "4 retro-gate under SessionStart only → unwired (not Stop)" "$d" "unwired"

# 5 — retro-gate appears in permissions.deny (not under Stop) → unwired.
d="$ROOT/t5"; mkdir -p "$d"
wire_settings "$d" '{"permissions":{"deny":["Bash(retro-gate:*)"]},"hooks":{"Stop":[]}}'
assert_state "5 retro-gate in permissions.deny → unwired" "$d" "unwired"

# 6 — settings.json unreadable (chmod 000) → unreadable. Skipped when running as root (root
#     bypasses permission bits, matching sweep-retros.test.sh's own skip convention).
if [ "$(id -u)" != "0" ]; then
  d="$ROOT/t6"; mkdir -p "$d"
  wire_settings "$d" '{"hooks":{"Stop":[]}}'
  chmod 000 "$d/.claude/settings.json"
  assert_state "6 unreadable settings.json → unreadable" "$d" "unreadable"
  chmod 644 "$d/.claude/settings.json"   # restore so cleanup works
else
  echo "  SKIP  6 unreadable settings.json → unreadable (running as root; permission bits bypassed)"
fi

# 7 — non-existent target dir → absent-settings (never a crash).
d="$ROOT/t7-absent"
assert_state "7 non-existent target dir → absent-settings" "$d" "absent-settings"

# --- kit issue #1135: 'wired-off-root' — settings.json is syntactically wired but the registered
# path is NOT its own git root (an ancestor owns the nearest `.git`). Downgrade applies ONLY to
# the wired case: an unwired/absent-settings/unreadable target off-root makes no active-firing
# claim, so there is nothing false to downgrade.

# 8 — POSITIVE CONTROL: registered path IS its own git root (git init'd there directly) and wired →
#     stays 'wired', never downgraded. Pins that a normal git-root target is unaffected.
d="$ROOT/t8-root"; mkdir -p "$d"
git init -q "$d" >/dev/null 2>&1
wire_settings "$d" '{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"/x/.claude/hooks/retro-gate-stop.sh"}]}]}}'
assert_state "8 registered path is its own git root, wired → wired (unaffected)" "$d" "wired"

# 9 — the three.js SHAPE (structural fact only — kit issue #1140 round-2 review: this predicate
#     does NOT know or claim where sessions actually launch from; see lib/hook-wiring.sh's own
#     header): registered path is a NESTED subdirectory of a git repo (git root is an ancestor),
#     settings.json wired at the nested path → wired-off-root, not wired.
d_root="$ROOT/t9-gitroot"; d="$d_root/nested"; mkdir -p "$d"
git init -q "$d_root" >/dev/null 2>&1
wire_settings "$d" '{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"/x/.claude/hooks/retro-gate-stop.sh"}]}]}}'
assert_state "9 nested non-root path, wired → wired-off-root (three.js shape)" "$d" "wired-off-root"

# 10 — a nested non-root path that is UNWIRED must stay 'unwired', never 'wired-off-root': no
#     active-firing claim is being made, so there is nothing to downgrade (matches kit issue #1135's
#     own fixture scope: "a nested non-root row with hook no/deferred — no WARN").
d_root="$ROOT/t10-gitroot"; d="$d_root/nested"; mkdir -p "$d"
git init -q "$d_root" >/dev/null 2>&1
wire_settings "$d" '{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"/x/other-hook.sh"}]}]}}'
assert_state "10 nested non-root path, unwired → unwired (not downgraded)" "$d" "unwired"

# 11 — a nested non-root path with NO settings.json at all must stay 'absent-settings', never
#     'wired-off-root' — the downgrade only ever applies to an already-'wired' result.
d_root="$ROOT/t11-gitroot"; d="$d_root/nested"; mkdir -p "$d"
git init -q "$d_root" >/dev/null 2>&1
assert_state "11 nested non-root path, no settings.json → absent-settings (not downgraded)" "$d" "absent-settings"

# 12 — registered path is NOT inside any git repository at all (walk-up reaches `/` with no `.git`
#     found) and wired → stays 'wired'. No git root to compare against, so nothing is downgraded.
d="$ROOT/t12-nogit"; mkdir -p "$d"
wire_settings "$d" '{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"/x/.claude/hooks/retro-gate-stop.sh"}]}]}}'
assert_state "12 not inside any git repo, wired → wired (no root to compare)" "$d" "wired"

# --- kit issue #1140 round-2 review, Blocking 4: TMPDIR-inside-a-repo hermeticity ------------------
# Reproduces the exact bug class this suite's own $RSDD_HOOK_WIRING_CEILING (set above) protects
# against, with $TMPDIR genuinely pointed inside a real git repository: without a ceiling, the
# walk-up (correctly, by design) keeps climbing past a fixture's own sandbox root and finds the
# ENCLOSING repo's real `.git`, misreporting a plain wired target as wired-off-root. This builds
# its own throwaway enclosing repo (never touches the actual kit checkout) so the reproduction is
# fully self-contained.
_encl="$ROOT/t13-enclosing-repo"; mkdir -p "$_encl"
git init -q "$_encl" >/dev/null 2>&1
_old_tmpdir="${TMPDIR:-}"; _had_tmpdir=0; [ -n "${TMPDIR+x}" ] && _had_tmpdir=1
TMPDIR="$_encl"; export TMPDIR
_inner_root="$(mktemp -d)"   # now lands under $_encl — simulates a host whose real $TMPDIR sits inside a repo
d="$_inner_root/target-no-own-git"; mkdir -p "$d"
wire_settings "$d" '{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"/x/.claude/hooks/retro-gate-stop.sh"}]}]}}'

# 13a — CONTROL, no per-fixture ceiling: proves the TMPDIR-bleed-in HAZARD is real, not
#      hypothetical (kit r3 review nit — distinct from case 9: case 9's 'wired-off-root' is the
#      PRODUCT correctly detecting a deliberately nested target; this case's SAME-LOOKING outcome
#      has a different CAUSE — an unrelated enclosing repo bleeding into a fixture never meant to
#      be nested at all, purely because $TMPDIR happens to sit inside one). The suite-wide ceiling
#      (dirname of $ROOT) does not reach this far down — $_encl is BELOW it — so this reproduces
#      exactly what an unset RSDD_HOOK_WIRING_CEILING would do on a real host whose $TMPDIR sits
#      inside a repo.
_saved_ceiling="$RSDD_HOOK_WIRING_CEILING"
unset RSDD_HOOK_WIRING_CEILING
r13a="$(hook_stop_wiring_state "$d")"
if [ "$r13a" = "wired-off-root" ]; then
  ok "13a (control) TMPDIR inside a repo, no ceiling → unrelated enclosing repo bleeds in (hermeticity hazard reproduced, not case 9's intentional detection)"
else
  no "13a (control) TMPDIR inside a repo, no ceiling → expected the bleed-in hazard to reproduce" "got [$r13a]"
fi
export RSDD_HOOK_WIRING_CEILING="$_saved_ceiling"

# 13b — WITH a ceiling set to $_encl (this fixture's own enclosing-repo boundary — the realistic
#      choice a suite makes: "don't look above my own sandbox"), the walk-up never scans $_encl at
#      all and correctly reports plain 'wired'. This is the actual fix under test.
export RSDD_HOOK_WIRING_CEILING="$_encl"
assert_state "13b ceiling set to the enclosing repo boundary → correctly 'wired', bleed-in blocked" "$d" "wired"
export RSDD_HOOK_WIRING_CEILING="$_saved_ceiling"

rm -rf "$_inner_root"
if [ "$_had_tmpdir" -eq 1 ]; then TMPDIR="$_old_tmpdir"; export TMPDIR; else unset TMPDIR; fi

# --- kit r3 review, M2: symlink handling (CORRECTED — 14a was mislabeled "intermediate
# component"; it is a LEAF symlink) --------------------------------------------------------------
# `[ -e ]` resolves a symlink AT the final path component at the kernel level, so a LEAF symlink
# pointing DIRECTLY at a git root resolves correctly on the FIRST check, before any climbing (14b).
# A leaf symlink pointing at a NESTED, non-root directory does NOT (14a): once the walk needs to
# climb past the leaf, it climbs the SYMLINK'S OWN textual path, not the resolved target's real
# ancestors, so it is a false negative (stays 'wired'), never a false positive. A genuinely
# INTERMEDIATE symlinked path component is a distinct, untested shape with the same root cause —
# see lib/hook-wiring.sh's own header on _hw_find_git_root.

# 14a — DOCUMENTED LIMITATION, pinned so a future change is deliberate, not silent: a LEAF symlink
#      pointing at a NESTED (non-root) real directory → stays 'wired' (a false negative — see lib
#      header), not a crash and not a false 'wired-off-root' WARN either way. If this pin ever
#      needs to flip to 'wired-off-root', that is a deliberate feature add (a fork-based
#      fallback), not a regression — update this test alongside it.
d_real_root="$ROOT/t14-real-repo"; mkdir -p "$d_real_root/real-nested"
git init -q "$d_real_root" >/dev/null 2>&1
wire_settings "$d_real_root/real-nested" '{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"/x/.claude/hooks/retro-gate-stop.sh"}]}]}}'
d_link="$ROOT/t14a-link-to-nested"
ln -s "$d_real_root/real-nested" "$d_link"
assert_state "14a DOCUMENTED LIMITATION: leaf symlink to a NESTED dir → stays 'wired' (false negative, not a crash or false WARN)" "$d_link" "wired"

# 14b — the LEAF case works correctly: a leaf symlink pointing DIRECTLY at a git root (settings.json
#      wired there) → stays 'wired', not off-root (this is the case `[ -e ]` resolves for free).
d_real_root2="$ROOT/t14b-real-root2"; mkdir -p "$d_real_root2"
git init -q "$d_real_root2" >/dev/null 2>&1
wire_settings "$d_real_root2" '{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"/x/.claude/hooks/retro-gate-stop.sh"}]}]}}'
d_link_root="$ROOT/t14b-link-to-root2"
ln -s "$d_real_root2" "$d_link_root"
assert_state "14b leaf symlink pointing directly AT a git root, wired → wired (not off-root)" "$d_link_root" "wired"

# --- 15a/15b/15c — RELATIVE-PATH INFINITE LOOP (RDD correction, kit issue #1140) ----------------
# A relative target ('.', 'foo', 'foo/bar' -> 'foo') gave ${d%/*} no "/" to climb past, so the
# walk-up spun forever — a real caller shape (e.g. research-sdd-status.sh invoked as '.'), not
# synthetic. Each case runs in a fresh subprocess under `timeout` so a regression fails loudly.
run_relative_case() {
  local label="$1" cwd="$2" target="$3" want="$4" out rc
  out="$(cd "$cwd" && timeout 10 "$BASH_BIN" -c ". \"$LIB\"; hook_stop_wiring_state \"$target\"" 2>&1)"
  rc=$?
  if [ "$rc" -eq 124 ]; then no "$label" "TIMED OUT (infinite loop) after 10s"
  elif [ "$rc" -eq 0 ] && [ "$out" = "$want" ]; then ok "$label" "-> $out"
  else no "$label" "rc=$rc out=[$out] want=[$want]"; fi
}
d15a="$ROOT/t15a-dot-selfroot"; mkdir -p "$d15a"; git init -q "$d15a" >/dev/null 2>&1
wire_settings "$d15a" '{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"retro-gate"}]}]}}'
run_relative_case "15a relative target '.' at its own git root → wired (no hang)" "$d15a" "." "wired"
mkdir -p "$ROOT/t15b-bare-norepo"
wire_settings "$ROOT/t15b-bare-norepo" '{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"retro-gate"}]}]}}'
run_relative_case "15b relative target (no slash), no ancestor .git under ceiling → wired (no hang)" "$ROOT" "t15b-bare-norepo" "wired"
d15c_root="$ROOT/t15c-repo"; mkdir -p "$d15c_root/nested"; git init -q "$d15c_root" >/dev/null 2>&1
wire_settings "$d15c_root/nested" '{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"retro-gate"}]}]}}'
run_relative_case "15c relative target 'nested' inside a repo → wired-off-root (no hang)" "$d15c_root" "nested" "wired-off-root"

# --- 16 — DOTDOT DISTRACTOR (kit r3 review, M1): a '..' component must be COLLAPSED before the
#      walk-up runs, not stripped one raw textual segment at a time. Target = ".../A/B/.." really
#      resolves to ".../A" (no .git of its own); ".../A/B" is an UNRELATED nested repo (B has its
#      own .git, A does not). Un-normalized, the walk-up's first miss at ".../A/B/../.git" climbs
#      by stripping the trailing '..' segment (not collapsing it), landing on the REAL directory
#      ".../A/B" and finding B's irrelevant .git there — a FALSE 'wired-off-root' for a target that
#      (correctly resolved) is not in any repo at all and should stay plain 'wired'.
d16_a="$ROOT/t16-dotdot/A"; d16_b="$d16_a/B"; mkdir -p "$d16_b"
wire_settings "$d16_a" '{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"/x/.claude/hooks/retro-gate-stop.sh"}]}]}}'
git init -q "$d16_b" >/dev/null 2>&1
assert_state "16 dotdot distractor: '.../A/B/..' resolves to A (no repo) → wired, B's nested .git ignored" "$d16_a/B/.." "wired"

# --- 17 — CEILING TRAILING SLASH (kit r3 review, M3): $RSDD_HOOK_WIRING_CEILING is compared
#      TEXTUALLY against the walk-up's (normalized, no trailing slash) $d, so the lib normalizes
#      the ceiling through _hw_abspath first. This case pins that: a ceiling with a trailing slash
#      still stops the walk-up, so the enclosing repo does not bleed in (case 13a's un-ceilinged
#      control shows what bleeding looks like). Reuses case 13's TMPDIR-inside-
#      a-repo fixture shape with a fresh enclosing dir so it cannot collide with case 13's cleanup.
_encl17="$ROOT/t17-enclosing"; mkdir -p "$_encl17"; git init -q "$_encl17" >/dev/null 2>&1
_old_tmpdir17="${TMPDIR:-}"; _had17=0; [ -n "${TMPDIR+x}" ] && _had17=1
TMPDIR="$_encl17"; export TMPDIR
_inner17="$(mktemp -d)"
d17="$_inner17/target"; mkdir -p "$d17"
wire_settings "$d17" '{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"/x/.claude/hooks/retro-gate-stop.sh"}]}]}}'
_saved_ceiling17="$RSDD_HOOK_WIRING_CEILING"
export RSDD_HOOK_WIRING_CEILING="$_encl17/"
assert_state "17 ceiling with a trailing slash still blocks the enclosing repo (not silently disabled)" "$d17" "wired"
export RSDD_HOOK_WIRING_CEILING="$_saved_ceiling17"
rm -rf "$_inner17"
if [ "$_had17" -eq 1 ]; then TMPDIR="$_old_tmpdir17"; export TMPDIR; else unset TMPDIR; fi

# --- 18 — SYMLINK BEFORE '..' (kit issue #1153 item 1) -------------------------------------------
# The kernel resolves '..' AFTER following a symlink, but the textual collapse in _hw_abspath does
# not: target ".../P/sub/link/.." (link -> Q/y/z) really names Q/y, a git root of its own and the
# directory holding the wired settings.json, yet collapses to ".../P/sub" inside enclosing repo P.
# That used to report a false 'wired-off-root'. The raw "$target/.git" check answers it first.
d18_p="$ROOT/t18-P"; d18_q="$ROOT/t18-Q"
mkdir -p "$d18_p/sub" "$d18_q/y/z"
git init -q "$d18_p" >/dev/null 2>&1; git init -q "$d18_q/y" >/dev/null 2>&1
ln -s "$d18_q/y/z" "$d18_p/sub/link"
wire_settings "$d18_q/y" '{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"retro-gate"}]}]}}'
assert_state "18 symlink-before-'..' resolving to a wired git root → wired (not a false off-root)" "$d18_p/sub/link/.." "wired"

# --- 19 — EMBEDDED NEWLINE (kit issue #1153 item 5): the path split used to be `read -ra` over a
#      here-string, which stops at the first newline and silently truncated the target. Target
#      ".../t19/a<NL>b" is a plain directory inside enclosing repo t19, so it is off-root. A
#      truncated ".../t19/a" is a different, sibling directory that is its own git root, so the old
#      split reported a false plain 'wired' (the raw-target check cannot rescue this shape: the
#      target itself owns no .git).
d19_p="$ROOT/t19"; d19="$d19_p/a"$'\n'"b"
mkdir -p "$d19" "$d19_p/a"; git init -q "$d19_p" >/dev/null 2>&1; git init -q "$d19_p/a" >/dev/null 2>&1
wire_settings "$d19" '{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"retro-gate"}]}]}}'
assert_state "19 embedded newline, nested in a repo → wired-off-root (path not truncated)" "$d19" "wired-off-root"

# --- 20 — NO HERE-STRING (kit issue #1153 item 2): on bash < 5.1 a here-string is backed by a
#      $TMPDIR temp file; if that cannot be created `read` fails, the array stays empty and the path
#      silently becomes '/'. The split must use parameter expansion only. Lint over executable
#      lines (comment lines excluded) of the lib.
# herestring_count FILE : sets HS_N to the number of here-strings on executable lines; rc 2 when
# FILE is unreadable or awk fails, so "0" never means "could not look" (no pipeline: one awk reads
# FILE directly and its own status is checked). Shared by case 20 and its tooth.
herestring_count() {
  HS_N=""
  [ -r "$1" ] || return 2
  HS_N="$(awk '!/^[[:space:]]*#/ && index($0, "<<<") { n++ } END { print n + 0 }' "$1")" || return 2
  return 0
}
# 20a — control: a missing path must be "could not look" (rc 2, empty count), never a clean 0.
herestring_count "$ROOT/no-such-file"; _hs_ctl_rc=$?
if [ "$_hs_ctl_rc" -eq 2 ] && [ -z "$HS_N" ]; then ok "20a here-string lint on a missing file → rc 2, no count (not a silent 0)"
else no "20a here-string lint on a missing file → rc 2, no count" "rc=$_hs_ctl_rc n=[$HS_N]"; fi
if ! herestring_count "$LIB"; then
  no "20 lib here-string lint could not run"
elif [ "$HS_N" -eq 0 ]; then
  ok "20 lib has no here-string on executable lines (no TMPDIR-backed split)"
else
  no "20 lib has no here-string on executable lines" "found $HS_N"
fi

# --- 21 — RAW-TARGET CHECK honors the ceiling (kit issue #1153, RDD review): same shape as case 18
#      (target ".../link/.." whose spelled form owns a .git), but the collapsed path IS the ceiling.
#      The ceiling must still win: HW_GIT_ROOT stays empty instead of echoing the collapsed path.
d21_p="$ROOT/t21-P"; d21_q="$ROOT/t21-Q"
mkdir -p "$d21_p/sub" "$d21_q/y/z"
git init -q "$d21_q/y" >/dev/null 2>&1
ln -s "$d21_q/y/z" "$d21_p/sub/link"
_saved_ceiling21="$RSDD_HOOK_WIRING_CEILING"
export RSDD_HOOK_WIRING_CEILING="$d21_p/sub"
_hw_find_git_root "$d21_p/sub/link/.."
_r21="$HW_GIT_ROOT"
export RSDD_HOOK_WIRING_CEILING="$_saved_ceiling21"
if [ -z "$_r21" ]; then ok "21 raw .git target whose collapsed path is the ceiling → ceiling wins (no root)"
else no "21 raw .git target whose collapsed path is the ceiling → ceiling wins (no root)" "HW_GIT_ROOT=[$_r21]"; fi

# --- 22 — HW_TARGET_IS_ROOT FLAG (kit issue #1696): in the RAW-TARGET branch HW_GIT_ROOT used to be
#      the textually collapsed target, which can name a directory with NO .git. It must now be a real
#      git-root path (here: the spelled target, which owns the .git) and the "target is its own root"
#      answer travels in HW_TARGET_IS_ROOT. The ordinary walk and the ceiling leave the flag 0.
d22_p="$ROOT/t22-P"; d22_q="$ROOT/t22-Q"
mkdir -p "$d22_p/sub" "$d22_q/y/z"
git init -q "$d22_p" >/dev/null 2>&1; git init -q "$d22_q/y" >/dev/null 2>&1
ln -s "$d22_q/y/z" "$d22_p/sub/link"
_hw_find_git_root "$d22_p/sub/link/.."
_r22="$HW_GIT_ROOT"; _f22="$HW_TARGET_IS_ROOT"
if [ "$_f22" = "1" ] && [ -e "$_r22/.git" ]; then ok "22a raw .git target → HW_TARGET_IS_ROOT=1 and HW_GIT_ROOT owns a .git"
else no "22a raw .git target → flag set, HW_GIT_ROOT is a real git root" "flag=[$_f22] root=[$_r22]"; fi
_hw_find_git_root "$d22_p/sub"
if [ "$HW_TARGET_IS_ROOT" = "0" ] && [ "$HW_GIT_ROOT" = "$d22_p" ]; then ok "22b ordinary walk → flag 0, root is the enclosing repo"
else no "22b ordinary walk → flag 0, root is the enclosing repo" "flag=[$HW_TARGET_IS_ROOT] root=[$HW_GIT_ROOT]"; fi
_saved_ceiling22="$RSDD_HOOK_WIRING_CEILING"
export RSDD_HOOK_WIRING_CEILING="$d22_p/sub"
_hw_find_git_root "$d22_p/sub/link/.."
export RSDD_HOOK_WIRING_CEILING="$_saved_ceiling22"
if [ "$HW_TARGET_IS_ROOT" = "0" ] && [ -z "$HW_GIT_ROOT" ]; then ok "22c ceiling wins → flag 0 and empty root"
else no "22c ceiling wins → flag 0 and empty root" "flag=[$HW_TARGET_IS_ROOT] root=[$HW_GIT_ROOT]"; fi

# --- 23 — the string comparison stays reachable (kit issue #1696): spelled target ".../link/.." has
#      no .git, but its collapsed path (the directory holding the link) is a git root equal to the
#      normalized target string → flag 0, root == collapsed → plain 'wired'.
d23_p="$ROOT/t23-P"; mkdir -p "$d23_p" "$ROOT/t23-Q/y/z"
git init -q "$d23_p" >/dev/null 2>&1
ln -s "$ROOT/t23-Q/y/z" "$d23_p/link"
wire_settings "$d23_p/link/.." '{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"retro-gate"}]}]}}'
assert_state "23 spelled target without .git, collapsed path is a git root → wired (flag 0, comparison equal)" "$d23_p/link/.." "wired"

# --- mutation teeth ("--prove-teeth") --------------------------------------------------------------
# Each mutant is a COPY of the real lib file with ONE line changed, sourced fresh in a subshell —
# never a hand-redefined function called directly (RDD finding, see header). Running the REAL
# hook_stop_wiring_state_var against the mutated COPY proves the SOURCED implementation reacts to
# a real code change, not that the test file's own inline stand-in behaves as scripted.
if [ "${1:-}" = "--prove-teeth" ]; then
  # Mutant builds go through lib/mutant.sh (kit issue #1299). Sourced only on this path. Each
  # mutant is built by mutant_chain, which refuses a dead sed stage, an empty/identical/unparseable
  # mutant and a mutant placed in the live tree; a refused build is counted ONCE here and its
  # observation never runs. The observations stay in-process (a mutated lib is sourced in a
  # subshell and its state variable read), so they are not expressible as mutant_tooth argv runs.
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  declare -F mutant_chain >/dev/null 2>&1 || { echo "FATAL: $HERE/lib/mutant.sh did not define mutant_chain" >&2; exit 2; }
  mk() { mutant_chain "$@" || { fail=$((fail+1)); return 1; }; }
  echo "-- teeth: force the awk always-found (END { exit 0 }) — case 3 must go RED --"
  mut_wired="$ROOT/hook-wiring.MUTANT-always-wired.sh"
  if mk "teeth: 'END { exit !found }' anchor in lib" "$LIB" "$mut_wired" 's/END { exit !found }/END { exit 0 }  # MUTANT: always found/'; then
    (
      # The outer script already sourced the REAL lib, so these names are already declared in
      # this subshell (subshells inherit the parent's functions). Unset first, or the mutant
      # lib's idempotency guard (`if ! declare -F ...`) sees them as already defined and skips
      # its own redefinition — the mutant would silently never take effect.
      unset -f hook_stop_wiring_state hook_stop_wiring_state_var _hw_find_git_root
      # shellcheck disable=SC1090
      . "$mut_wired"
      d="$ROOT/t3"
      r="$(hook_stop_wiring_state "$d")"
      if [ "$r" = "unwired" ]; then echo "  FAIL  teeth: mutant did not flip (theater)"; exit 1
      else echo "  PASS  teeth: mutant correctly breaks case 3 (unwired misreported as wired)"; exit 0; fi
    )
    if [ $? -eq 0 ]; then ok "teeth: always-found awk mutation caught (real sourced lib)"; else no "teeth: always-found awk mutation NOT caught (theater)"; fi
  fi

  echo "-- teeth: collapse absent-settings assignment into 'unwired' — case 1 must go RED --"
  mut_absent="$ROOT/hook-wiring.MUTANT-absent-collapse.sh"
  if mk "teeth: absent-settings assignment anchor in lib" "$LIB" "$mut_absent" 's/HOOK_WIRING_STATE="absent-settings"; return 0/HOOK_WIRING_STATE="unwired"; return 0  # MUTANT: collapsed/'; then
    (
      unset -f hook_stop_wiring_state hook_stop_wiring_state_var _hw_find_git_root
      # shellcheck disable=SC1090
      . "$mut_absent"
      d="$ROOT/t1"
      r="$(hook_stop_wiring_state "$d")"
      if [ "$r" = "absent-settings" ]; then echo "  FAIL  teeth: mutant did not flip (theater)"; exit 1
      else echo "  PASS  teeth: mutant correctly breaks case 1 (absent-settings collapsed into unwired)"; exit 0; fi
    )
    if [ $? -eq 0 ]; then ok "teeth: absent-settings/unwired collapse mutation caught (real sourced lib)"; else no "teeth: absent-settings/unwired collapse mutation NOT caught (theater)"; fi
  fi

  echo "-- teeth: force hook_stop_wiring_state_var (fork-free path) to always set 'wired' — case 6 must go RED --"
  mut_var="$ROOT/hook-wiring.MUTANT-var-always-wired.sh"
  if mk "teeth: unreadable assignment anchor in lib" "$LIB" "$mut_var" 's/HOOK_WIRING_STATE="unreadable"; return 0/HOOK_WIRING_STATE="wired"; return 0  # MUTANT: unreadable forced wired/'; then
    if [ "$(id -u)" != "0" ]; then
      # Fresh fixture — case 6's own $ROOT/t6 was already chmod-644-restored above for cleanup,
      # so reusing it here would silently test the awk path instead of the unreadable branch.
      d_t6b="$ROOT/t6b-teeth"; mkdir -p "$d_t6b"
      wire_settings "$d_t6b" '{"hooks":{"Stop":[]}}'
      chmod 000 "$d_t6b/.claude/settings.json"
      (
        unset -f hook_stop_wiring_state hook_stop_wiring_state_var _hw_find_git_root
        # shellcheck disable=SC1090
        . "$mut_var"
        d="$d_t6b"
        hook_stop_wiring_state_var "$d"
        if [ "$HOOK_WIRING_STATE" = "unreadable" ]; then echo "  FAIL  teeth: mutant did not flip (theater)"; exit 1
        else echo "  PASS  teeth: mutant correctly breaks case 6 via the fork-free entry point"; exit 0; fi
      )
      _t6b_rc=$?
      chmod 644 "$d_t6b/.claude/settings.json"   # restore so cleanup can remove it
      if [ "$_t6b_rc" -eq 0 ]; then ok "teeth: hook_stop_wiring_state_var unreadable mutation caught (real sourced lib)"; else no "teeth: hook_stop_wiring_state_var unreadable mutation NOT caught (theater)"; fi
    else
      echo "  SKIP  teeth: hook_stop_wiring_state_var unreadable mutation (running as root)"
    fi
  fi

  echo "-- teeth: neuter the wired-off-root downgrade assignment — case 9 must go RED (stays 'wired') --"
  mut_offroot_neuter="$ROOT/hook-wiring.MUTANT-offroot-neuter.sh"
  if mk "teeth: wired-off-root assignment anchor in lib" "$LIB" "$mut_offroot_neuter" 's/HOOK_WIRING_STATE="wired-off-root"/: # MUTANT: neutered/'; then
    (
      unset -f hook_stop_wiring_state hook_stop_wiring_state_var _hw_find_git_root
      # shellcheck disable=SC1090
      . "$mut_offroot_neuter"
      d_root="$ROOT/t9-teeth-neuter"; d="$d_root/nested"; mkdir -p "$d"
      git init -q "$d_root" >/dev/null 2>&1
      wire_settings "$d" '{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"/x/.claude/hooks/retro-gate-stop.sh"}]}]}}'
      r="$(hook_stop_wiring_state "$d")"
      if [ "$r" = "wired-off-root" ]; then echo "  FAIL  teeth: mutant did not flip (theater)"; exit 1
      else echo "  PASS  teeth: mutant correctly breaks case 9 (off-root false-reported as plain wired)"; exit 0; fi
    )
    if [ $? -eq 0 ]; then ok "teeth: wired-off-root downgrade-neuter mutation caught (real sourced lib)"; else no "teeth: wired-off-root downgrade-neuter mutation NOT caught (theater)"; fi
  fi

  echo "-- teeth: widen the git-root comparison to always-mismatch — case 23 must go RED (a collapsed-root-equals-target shape would be misreported off-root) --"
  mut_offroot_always="$ROOT/hook-wiring.MUTANT-offroot-always.sh"
  if mk "teeth: WIRED-OFF-ROOT-CHECK comparison anchor in lib" "$LIB" "$mut_offroot_always" 's/\[ -n "\$HW_GIT_ROOT" \] \&\& \[ "\$HW_GIT_ROOT" != "\$_hw_target_norm" \]; then  # WIRED-OFF-ROOT-CHECK/[ -n "$HW_GIT_ROOT" ]; then  # MUTANT: comparison dropped/'; then
    (
      unset -f hook_stop_wiring_state hook_stop_wiring_state_var _hw_find_git_root
      # shellcheck disable=SC1090
      . "$mut_offroot_always"
      # Since kit issue #1696 a target that owns a .git is answered by the flag, so the string
      # comparison is only reachable when the spelled target has NO .git while its collapsed path
      # does (case 23 shape): collapsed root == normalized target, so the baseline stays 'wired'.
      d_p="$ROOT/t8-teeth-always-P"; mkdir -p "$d_p" "$ROOT/t8-teeth-always-Q/y/z"
      git init -q "$d_p" >/dev/null 2>&1
      ln -s "$ROOT/t8-teeth-always-Q/y/z" "$d_p/link"
      d="$d_p/link/.."
      wire_settings "$d" '{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"/x/.claude/hooks/retro-gate-stop.sh"}]}]}}'
      r="$(hook_stop_wiring_state "$d")"
      if [ "$r" = "wired" ]; then echo "  FAIL  teeth: mutant did not flip (theater)"; exit 1
      else echo "  PASS  teeth: mutant correctly breaks case 23 (collapsed-root target misreported [$r])"; exit 0; fi
    )
    if [ $? -eq 0 ]; then ok "teeth: git-root comparison always-mismatch mutation caught (real sourced lib)"; else no "teeth: git-root comparison always-mismatch mutation NOT caught (theater)"; fi
  fi

  echo "-- teeth: drop the '[ -n \"\$HW_GIT_ROOT\" ]' guard — case 12 must go RED (a non-repo target would be misreported off-root) --"
  mut_hwg_guard="$ROOT/hook-wiring.MUTANT-hwgroot-null-guard.sh"
  if mk "teeth: WIRED-OFF-ROOT-CHECK null-guard anchor in lib" "$LIB" "$mut_hwg_guard" 's/\[ -n "\$HW_GIT_ROOT" \] \&\& \[ "\$HW_GIT_ROOT" != "\$_hw_target_norm" \]; then  # WIRED-OFF-ROOT-CHECK/[ "$HW_GIT_ROOT" != "$_hw_target_norm" ]; then  # MUTANT: null-guard dropped/'; then
    (
      unset -f hook_stop_wiring_state hook_stop_wiring_state_var _hw_find_git_root
      # shellcheck disable=SC1090
      . "$mut_hwg_guard"
      d="$ROOT/t12-teeth-nullguard"; mkdir -p "$d"
      wire_settings "$d" '{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"/x/.claude/hooks/retro-gate-stop.sh"}]}]}}'
      r="$(hook_stop_wiring_state "$d")"
      if [ "$r" = "wired" ]; then echo "  FAIL  teeth: mutant did not flip (theater)"; exit 1
      else echo "  PASS  teeth: mutant correctly breaks case 12 (non-repo target misreported [$r] — empty HW_GIT_ROOT != any target string)"; exit 0; fi
    )
    if [ $? -eq 0 ]; then ok "teeth: null-guard-dropped mutation caught (real sourced lib)"; else no "teeth: null-guard-dropped mutation NOT caught (theater)"; fi
  fi

  echo "-- teeth: neuter HOOK-WIRING-GITDIR-CHECK ('.git' existence test) — case 9 must go RED (off-root target never finds any git root) --"
  mut_gitdir="$ROOT/hook-wiring.MUTANT-gitdir-check.sh"
  if mk "teeth: HOOK-WIRING-GITDIR-CHECK anchor in lib" "$LIB" "$mut_gitdir" 's/if \[ -e "\$d\/\.git" \]; then  # HOOK-WIRING-GITDIR-CHECK/if false; then  # MUTANT: gitdir check neutered/'; then
    (
      unset -f hook_stop_wiring_state hook_stop_wiring_state_var _hw_find_git_root
      # shellcheck disable=SC1090
      . "$mut_gitdir"
      d_root="$ROOT/t9-teeth-gitdir"; d="$d_root/nested"; mkdir -p "$d"
      git init -q "$d_root" >/dev/null 2>&1
      wire_settings "$d" '{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"/x/.claude/hooks/retro-gate-stop.sh"}]}]}}'
      r="$(hook_stop_wiring_state "$d")"
      if [ "$r" = "wired-off-root" ]; then echo "  FAIL  teeth: mutant did not flip (theater)"; exit 1
      else echo "  PASS  teeth: mutant correctly breaks case 9 ('.git' never found, stays plain wired [$r])"; exit 0; fi
    )
    if [ $? -eq 0 ]; then ok "teeth: HOOK-WIRING-GITDIR-CHECK neuter mutation caught (real sourced lib)"; else no "teeth: HOOK-WIRING-GITDIR-CHECK neuter mutation NOT caught (theater)"; fi
  fi

  echo "-- teeth: neuter HOOK-WIRING-CEILING-CHECK — case 13b must go RED (ceiling no longer stops the walk-up before the enclosing repo) --"
  mut_ceiling="$ROOT/hook-wiring.MUTANT-ceiling-check.sh"
  if mk "teeth: HOOK-WIRING-CEILING-CHECK anchor in lib" "$LIB" "$mut_ceiling" 's/if \[ -n "\$ceiling" \] \&\& \[ "\$d" = "\$ceiling" \]; then  # HOOK-WIRING-CEILING-CHECK/if false; then  # MUTANT: ceiling check neutered/'; then
    (
      unset -f hook_stop_wiring_state hook_stop_wiring_state_var _hw_find_git_root
      # shellcheck disable=SC1090
      . "$mut_ceiling"
      _mc_encl="$ROOT/t13-teeth-enclosing"; mkdir -p "$_mc_encl"
      git init -q "$_mc_encl" >/dev/null 2>&1
      _mc_old_tmpdir="${TMPDIR:-}"; _mc_had=0; [ -n "${TMPDIR+x}" ] && _mc_had=1
      TMPDIR="$_mc_encl"; export TMPDIR
      _mc_inner="$(mktemp -d)"
      d="$_mc_inner/target"; mkdir -p "$d"
      wire_settings "$d" '{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"/x/.claude/hooks/retro-gate-stop.sh"}]}]}}'
      export RSDD_HOOK_WIRING_CEILING="$_mc_encl"
      r="$(hook_stop_wiring_state "$d")"
      rm -rf "$_mc_inner"
      if [ "$_mc_had" -eq 1 ]; then TMPDIR="$_mc_old_tmpdir"; export TMPDIR; else unset TMPDIR; fi
      if [ "$r" = "wired" ]; then echo "  FAIL  teeth: mutant did not flip (theater)"; exit 1
      else echo "  PASS  teeth: mutant correctly breaks case 13b (ceiling ignored, enclosing repo bleeds in again [$r])"; exit 0; fi
    )
    if [ $? -eq 0 ]; then ok "teeth: HOOK-WIRING-CEILING-CHECK neuter mutation caught (real sourced lib)"; else no "teeth: HOOK-WIRING-CEILING-CHECK neuter mutation NOT caught (theater)"; fi
  fi

  echo "-- teeth: drop the relative-path join '/' prefix AND the no-progress guard — case 15b must go RED (reproduces the original infinite loop) --"
  mut_relhang="$ROOT/hook-wiring.MUTANT-relpath-hang.sh"
  if mk "teeth: relative-path join-prefix + no-progress-guard" "$LIB" "$mut_relhang" \
      's/\*)    result="\$result\/\$part" ;;/*)    result="$part" ;;  # MUTANT: join no longer prefixes "\/"/' \
      's/if \[ "\$_hw_next" = "\$d" \]; then  # HOOK-WIRING-NOPROGRESS-GUARD.*/if false; then  # MUTANT: no-progress guard dropped/'; then
    d_relhang="$ROOT/t15b-teeth-norepo"; mkdir -p "$d_relhang"
    wire_settings "$d_relhang" '{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"retro-gate"}]}]}}'
    out_relhang="$(cd "$ROOT" && timeout 10 "$BASH_BIN" -c ". \"$mut_relhang\"; hook_stop_wiring_state \"t15b-teeth-norepo\"" 2>&1)"
    rc_relhang=$?
    if [ "$rc_relhang" -eq 124 ]; then
      ok "teeth: relative-path abspath+no-progress-guard mutation caught (real sourced lib, timed out as expected)"
    else
      no "teeth: relative-path abspath+no-progress-guard mutation NOT caught (theater)" "rc=$rc_relhang out=[$out_relhang]"
    fi
  fi

  echo "-- teeth: stop collapsing '..' (append it as a literal component instead) — case 16 must go RED --"
  mut_dotdot="$ROOT/hook-wiring.MUTANT-dotdot-nocollapse.sh"
  if mk "teeth: '..' collapse anchor in lib" "$LIB" "$mut_dotdot" 's/\.\.)   result="\${result%\/\*}" ;;/..)   result="$result\/.." ;;  # MUTANT: dotdot no longer collapsed/'; then
    (
      unset -f hook_stop_wiring_state hook_stop_wiring_state_var _hw_find_git_root _hw_abspath
      # shellcheck disable=SC1090
      . "$mut_dotdot"
      r="$(hook_stop_wiring_state "$d16_a/B/..")"
      if [ "$r" = "wired" ]; then echo "  FAIL  teeth: mutant did not flip (theater)"; exit 1
      else echo "  PASS  teeth: mutant correctly breaks case 16 (dotdot distractor misreported [$r])"; exit 0; fi
    )
    if [ $? -eq 0 ]; then ok "teeth: '..' no-collapse mutation caught (real sourced lib)"; else no "teeth: '..' no-collapse mutation NOT caught (theater)"; fi
  fi

  echo "-- teeth: compare the ceiling raw (skip its _hw_abspath normalization) — case 17 must go RED --"
  mut_ceilraw="$ROOT/hook-wiring.MUTANT-ceiling-raw.sh"
  if mk "teeth: ceiling-normalize anchor in lib" "$LIB" "$mut_ceilraw" 's/_hw_abspath "\$RSDD_HOOK_WIRING_CEILING"; ceiling="\$HW_ABS_PATH"/ceiling="$RSDD_HOOK_WIRING_CEILING"  # MUTANT: ceiling compared raw/'; then
    _encl_t="$ROOT/t17-teeth-enclosing"; mkdir -p "$_encl_t/nested"; git init -q "$_encl_t" >/dev/null 2>&1
    wire_settings "$_encl_t/nested" '{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"/x/.claude/hooks/retro-gate-stop.sh"}]}]}}'
    (
      unset -f hook_stop_wiring_state hook_stop_wiring_state_var _hw_find_git_root _hw_abspath
      # shellcheck disable=SC1090
      . "$mut_ceilraw"
      export RSDD_HOOK_WIRING_CEILING="$_encl_t/"
      r="$(hook_stop_wiring_state "$_encl_t/nested")"
      if [ "$r" = "wired" ]; then echo "  FAIL  teeth: mutant did not flip (theater)"; exit 1
      else echo "  PASS  teeth: mutant correctly breaks case 17 (trailing-slash ceiling silently disabled [$r])"; exit 0; fi
    )
    if [ $? -eq 0 ]; then ok "teeth: ceiling-raw-comparison mutation caught (real sourced lib)"; else no "teeth: ceiling-raw-comparison mutation NOT caught (theater)"; fi
  fi

  # tooth_state LABEL MUTANT EXPECT_NOT TARGET CASE-NOTE [CWD] : source the mutant lib in a clean
  # subshell and require the state NOT to be EXPECT_NOT (the good lib's answer) and not to be a
  # crash/empty string — a mutant that dies reads as empty, which is theater, not a bite.
  tooth_state() {
    local label="$1" mut="$2" not="$3" target="$4" note="$5" cwd="${6:-$ROOT}" r
    # shellcheck disable=SC1090
    r="$(cd "$cwd" && unset -f hook_stop_wiring_state hook_stop_wiring_state_var _hw_find_git_root _hw_abspath \
         && . "$mut" && hook_stop_wiring_state "$target" 2>&1)"
    case "$r" in
      wired|wired-off-root|unwired|absent-settings|unreadable)
        if [ "$r" != "$not" ]; then ok "teeth: $label caught (real sourced lib)" "$note -> $r"
        else no "teeth: $label NOT caught (theater)" "state still [$r]"; fi ;;
      *) no "teeth: $label produced a crash/unknown state, not a bite" "out=[$r]" ;;
    esac
  }

  echo "-- teeth: neuter HOOK-WIRING-RAWGIT-CHECK — case 18 must go RED (symlink-before-'..' false off-root returns) --"
  mut_rawgit="$ROOT/hook-wiring.MUTANT-rawgit-check.sh"
  if mk "teeth: HOOK-WIRING-RAWGIT-CHECK anchor in lib" "$LIB" "$mut_rawgit" 's/ \&\& \[ -e "\$_hw_raw\/\.git" \]; then  # HOOK-WIRING-RAWGIT-CHECK/ \&\& false; then  # MUTANT: raw check neutered/'; then
    tooth_state "raw-target .git check neutered" "$mut_rawgit" "wired" "$d18_p/sub/link/.." "case 18"
  fi

  echo "-- teeth: truncate the split at the first control char (newline) — case 19 must go RED --"
  mut_split_nl="$ROOT/hook-wiring.MUTANT-split-newline.sh"
  if mk "teeth: path-split anchor in lib" "$LIB" "$mut_split_nl" 's/local rest="\${d#\/}" last=0/local rest="${d#\/}" last=0; rest="${rest%%[[:cntrl:]]*}"  # MUTANT: truncate at newline/'; then
    tooth_state "newline-truncating split" "$mut_split_nl" "wired-off-root" "$d19" "case 19"
  fi

  echo "-- teeth: reintroduce a here-string on an executable line — case 20 lint must go RED --"
  mut_herestr="$ROOT/hook-wiring.MUTANT-herestring.sh"
  if mk "teeth: path-split anchor in lib (here-string)" "$LIB" "$mut_herestr" 's/local rest="\${d#\/}" last=0/local rest="${d#\/}" last=0; : <<< "$d"  # MUTANT: here-string/'; then
    if herestring_count "$mut_herestr" && [ "$HS_N" -ne 0 ]; then
      ok "teeth: here-string lint bites on a mutant carrying one (real sourced lib)" "found $HS_N"
    else
      no "teeth: here-string lint did NOT bite on a here-string mutant (theater)" "n=[${HS_N:-}]"
    fi
  fi

  echo "-- teeth: drop the ceiling clause from HOOK-WIRING-RAWGIT-CHECK — case 21 must go RED --"
  mut_rawceil="$ROOT/hook-wiring.MUTANT-rawgit-ceiling.sh"
  if mk "teeth: RAWGIT ceiling-clause anchor in lib" "$LIB" "$mut_rawceil" 's/if { \[ -z "\$ceiling" \] || \[ "\$d" != "\$ceiling" \]; } \&\& \[ -e/if [ -e/'; then
    r21m="$(
      unset -f hook_stop_wiring_state hook_stop_wiring_state_var _hw_find_git_root _hw_abspath
      # shellcheck disable=SC1090
      . "$mut_rawceil"
      export RSDD_HOOK_WIRING_CEILING="$d21_p/sub"
      _hw_find_git_root "$d21_p/sub/link/.." 2>&1; printf 'ROOT=[%s]' "$HW_GIT_ROOT"
    )"
    case "$r21m" in
      'ROOT=[]') no "teeth: RAWGIT ceiling-clause mutation NOT caught (theater)" "$r21m" ;;
      'ROOT=['*']') ok "teeth: RAWGIT ceiling-clause mutation caught (real sourced lib)" "$r21m" ;;
      *) no "teeth: RAWGIT ceiling mutant crashed, not a bite" "$r21m" ;;
    esac
  fi

  echo "-- teeth: drop the HW_TARGET_IS_ROOT flag from WIRED-OFF-ROOT-CHECK — case 18 must go RED (false off-root returns) --"
  mut_flagdrop="$ROOT/hook-wiring.MUTANT-flag-drop.sh"
  if mk "teeth: WIRED-OFF-ROOT-CHECK flag anchor in lib" "$LIB" "$mut_flagdrop" 's/\[ "\$HW_TARGET_IS_ROOT" != "1" \] \&\& \[ -n "\$HW_GIT_ROOT" \]/[ -n "$HW_GIT_ROOT" ]/'; then
    tooth_state "target-is-root flag ignored" "$mut_flagdrop" "wired" "$d18_p/sub/link/.." "case 18"
  fi

  echo "-- teeth: return the collapsed path as HW_GIT_ROOT in the raw branch — case 22a must go RED --"
  mut_rawcollapsed="$ROOT/hook-wiring.MUTANT-raw-collapsed-root.sh"
  if mk "teeth: raw-branch HW_GIT_ROOT anchor in lib" "$LIB" "$mut_rawcollapsed" 's/      HW_GIT_ROOT="\$_hw_raw"/      HW_GIT_ROOT="$d"  # MUTANT: collapsed path as root/'; then
    r22m="$(
      unset -f hook_stop_wiring_state hook_stop_wiring_state_var _hw_find_git_root _hw_abspath
      # shellcheck disable=SC1090
      . "$mut_rawcollapsed"
      _hw_find_git_root "$d22_p/sub/link/.." 2>&1; if [ -e "$HW_GIT_ROOT/.git" ]; then printf 'REAL'; else printf 'FAKE[%s]' "$HW_GIT_ROOT"; fi
    )"
    case "$r22m" in
      REAL) no "teeth: collapsed-path-as-root mutation NOT caught (theater)" "$r22m" ;;
      FAKE*) ok "teeth: collapsed-path-as-root mutation caught (real sourced lib)" "$r22m" ;;
      *) no "teeth: collapsed-root mutant crashed, not a bite" "$r22m" ;;
    esac
  fi

  echo "-- teeth: stop absolutizing a relative target (drop the \$PWD prefix) — case 15c must go RED --"
  mut_absolut="$ROOT/hook-wiring.MUTANT-no-absolutize.sh"
  if mk "teeth: absolutize anchor in lib" "$LIB" "$mut_absolut" 's/\*)  d="\$PWD\/\$d" ;;/*)  : ;;  # MUTANT: relative target left relative/'; then
    tooth_state "relative-target absolutize dropped" "$mut_absolut" "wired-off-root" "nested" "case 15c" "$d15c_root"
  fi
fi

echo ""
printf '== %d passed · %d failed ==\n' "$pass" "$fail"

[ "$fail" -eq 0 ] && exit 0 || exit 1
