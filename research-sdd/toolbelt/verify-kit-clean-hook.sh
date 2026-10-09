#!/usr/bin/env bash
# SessionStart hook wrapper — runs verify-kit-clean.sh and, ONLY when the kit is NOT clean, emits its report
# as additionalContext so a DIRTY / unpushed kit surfaces when the supervisor project opens (alongside the
# retro sweep). A clean kit emits nothing — no session-start noise. Read-only. Wired from .claude/settings.json.
# RSDD-SELF-DIR (kit #1675): own directory from BASH_SOURCE with symlinks followed - never $0 or the caller's cwd.
_rsdd_s="${BASH_SOURCE[0]}"; _rsdd_n=0
while [ -L "$_rsdd_s" ] && [ "$_rsdd_n" -lt 40 ]; do _rsdd_n=$((_rsdd_n + 1)); _rsdd_t="$(readlink -- "$_rsdd_s")" || break; case "$_rsdd_t" in /*) _rsdd_s="$_rsdd_t" ;; *) _rsdd_s="$(dirname -- "$_rsdd_s")/$_rsdd_t" ;; esac; done
_RSDD_SELF="$(cd -- "$(dirname -- "$_rsdd_s")" && pwd -P)"; unset _rsdd_s _rsdd_n _rsdd_t
here="$_RSDD_SELF"
# shellcheck source=lib/hook-emit.sh
. "$here/lib/hook-emit.sh" 2>/dev/null || { printf 'Research-SDD hook: lib/hook-emit.sh missing beside %s\n' "$0"; exit 0; }   # SENTINEL-HOOK-EMIT-GUARD: a missing lib must announce itself, never mean empty stdout (#1877)
out="$("$here/verify-kit-clean.sh" 2>&1)"; rc=$?
[ "$rc" = 0 ] && exit 0                         # clean → stay silent
# Distinguish a real dirty/unpushed state (rc=1) from a gate that could not run (rc=2: not a git repo /
# misdeployed) so the surfaced banner is not misleading.
if [ "$rc" = 1 ]; then
  hdr="Research-SDD KIT is NOT clean — commit/stash + push before staging §18 retros (else the retro branch/PR mixes unrelated history):"
else
  hdr="Research-SDD kit-clean check could not run (exit $rc — misconfigured path or not a git repo):"
fi
rsdd_hook_emit "$hdr" "$out"
