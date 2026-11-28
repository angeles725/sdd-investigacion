#!/usr/bin/env bash
# Ported to Go: `rsdd serial console`. Compatibility shim (removed in phase 8, kit issue #2270; ported in T8b).
# Usage: serial-console.sh list | check | run <target-dir> <com-port> <baud> <command>. READ-ONLY serial/COM acquisition through
# Windows PowerShell over WSL interop (override the binary with POWERSHELL_BIN); `run` preserves the response under
# <target-dir>/sources/probes/ as [CERT-hw] evidence. Exit codes pass through unchanged (0 ok, 2 usage, 3 interop absent,
# 4 mkdir failed, 5 preservation failed, else PowerShell's own). The WSLInterop binfmt gotcha, the safety rules and the
# evidence-integrity contract are documented in research-sdd/rsdd/internal/serial/console/console.go and DYNAMIC-SETUP.md.
# RSDD-SELF-DIR (kit #1675): own directory from BASH_SOURCE with symlinks followed - never $0 or the caller's cwd.
_rsdd_s="${BASH_SOURCE[0]}"; _rsdd_n=0
while [ -L "$_rsdd_s" ] && [ "$_rsdd_n" -lt 40 ]; do _rsdd_n=$((_rsdd_n + 1)); _rsdd_t="$(readlink -- "$_rsdd_s")" || break; case "$_rsdd_t" in /*) _rsdd_s="$_rsdd_t" ;; *) _rsdd_s="$(dirname -- "$_rsdd_s")/$_rsdd_t" ;; esac; done
if [ -L "$_rsdd_s" ]; then echo "${0##*/}: degraded: self-dir symlink resolution incomplete (hop limit or readlink failure) at $_rsdd_s" >&2; fi
_RSDD_SELF="$(CDPATH='' cd -- "$(dirname -- "$_rsdd_s")" && pwd -P)"; unset _rsdd_s _rsdd_n _rsdd_t
. "$_RSDD_SELF/lib/rsdd-exec.sh" 2>/dev/null || { printf 'degraded: rsdd-unavailable — rsdd-exec.sh missing beside %s\n' "$0" >&2; exit 2; }   # SENTINEL-RSDD-EXEC-GUARD
rsdd_exec serial console "$@"
