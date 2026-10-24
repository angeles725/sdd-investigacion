#!/usr/bin/env bash
# kit-resolve.test.sh — RED-first harness for kit-resolve.sh (kit issue #2334).
#
# Every case builds its own scratch world under the suite's temp dir: a bare origin, a pusher clone that
# advances it, and a HOME whose investigacion/sdd-investigacion is the "default checkout" (or a separate
# clone named by $RESEARCH_SDD_KIT). The real ~/investigacion/sdd-investigacion is never touched: HOME is
# always the scratch one and RESEARCH_SDD_KIT is always set or removed explicitly.
#   refresh      behind+clean -> fast-forwarded, `refreshed <old>→<new>`, KIT line with the new sha
#   current      at origin/main -> KIT line, no refresh; a SIBLING worktree is allowed
#   tracked      a tracked change -> refused dirty, not refreshed; untracked-only -> allowed and refreshed;
#                an untracked path the fast-forward would overwrite -> refused (refresh failed)
#   history      ahead -> refused ahead; diverged -> refused diverged (HEAD untouched)
#   placement    not on main / detached -> refused; a worktree registered inside the checkout -> refused
#   offline      unreachable origin -> refused; --offline-ok -> WARN + "unfetched", nothing refreshed
#   env          $RESEARCH_SDD_KIT valid -> its KIT line; no marker -> exit 3; stale -> refused, never touched
#   cli          -h prints the header; an unknown flag, or no candidate at all -> exit 3; not git -> refused
#
# Usage: kit-resolve.test.sh      env KIT_RESOLVE_SUT=<path> runs the cases against another script
# Exit: 0 all held · 1 regression · 2 harness error
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"  # LINT-CD-PHYSICAL-OK: test driver locating its SUT; run from the kit checkout by path
SUT="${KIT_RESOLVE_SUT:-$HERE/../kit-resolve.sh}"
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
command -v git >/dev/null 2>&1 || { echo "FATAL: git not installed" >&2; exit 2; }
# shellcheck source=lib/mutant.sh
. "$HERE/lib/mutant.sh" || exit 2
mutant_bootstrap mutant_cleanup_register || exit 2

T="$(mktemp -d "${TMPDIR:-/tmp}/kit-resolve-test.XXXXXX")" || exit 2
mutant_cleanup_register "$T" || exit 2
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE

