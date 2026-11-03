#!/usr/bin/env bash
# Ported to Go: `rsdd verify registry`. Compatibility shim (removed in phase 8, kit issue #2270; ported in #2362/#2364).
# Usage: verify-registry.sh [--json]
# Exit: 0 report (advisory findings never fail) · 1 operational failure (TARGETS.md missing, no usable path) · 2 usage error.
# Reconciles the master registry (KIT/TARGETS.md) against the corpora on disk, WARN-only and READ-ONLY (propose-never-apply);
# --json prints one research-sdd.verify-registry/v1 envelope. Env: RSDD_REGISTRY_TOL (default 2), RSDD_REGISTRY_SESSION_BUDGET=1.
# The report is produced by the binary, byte for byte as this script printed it. The binary cannot see this file's directory,
# so the kit root (this directory's parent, physical path) is handed over as --kit. Differences from the bash original: the
# package doc of research-sdd/rsdd/internal/verify (registry.go) - `--json` no longer needs jq, so its "degraded, exit 3" state is gone.
# RSDD-SELF-DIR (kit #1675): own directory from BASH_SOURCE with symlinks followed - never $0 or the caller's cwd.
_rsdd_s="${BASH_SOURCE[0]}"; _rsdd_n=0
while [ -L "$_rsdd_s" ] && [ "$_rsdd_n" -lt 40 ]; do _rsdd_n=$((_rsdd_n + 1)); _rsdd_t="$(readlink -- "$_rsdd_s")" || break; case "$_rsdd_t" in /*) _rsdd_s="$_rsdd_t" ;; *) _rsdd_s="$(dirname -- "$_rsdd_s")/$_rsdd_t" ;; esac; done
if [ -L "$_rsdd_s" ]; then echo "${0##*/}: degraded: self-dir symlink resolution incomplete (hop limit or readlink failure) at $_rsdd_s" >&2; fi
_RSDD_SELF="$(CDPATH='' cd -- "$(dirname -- "$_rsdd_s")" && pwd -P)"; unset _rsdd_s _rsdd_n _rsdd_t
. "$_RSDD_SELF/lib/rsdd-exec.sh" 2>/dev/null || { printf 'degraded: rsdd-unavailable — rsdd-exec.sh missing beside %s\n' "$0" >&2; exit 2; }   # SENTINEL-RSDD-EXEC-GUARD
KIT="$(cd -P -- "$_RSDD_SELF/.." && pwd -P)"
rsdd_exec verify registry --kit "$KIT" "$@"
