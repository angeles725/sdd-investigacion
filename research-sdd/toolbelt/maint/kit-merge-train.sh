#!/usr/bin/env bash
# Ported to Go: `rsdd gate merge-train`. Compatibility shim (removed in phase 8, kit issue #2499).
# kit-merge-train.sh [options] <pr> [<pr>...]: gate a batch of approved kit PRs ONCE on a combined local train head,
# then merge them in order (kit issue #2213). The contract (options, receipt, typed `kit-merge-train: ...` lines and exit
# codes) is documented on gate.RunMergeTrain (research-sdd/rsdd/internal/gate/mergetrain.go) and in `--help`; the merge
# gate runs in-process there (no merge-gate.sh child; KIT_MERGE_GATE is ignored) and the CI wait / MERGED check of
# kit-wait-merge.sh and the flock-serialised gate run of kit-gate.sh are inlined. The frozen bash original is kept as the
# differential oracle under research-sdd/rsdd/internal/gate/testdata/legacy/mergetrain/.
# RSDD-SELF-DIR (kit #1675): own directory from BASH_SOURCE with symlinks followed - never $0 or the caller's cwd.
_rsdd_s="${BASH_SOURCE[0]}"; _rsdd_n=0
while [ -L "$_rsdd_s" ] && [ "$_rsdd_n" -lt 40 ]; do _rsdd_n=$((_rsdd_n + 1)); _rsdd_t="$(readlink -- "$_rsdd_s")" || break; case "$_rsdd_t" in /*) _rsdd_s="$_rsdd_t" ;; *) _rsdd_s="$(dirname -- "$_rsdd_s")/$_rsdd_t" ;; esac; done
if [ -L "$_rsdd_s" ]; then echo "${0##*/}: degraded: self-dir symlink resolution incomplete (hop limit or readlink failure) at $_rsdd_s" >&2; fi
_RSDD_SELF="$(CDPATH='' cd -- "$(dirname -- "$_rsdd_s")" && pwd -P)"; unset _rsdd_s _rsdd_n _rsdd_t
. "$_RSDD_SELF/../lib/rsdd-exec.sh" 2>/dev/null || { printf 'degraded: rsdd-unavailable — rsdd-exec.sh missing beside %s\n' "$0" >&2; exit 2; }   # SENTINEL-RSDD-EXEC-GUARD
rsdd_exec gate merge-train "$@"
