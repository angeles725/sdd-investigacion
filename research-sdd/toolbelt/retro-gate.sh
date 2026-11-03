#!/usr/bin/env bash
# Ported to Go: `rsdd gate retro`. Compatibility shim (removed in phase 8, kit issue #2270; ported in #2367, #2368).
# retro-gate.sh — §18 Stop-hook body: blocks once when research files advanced without a conforming retro.
# Usage: retro-gate.sh [--json] <target>   (the Stop-hook JSON on stdin; templates/hook-stop-retro-gate.sh execs this)
# Default mode: ALWAYS exits 0 (hook contract); BLOCK is {"decision":"block","reason":...} on stdout, ALLOW is empty
# stdout; one typed state line on stderr; every Stop appends one line to <target>/.claude/.rsdd-retro-gate-stops.log.
# --json: ONE research-sdd.retro-gate/v1 envelope on stdout instead; rc 0 verdict · 1 operational failure · 2 usage
# error · 3 degraded (jq missing). The gate's own contract, scans and deliberate differences from the bash original are
# documented in research-sdd/rsdd/internal/gate (retrogate.go). verify-retro.sh and stage-retro-issues.sh stay beside
# this shim and run as before; the binary cannot see this file's directory, so the shim passes it with --toolbelt.
# A hook must never fail the Stop it guards: when the binary is unavailable the default mode degrades to an allow
# (exit 0, typed stderr line); --json is a machine reader and keeps the CLI degrade (rc 2).
# RSDD-SELF-DIR (kit #1675): own directory from BASH_SOURCE with symlinks followed - never $0 or the caller's cwd.
_rsdd_s="${BASH_SOURCE[0]}"; _rsdd_n=0
while [ -L "$_rsdd_s" ] && [ "$_rsdd_n" -lt 40 ]; do _rsdd_n=$((_rsdd_n + 1)); _rsdd_t="$(readlink -- "$_rsdd_s")" || break; case "$_rsdd_t" in /*) _rsdd_s="$_rsdd_t" ;; *) _rsdd_s="$(dirname -- "$_rsdd_s")/$_rsdd_t" ;; esac; done
if [ -L "$_rsdd_s" ]; then echo "${0##*/}: degraded: self-dir symlink resolution incomplete (hop limit or readlink failure) at $_rsdd_s" >&2; fi
_RSDD_SELF="$(CDPATH='' cd -- "$(dirname -- "$_rsdd_s")" && pwd -P)"; unset _rsdd_s _rsdd_n _rsdd_t
. "$_RSDD_SELF/lib/rsdd-exec.sh" 2>/dev/null || { printf 'degraded: rsdd-unavailable — rsdd-exec.sh missing beside %s\n' "$0" >&2; printf 'rsdd-exec-gate: state=allow branch=degraded (rsdd-unavailable — rsdd-exec.sh missing beside %s)\n' "$0" >&2; case " $* " in *" --json "*) exit 2 ;; esac; exit 0; }   # SENTINEL-RSDD-EXEC-GUARD
case " $* " in *" --json "*) rsdd_exec gate retro --toolbelt "$_RSDD_SELF" "$@"; exit $? ;; esac
rsdd_exec_hook gate gate retro --toolbelt "$_RSDD_SELF" "$@"
