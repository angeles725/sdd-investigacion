#!/usr/bin/env bash
# Ported to Go: `rsdd verify corrections`. Compatibility shim (removed in phase 8, kit issue #2270; ported in #2625).
# verify-corrections.sh — §14 reciprocal-backlink lint for a Research-SDD corpus (retro delta).
# Usage: verify-corrections.sh <target-dir>
# Exit: 0 = every declared correction is reciprocated (or none) · 1 = a one-directional correction, or a block file that
#       could not be read (a typed `degraded:` line, never an "ok") · 2 = bad args / no block files.
# A block that declares "Corrects [Block N]" must be back-linked by block N ("corrected in B<this>"): the binary reads
# every canonical block file under the target (the corpus-wide discriminator now lives in research-sdd/rsdd/internal/core/kit,
# depth <= 3), extracts the declarations clause by clause and requires the reciprocal note. The report is produced by the
# binary, byte for byte as this script printed it. Differences from the bash original (each pinned by a Go test): the package
# doc of research-sdd/rsdd/internal/verify/corrections and tool-registry.d/verify-corrections.md.
# RSDD-SELF-DIR (kit #1675): own directory from BASH_SOURCE with symlinks followed - never $0 or the caller's cwd.
_rsdd_s="${BASH_SOURCE[0]}"; _rsdd_n=0
while [ -L "$_rsdd_s" ] && [ "$_rsdd_n" -lt 40 ]; do _rsdd_n=$((_rsdd_n + 1)); _rsdd_t="$(readlink -- "$_rsdd_s")" || break; case "$_rsdd_t" in /*) _rsdd_s="$_rsdd_t" ;; *) _rsdd_s="$(dirname -- "$_rsdd_s")/$_rsdd_t" ;; esac; done
if [ -L "$_rsdd_s" ]; then echo "${0##*/}: degraded: self-dir symlink resolution incomplete (hop limit or readlink failure) at $_rsdd_s" >&2; fi
_RSDD_SELF="$(CDPATH='' cd -- "$(dirname -- "$_rsdd_s")" && pwd -P)"; unset _rsdd_s _rsdd_n _rsdd_t
. "$_RSDD_SELF/lib/rsdd-exec.sh" 2>/dev/null || { printf 'degraded: rsdd-unavailable — rsdd-exec.sh missing beside %s\n' "$0" >&2; exit 2; }   # SENTINEL-RSDD-EXEC-GUARD
rsdd_exec verify corrections "$@"
