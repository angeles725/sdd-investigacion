#!/usr/bin/env bash
# Ported to Go: `rsdd verify gap-drift`. Compatibility shim (removed in phase 8, kit issue #2270; ported in #2645).
# check-gap-drift.sh — flag RESEARCH-STATE backlog rows whose text drifted from the child-gap bullet that defines them
# (kit issues #1291, #1294; ported from niagara5-research tools/check-gap-drift.py).
# Usage: check-gap-drift.sh <target-dir> [--state <file>] [--threshold <pct>] [--all]
# Exit: 0 = no drift suspected · 1 = drift or unparsed rows (findings ONLY) · 2 = every operational failure (usage,
#       unreadable input).
# A backlog row `| <priority> | B<n>-G<m> <text> | ... | <status> |` is a promoted COPY of the bullet
# `- **B<n>-G<m>** <text>` in block <n>'s child-gaps list; a row sharing fewer than THRESHOLD percent (default 20) of its
# content words with that bullet is suspected drift. The report (DRIFT? / NO-BULLET / NO-BLOCK / NO-WORDS / UNPARSED
# lines, the typed not-applicable / no-pending / DEGRADED message and the checked=N summary) is produced by the binary,
# byte for byte as this script printed it, except for the differences listed in
# research-sdd/toolbelt/tool-registry.d/check-gap-drift.md and the package doc of research-sdd/rsdd/internal/verify/gapdrift.
# Known limit: the overlap measure sees only words that start with a letter (>= 3 chars); a row that changes only a
# number or an id is NOT detected. Read-only: never edits a corpus (propose-never-apply).
# RSDD-SELF-DIR (kit #1675): own directory from BASH_SOURCE with symlinks followed - never $0 or the caller's cwd.
_rsdd_s="${BASH_SOURCE[0]}"; _rsdd_n=0
while [ -L "$_rsdd_s" ] && [ "$_rsdd_n" -lt 40 ]; do _rsdd_n=$((_rsdd_n + 1)); _rsdd_t="$(readlink -- "$_rsdd_s")" || break; case "$_rsdd_t" in /*) _rsdd_s="$_rsdd_t" ;; *) _rsdd_s="$(dirname -- "$_rsdd_s")/$_rsdd_t" ;; esac; done
if [ -L "$_rsdd_s" ]; then echo "${0##*/}: degraded: self-dir symlink resolution incomplete (hop limit or readlink failure) at $_rsdd_s" >&2; fi
_RSDD_SELF="$(CDPATH='' cd -- "$(dirname -- "$_rsdd_s")" && pwd -P)"; unset _rsdd_s _rsdd_n _rsdd_t
. "$_RSDD_SELF/lib/rsdd-exec.sh" 2>/dev/null || { printf 'degraded: rsdd-unavailable — rsdd-exec.sh missing beside %s\n' "$0" >&2; exit 2; }   # SENTINEL-RSDD-EXEC-GUARD
rsdd_exec verify gap-drift "$@"
