#!/usr/bin/env bash
# checkout-freshness.sh — shared helper: how far behind its origin ref is the kit checkout? (kit issue #2215)
#
# WHY: the kit a SessionStart hook runs from is a mutable shared checkout that silently falls behind origin/main
# (it is deliberately not auto-updated while research sessions run). Every kit-content WARN the other hooks print
# (tool catalog, registry, install --verify drift) can then be an ARTIFACT of the stale tree, not a finding
# (2026-10-11: 8 "installed-but-not-cataloged" tools and install drift vanished after a pull of 153 commits).
# This helper measures staleness so the FIRST hook can say so before any of those WARNs are read.
#
#   rsdd_checkout_freshness DIR [MAX_COMMITS]
#     Prints exactly ONE record line on stdout and returns 0. Three typed states (CLAUDE.md §7):
#       state=ok       behind=N ref=R age=Dd   behind is <= MAX_COMMITS (default 20; N may be > 0)
#       state=stale    behind=N ref=R age=Dd   behind is > MAX_COMMITS
#       state=degraded reason=<text>           NOT measurable: no git, no timeout binary, not a git checkout,
#                                              unrelated repo, no upstream / origin ref, git stalled or failed.
#                                              A degraded record is never "fresh"; callers decide how loud to be.
#     age is the days since the last fetch (FETCH_HEAD mtime), or `?` when the checkout never fetched.
#     LOCAL refs only: it never fetches, so the count may understate. All git work runs in ONE child under
#     `timeout 3`, so a stalled git cannot hold a session start. Read-only.
#
# Idempotent: safe to source more than once.
_RSDD_CF_LIB="${BASH_SOURCE[0]}"

# _rsdd_cf_measure DIR MAX — runs in the bounded child; prints the record line.
_rsdd_cf_measure() {
  local kdir="$1" kmax="$2" top kd t ref n fh ft now age="?"
  command -v git >/dev/null 2>&1 || { echo "state=degraded reason=git not found"; return 0; }
  top="$(git -C "$kdir" rev-parse --show-toplevel 2>/dev/null)" || top=""
  [ -n "$top" ] || { echo "state=degraded reason=not a git checkout (tarball install?)"; return 0; }
  kd="$(cd -P "$kdir" 2>/dev/null && pwd -P)"; t="$(cd -P "$top" 2>/dev/null && pwd -P)"
  if [ -z "$kd" ] || [ -z "$t" ] || { [ "$t" != "$kd" ] && [ "$t" != "$(dirname "$kd")" ]; }; then
    echo "state=degraded reason=kit dir sits inside an unrelated repo"; return 0
  fi
  if ref="$(git -C "$kd" rev-parse --abbrev-ref '@{upstream}' 2>/dev/null)" && [ -n "$ref" ]; then :
  elif git -C "$kd" rev-parse --verify --quiet refs/remotes/origin/main >/dev/null 2>&1; then ref="origin/main"
  else echo "state=degraded reason=no upstream ref (no @{upstream}, no origin/main)"; return 0; fi
  if ! n="$(git -C "$kd" rev-list --count "HEAD..$ref" 2>/dev/null)" || ! [[ "$n" =~ ^[0-9]+$ ]]; then
    echo "state=degraded reason=could not count commits behind $ref"; return 0
  fi
  if fh="$(git -C "$kd" rev-parse --git-path FETCH_HEAD 2>/dev/null)" && [ -n "$fh" ]; then
    case "$fh" in /*) ;; *) fh="$kd/$fh" ;; esac
    ft=""; [ ! -f "$fh" ] || ft="$(stat -c %Y "$fh" 2>/dev/null || stat -f %m "$fh" 2>/dev/null)"
    now="$(date +%s 2>/dev/null)"
    if [[ "$ft" =~ ^[0-9]+$ ]] && [[ "$now" =~ ^[0-9]+$ ]]; then age=$(( (now - ft) / 86400 )); [ "$age" -ge 0 ] || age=0; fi
  fi
  if [ "$n" -gt "$kmax" ]; then echo "state=stale behind=$n ref=$ref age=${age}d"   # SENTINEL-CF-STALE
  else echo "state=ok behind=$n ref=$ref age=${age}d"; fi
  return 0
}

if ! declare -F rsdd_checkout_freshness >/dev/null 2>&1; then
  rsdd_checkout_freshness() {
    local kdir="${1:-}" kmax="${2:-20}" rec
    [[ "$kmax" =~ ^[0-9]{1,6}$ ]] || kmax=20
    if [ -z "$kdir" ] || [ ! -d "$kdir" ]; then echo "state=degraded reason=kit dir absent"; return 0; fi
    if [ -n "${RESEARCH_SDD_NO_TIMEOUT_BIN:-}" ] || ! command -v timeout >/dev/null 2>&1; then
      echo "state=degraded reason=no timeout binary: git calls would be unbounded"; return 0
    fi
    rec="$(timeout 3 bash -c '. "$1"; _rsdd_cf_measure "$2" "$3"' _ "$_RSDD_CF_LIB" "$kdir" "$kmax" 2>/dev/null)" || rec=""
    case "$rec" in
      state=*) printf '%s\n' "${rec%%$'\n'*}" ;;
      *) echo "state=degraded reason=measurement timed out or failed (3s bound)" ;;
    esac
    return 0
  }
fi
