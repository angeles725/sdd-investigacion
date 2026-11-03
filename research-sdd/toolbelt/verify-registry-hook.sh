#!/usr/bin/env bash
# Ported to Go: `rsdd verify registry-hook`. Compatibility shim (removed in phase 8, kit issue #2270; ported in #2363).
# SessionStart hook wrapper: runs the registry check and emits its output as additionalContext so master-registry drift
# (TARGETS.md 'N md' vs the real corpus block count) surfaces when the supervisor project opens. Wired from
# .claude/settings.json (SessionStart). Read-only; COMPACT by default (kit issue #1816), --full emits the report unchanged.
# The kit checked is this script's own kit (its directory's parent), passed explicitly to the binary.
# RSDD-SELF-DIR (kit #1675): own directory from BASH_SOURCE with symlinks followed - never $0 or the caller's cwd.
_rsdd_s="${BASH_SOURCE[0]}"; _rsdd_n=0
while [ -L "$_rsdd_s" ] && [ "$_rsdd_n" -lt 40 ]; do _rsdd_n=$((_rsdd_n + 1)); _rsdd_t="$(readlink -- "$_rsdd_s")" || break; case "$_rsdd_t" in /*) _rsdd_s="$_rsdd_t" ;; *) _rsdd_s="$(dirname -- "$_rsdd_s")/$_rsdd_t" ;; esac; done
if [ -L "$_rsdd_s" ]; then echo "${0##*/}: degraded: self-dir symlink resolution incomplete (hop limit or readlink failure) at $_rsdd_s" >&2; fi
_RSDD_SELF="$(CDPATH='' cd -- "$(dirname -- "$_rsdd_s")" && pwd -P)"; unset _rsdd_s _rsdd_n _rsdd_t
. "$_RSDD_SELF/lib/rsdd-exec.sh" 2>/dev/null || { printf 'Research-SDD hook: lib/rsdd-exec.sh missing beside %s\n' "$0"; exit 0; }   # SENTINEL-HOOK-EMIT-GUARD: a missing lib must announce itself, never mean empty stdout
KIT="$(cd -P -- "$_RSDD_SELF/.." && pwd -P)"
rsdd_exec_hook sweep verify registry-hook --kit "$KIT" "$@"
