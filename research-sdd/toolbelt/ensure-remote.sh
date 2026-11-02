#!/usr/bin/env bash
# Ported to Go: `rsdd corpus ensure-remote`. Compatibility shim (removed in phase 8, kit issue #2460).
#
# ensure-remote.sh — create a PRIVATE-BY-CONSTRUCTION GitHub remote for a Research-SDD corpus and push it
# (METHODOLOGY §15 "Remote"). The corpora DECOMPILE proprietary systems, so a public repo would leak the research:
# the command makes a public remote UNREACHABLE by construction, not by convention. It is NEVER auto-invoked by the
# loop; the operator runs it once, per target, on consent.
#
# THE SIX-LAYER PRIVATE GUARD (each independently blocks a public leak; the implementation and its tests are
# research-sdd/rsdd/internal/corpus/ensureremote):
#   1. NO PUBLIC CODE PATH — `--private` is hard-coded on the single `gh repo create`; there is no --public flag and
#      no env var that flips visibility.
#   2. FORCE A PERSONAL ACCOUNT — the owner comes from `gh api user` and is REFUSED if it is an organization (orgs can
#      carry a default-public creation policy) or if its type cannot be verified.
#   3. CONSENT GATE — refuses unless `--yes` (or RSDD_ALLOW_REMOTE=1) is present; no network call happens before it.
#   4. PRE-PUSH SECRET SWEEP — seeds and commits `.gitignore` with secret-bearing paths, refuses a dirty working tree,
#      runs scan-secrets.sh --committed over all committed history, and REFUSES any git-TRACKED secret-type file
#      (*.pem/*.der/*.key/*.p12/*.pfx/id_rsa*/*.jks/*.keystore, security/licenses/certificates/keystore/keyring dirs)
#      unless `<target>/.research-sdd/secret-files.conf` (`allow <path-glob>`) names it AND every committed revision
#      of it is positively identified as public material; private keys are never allowable.
#   5. CREATE THEN VERIFY visibility BEFORE ANY PUSH — read back `visibility`; if it is not PRIVATE, one forced
#      `--visibility private` and a re-read; still not private is a HARD ABORT (origin removed, exit 6, no push).
#   6. IDEMPOTENT — if `origin` already resolves, do nothing (never a duplicate repo).
#
# BOUNDS (kit issue #1841): `gh repo create`, `gh repo edit`, the visibility read-back and the owner lookups run with
# GH_PROMPT_DISABLED=1 and a bound: RSDD_GH_TIMEOUT (default 20 s) for all but the create, RSDD_GH_CREATE_TIMEOUT
# (default 60 s) for `gh repo create`. Both take a positive integer of seconds; anything else falls back to the
# default with a note. A create TIMEOUT is a typed DEGRADED + PARTIAL-STATE line with the exact next step.
#
# Usage: ensure-remote.sh <target-dir> [--yes] [--name <repo>]
#   default repo name: research-<basename-of-target-dir>, slugified to [a-z0-9-].
# Exit: 0 = remote present (created+pushed, or already existed) · 2 = bad args / not a git repo / malformed allow
#       list · 3 = no consent · 4 = owner is an organization · 5 = secret leak (refused to push) · 6 = visibility
#       verification failed (HARD ABORT, no push) · 7 = tooling missing / git-or-gh op failed · 8 = dirty working tree.
# RSDD-SELF-DIR (kit #1675): own directory from BASH_SOURCE with symlinks followed - never $0 or the caller's cwd.
_rsdd_s="${BASH_SOURCE[0]}"; _rsdd_n=0
while [ -L "$_rsdd_s" ] && [ "$_rsdd_n" -lt 40 ]; do _rsdd_n=$((_rsdd_n + 1)); _rsdd_t="$(readlink -- "$_rsdd_s")" || break; case "$_rsdd_t" in /*) _rsdd_s="$_rsdd_t" ;; *) _rsdd_s="$(dirname -- "$_rsdd_s")/$_rsdd_t" ;; esac; done
if [ -L "$_rsdd_s" ]; then echo "${0##*/}: degraded: self-dir symlink resolution incomplete (hop limit or readlink failure) at $_rsdd_s" >&2; fi
_RSDD_SELF="$(CDPATH='' cd -- "$(dirname -- "$_rsdd_s")" && pwd -P)"; unset _rsdd_s _rsdd_n _rsdd_t
. "$_RSDD_SELF/lib/rsdd-exec.sh" 2>/dev/null || { printf 'degraded: rsdd-unavailable — rsdd-exec.sh missing beside %s\n' "$0" >&2; exit 2; }   # SENTINEL-RSDD-EXEC-GUARD
rsdd_exec corpus ensure-remote --toolbelt "$_RSDD_SELF" "$@"   # --toolbelt: scan-secrets.sh is resolved beside THIS shim
