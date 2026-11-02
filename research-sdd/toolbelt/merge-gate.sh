#!/usr/bin/env bash
# Ported to Go: `rsdd gate merge`. Compatibility shim (removed in phase 8, kit issue #2434).
# The pre-merge check of kit issue #1272: never merge a review-due candidate before its review. The contract
# (flags, typed `merge-gate: ...` stdout lines, exit codes 0 allow/merged, 1 refuse, 2 usage, 3 degraded) is
# documented on gate.RunMerge (research-sdd/rsdd/internal/gate/merge.go); the frozen bash original is kept as the
# differential oracle under research-sdd/rsdd/internal/gate/testdata/legacy/.
# RSDD-SELF-DIR (kit #1675): own directory from BASH_SOURCE with symlinks followed - never $0 or the caller's cwd.
_rsdd_s="${BASH_SOURCE[0]}"; _rsdd_n=0
while [ -L "$_rsdd_s" ] && [ "$_rsdd_n" -lt 40 ]; do _rsdd_n=$((_rsdd_n + 1)); _rsdd_t="$(readlink -- "$_rsdd_s")" || break; case "$_rsdd_t" in /*) _rsdd_s="$_rsdd_t" ;; *) _rsdd_s="$(dirname -- "$_rsdd_s")/$_rsdd_t" ;; esac; done
if [ -L "$_rsdd_s" ]; then echo "${0##*/}: degraded: self-dir symlink resolution incomplete (hop limit or readlink failure) at $_rsdd_s" >&2; fi
_RSDD_SELF="$(CDPATH='' cd -- "$(dirname -- "$_rsdd_s")" && pwd -P)"; unset _rsdd_s _rsdd_n _rsdd_t
. "$_RSDD_SELF/lib/rsdd-exec.sh" 2>/dev/null || { printf 'degraded: rsdd-unavailable — rsdd-exec.sh missing beside %s\n' "$0" >&2; exit 2; }   # SENTINEL-RSDD-EXEC-GUARD
rsdd_exec gate merge "$@"
