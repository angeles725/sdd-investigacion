#!/usr/bin/env bash
# Ported to Go: `rsdd budget verify`. Compatibility shim (removed in phase 8, kit issue #2270; ported in #2446).
# Usage: verify-session-budget.sh [--harness claude|pi|both] <target-dir>
# Measures what a target's SessionStart hooks (or, with --harness pi, its pi extensions) hand to the model, in decoded
# characters, against the 8,000-character kit budget. Exit: 0 always for findings and degraded states (WARN-only) · 2 usage error.
# The reference documentation (matcher rule, typed states, sandbox, env RSDD_BUDGET_*) is the doc comment of Run in
# rsdd/internal/budget/verify.go. The shim passes its own directory because the binary cannot see this file's location: the pi
# harness finds lib/session-budget-pi.mjs (Node, unchanged) beside it.
# RSDD-SELF-DIR (kit #1675): own directory from BASH_SOURCE with symlinks followed - never $0 or the caller's cwd.
_rsdd_s="${BASH_SOURCE[0]}"; _rsdd_n=0
while [ -L "$_rsdd_s" ] && [ "$_rsdd_n" -lt 40 ]; do _rsdd_n=$((_rsdd_n + 1)); _rsdd_t="$(readlink -- "$_rsdd_s")" || break; case "$_rsdd_t" in /*) _rsdd_s="$_rsdd_t" ;; *) _rsdd_s="$(dirname -- "$_rsdd_s")/$_rsdd_t" ;; esac; done
if [ -L "$_rsdd_s" ]; then echo "${0##*/}: degraded: self-dir symlink resolution incomplete (hop limit or readlink failure) at $_rsdd_s" >&2; fi
_RSDD_SELF="$(CDPATH='' cd -- "$(dirname -- "$_rsdd_s")" && pwd -P)"; unset _rsdd_s _rsdd_n _rsdd_t
. "$_RSDD_SELF/lib/rsdd-exec.sh" 2>/dev/null || { printf 'degraded: rsdd-unavailable — rsdd-exec.sh missing beside %s\n' "$0" >&2; exit 2; }   # SENTINEL-RSDD-EXEC-GUARD
rsdd_exec budget verify --toolbelt "$_RSDD_SELF" "$@"