pass=0; fail=0
ok() { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
no() { printf '  FAIL  %s\n' "$1"; fail=$((fail + 1)); }
echo "== kit-resolve.test.sh =="

# ---- fixtures -----------------------------------------------------------------------------------------
# world — a fresh scratch dir W with W/origin.git (one commit holding research-sdd/METHODOLOGY.md), the
# pusher clone W/up and an empty HOME W/home. Sets W, H (home) and D (the default checkout's git top).
n_world=0
world() {
  n_world=$((n_world + 1)); W="$T/w$n_world"; H="$W/home"; D="$H/investigacion/sdd-investigacion"
  mkdir -p "$H" && git init -q --bare -b main "$W/origin.git" && git init -q -b main "$W/up" || return 1
  mkdir -p "$W/up/research-sdd" && echo m > "$W/up/research-sdd/METHODOLOGY.md" && echo a > "$W/up/f.txt"
  git -C "$W/up" add -A && git -C "$W/up" commit -q -m init \
    && git -C "$W/up" remote add origin "$W/origin.git" && git -C "$W/up" push -q origin main
}
clone_to() { git clone -q "$W/origin.git" "$1"; }                       # clone_to DIR
advance() {                                                            # advance [FILE] — one new origin commit
  echo "$RANDOM" >> "$W/up/${1:-f.txt}" && git -C "$W/up" add -A && git -C "$W/up" commit -q -m adv \
    && git -C "$W/up" push -q origin main
}
local_commit() { echo l >> "$1/f.txt" && git -C "$1" commit -q -am local; }   # local_commit DIR
sha() { git -C "$1" rev-parse --short "${2:-HEAD}"; }

# run SUT [ARGS...] — runs with HOME=$H and RESEARCH_SDD_KIT=$KITENV (removed when KITENV is empty);
# sets OUT (stdout), ERR (stderr) and RC.
KITENV=""
run() {
  local s="$1"; shift
  env -u RESEARCH_SDD_KIT ${KITENV:+"RESEARCH_SDD_KIT=$KITENV"} HOME="$H" bash "$s" "$@" >"$T/out" 2>"$T/err"
  RC=$?; OUT="$(cat "$T/out")"; ERR="$(cat "$T/err")"
}
# why TEXT — records why the current case did not hold (printed by chk), returns 1
why() { WHY="$1 :: rc=$RC out=[$OUT] err=[$ERR]"; return 1; }
# kitline KIT SHA [FRESH] — OUT must be exactly one line, the contract line
kitline() { [ "$OUT" = "KIT=$1 SHA=$2 (${3:-origin/main}, clean)" ]; }

# ---- cases: each takes the SUT path and returns 0 when the behaviour holds ----------------------------
c_refresh() {
  world && clone_to "$D" && advance || return 2
  local old new; old="$(sha "$D")"; new="$(sha "$W/up")"; run "$1"
  [ "$RC" = 0 ] && [ "$(sha "$D")" = "$new" ] && kitline "$D/research-sdd" "$new" \
    && grep -qF "kit-resolve: refreshed $old→$new" <<<"$ERR" || why "behind+clean not refreshed"
}
c_current() {
  world && clone_to "$D" && git -C "$D" worktree add -q "$W/sibling" -b side || return 2
  run "$1"
  [ "$RC" = 0 ] && kitline "$D/research-sdd" "$(sha "$D")" && ! grep -q refreshed <<<"$ERR" \
    || why "current checkout (sibling worktree) not resolved cleanly"
}
c_dirty() {
  world && clone_to "$D" && advance g.txt && echo x >> "$D/f.txt" || return 2
  local old; old="$(sha "$D")"; run "$1"
  [ "$RC" = 2 ] && grep -q 'REFUSED dirty' <<<"$ERR" && [ "$(sha "$D")" = "$old" ] && [ -z "$OUT" ] \
    || why "tracked change not refused"
}
c_untracked() {
  world && clone_to "$D" && advance && echo u > "$D/scratch.txt" || return 2
  local new; new="$(sha "$W/up")"; run "$1"
  [ "$RC" = 0 ] && kitline "$D/research-sdd" "$new" && grep -q refreshed <<<"$ERR" \
    || why "untracked-only checkout not refreshed"
}
c_collide() {
  world && clone_to "$D" && advance new.txt && echo mine > "$D/new.txt" || return 2
  local old; old="$(sha "$D")"; run "$1"
  [ "$RC" = 2 ] && grep -q 'REFUSED refresh failed' <<<"$ERR" && [ "$(sha "$D")" = "$old" ] \
    && [ "$(cat "$D/new.txt")" = mine ] || why "ff over an untracked path not refused"
}
c_ahead() {
  world && clone_to "$D" && local_commit "$D" || return 2
  run "$1"
  [ "$RC" = 2 ] && grep -q 'REFUSED ahead' <<<"$ERR" || why "ahead not refused"
}
c_diverged() {
  world && clone_to "$D" && local_commit "$D" && advance g.txt || return 2
  local old; old="$(sha "$D")"; run "$1"
  [ "$RC" = 2 ] && grep -q 'REFUSED diverged' <<<"$ERR" && [ "$(sha "$D")" = "$old" ] \
    || why "diverged not refused"
}
c_branch() {
  world && clone_to "$D" && git -C "$D" switch -q -c topic || return 2
  run "$1"
  [ "$RC" = 2 ] && grep -q 'REFUSED not on main: .* is on topic' <<<"$ERR" || why "topic branch not refused"
}
c_detached() {
  world && clone_to "$D" && git -C "$D" switch -q --detach || return 2
  run "$1"
  [ "$RC" = 2 ] && grep -q 'REFUSED not on main: .* is on (detached at' <<<"$ERR" || why "detached HEAD not refused"
}
c_nested() {
  world && clone_to "$D" && git -C "$D" worktree add -q "$D/research-sdd-worktrees/x" -b x || return 2
  run "$1"
  [ "$RC" = 2 ] && grep -q "REFUSED nested worktree: $D/research-sdd-worktrees/x .*worktree move" <<<"$ERR" \
    || why "nested worktree not refused"
}
c_offline() {
  world && clone_to "$D" && git -C "$D" remote set-url origin "$W/gone.git" || return 2
  run "$1"
  [ "$RC" = 2 ] && grep -q 'REFUSED offline' <<<"$ERR" && [ -z "$OUT" ] || why "unreachable origin not refused"
}
c_offline_ok() {
  world && clone_to "$D" && git -C "$D" remote set-url origin "$W/gone.git" || return 2
  run "$1" --offline-ok
  [ "$RC" = 0 ] && kitline "$D/research-sdd" "$(sha "$D")" "origin/main unfetched" && grep -q 'WARN offline' <<<"$ERR" \
    || why "--offline-ok did not accept the local origin/main"
}
c_env_valid() {
  world && clone_to "$W/envkit" || return 2
  KITENV="$W/envkit/research-sdd"; run "$1"; KITENV=""
  [ "$RC" = 0 ] && kitline "$W/envkit/research-sdd" "$(sha "$W/envkit")" || why "valid RESEARCH_SDD_KIT not resolved"
}
c_env_marker() {
  world && mkdir -p "$W/nomarker" || return 2
  KITENV="$W/nomarker"; run "$1"; KITENV=""
  [ "$RC" = 3 ] && grep -q 'has no METHODOLOGY.md' <<<"$ERR" || why "RESEARCH_SDD_KIT without marker not exit 3"
}
c_env_stale() {
  world && clone_to "$W/envkit" && advance || return 2
  local old; old="$(sha "$W/envkit")"
  KITENV="$W/envkit/research-sdd"; run "$1"; KITENV=""
  [ "$RC" = 2 ] && grep -q 'REFUSED stale: .* 1 commit(s) behind' <<<"$ERR" && [ "$(sha "$W/envkit")" = "$old" ] \
    || why "stale RESEARCH_SDD_KIT refused or touched wrongly"
}
c_help() {
  world || return 2
  run "$1" -h
  [ "$RC" = 0 ] && grep -q '^Usage:' <<<"$OUT" && grep -q 'kit-resolve.sh \[--offline-ok\]' <<<"$OUT" || why "-h header"
}
c_badflag() { world || return 2; run "$1" --bogus; [ "$RC" = 3 ] && grep -q '^usage:' <<<"$ERR" || why "unknown flag"; }
c_nocand() { world || return 2; run "$1"; [ "$RC" = 3 ] && grep -q 'no kit found' <<<"$ERR" || why "no candidate"; }
c_notgit() {
  world && mkdir -p "$W/plain" && echo m > "$W/plain/METHODOLOGY.md" || return 2
  KITENV="$W/plain"; run "$1"; KITENV=""
  [ "$RC" = 2 ] && grep -q 'REFUSED untracked: .* not in a git work tree' <<<"$ERR" || why "non-git kit not refused"
}

CASES=(c_refresh c_current c_dirty c_untracked c_collide c_ahead c_diverged c_branch c_detached c_nested
       c_offline c_offline_ok c_env_valid c_env_marker c_env_stale c_help c_badflag c_nocand c_notgit)
for c in "${CASES[@]}"; do
  WHY=""; "$c" "$SUT"; r=$?
  case "$r" in
    0) ok "$c" ;;
    2) no "$c: fixture setup failed" ;;
    *) no "$c: $WHY" ;;
  esac
done

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
