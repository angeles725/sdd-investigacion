#!/usr/bin/env bash
# Ported to Go: `rsdd budget session`. Compatibility shim (removed in phase 8, kit issue #2270; ported in #2364).
# Usage: verify-session-budget.sh [--harness claude|pi|both] <target-dir>   (kit issues #2129, #2174)
# Measures what a target's SessionStart hooks (Claude Code) or pi extensions hand to the model, per source, against the
# 10,000-char per-field cap and the < 8,000-char budget; hooks run in a bubblewrap sandbox, never against the live tree.
# Exit: 0 always for findings and typed degraded states · 2 usage error. The pi helper lib/session-budget-pi.mjs stays
# JavaScript (it loads TypeScript extensions through node): the binary cannot see this file's directory, so the shim
# passes it with --toolbelt. Differences from the bash original: the package doc of research-sdd/rsdd/internal/budget.
# RSDD-SELF-DIR (kit #1675): own directory from BASH_SOURCE with symlinks followed - never $0 or the caller's cwd.
_rsdd_s="${BASH_SOURCE[0]}"; _rsdd_n=0
while [ -L "$_rsdd_s" ] && [ "$_rsdd_n" -lt 40 ]; do _rsdd_n=$((_rsdd_n + 1)); _rsdd_t="$(readlink -- "$_rsdd_s")" || break; case "$_rsdd_t" in /*) _rsdd_s="$_rsdd_t" ;; *) _rsdd_s="$(dirname -- "$_rsdd_s")/$_rsdd_t" ;; esac; done
if [ -L "$_rsdd_s" ]; then echo "${0##*/}: degraded: self-dir symlink resolution incomplete (hop limit or readlink failure) at $_rsdd_s" >&2; fi
_RSDD_SELF="$(CDPATH='' cd -- "$(dirname -- "$_rsdd_s")" && pwd -P)"; unset _rsdd_s _rsdd_n _rsdd_t
. "$_RSDD_SELF/lib/rsdd-exec.sh" 2>/dev/null || { printf 'degraded: rsdd-unavailable — rsdd-exec.sh missing beside %s\n' "$0" >&2; exit 2; }   # SENTINEL-RSDD-EXEC-GUARD
rsdd_exec budget session --toolbelt "$_RSDD_SELF" "$@"
