#!/usr/bin/env bash
# corpus-markers.sh — shared helper: does a directory carry a recognised corpus marker?
#
# WHY: research-sdd-init.sh's --wire anti-implicit-scaffold guard (kit issue #1047) and
# verify-registry.sh's registered-path marker check (kit issue #1108) both need to agree on
# EXACTLY which files make a directory "a corpus". Before #1108 this predicate lived only as
# research-sdd-init.sh's inline corpus_present() — duplicating it into verify-registry.sh would
# risk the two silently drifting (init refusing to scaffold over a directory verify-registry
# would still call markerless, or the reverse). This file is the single source of truth; both
# scripts source it.
#
# Recognised markers (ROOT-LEVEL ONLY — no descent): INDEX.md, CATALOG.md, or any
# RESEARCH-STATE*.md (including the §16 multi-focus RESEARCH-STATE-<focus>.md form) that is NOT
# a *.template.md. A stray copied template never counts as a marker. This is DELIBERATELY
# narrower than the maxdepth-3 corpus-root search verify-registry.sh's block-count reconciler
# uses (which tolerates a nested <target>/research/RESEARCH-STATE.md layout) — the marker check
# exists precisely to surface a registered path that only resolves via that tolerant deep search,
# not at the canonical root or research-sdd-init.sh's own nested convention (<target>/corpus/).
#
#   corpus_has_marker <dir>
#     Returns 0 (true) if <dir> carries a recognised corpus marker at its OWN root; returns 1
#     (false) otherwise, including when <dir> does not exist. Never prints anything — callers
#     test the exit status.
#
#   corpus_marker_present <root1> [<root2> ...]
#     Convenience: returns 0 if ANY of the given candidate roots carries a marker (mirrors
#     research-sdd-init.sh's anti-clobber guard, which checks BOTH $target and $target/corpus —
#     a corpus may be registered flat or nested one level under 'corpus/'). Returns 1 only when
#     NONE of the candidates carries a marker.
#
# Idempotent: safe to source more than once (a caller may pull this in alongside another lib
# that also sources it in the same shell).

if ! declare -F corpus_has_marker >/dev/null 2>&1; then
  corpus_has_marker() {
    local r="$1" m f
    [ -d "$r" ] || return 1
    for m in INDEX.md CATALOG.md; do
      [ -e "$r/$m" ] && return 0
    done
    for f in "$r"/RESEARCH-STATE*.md; do
      [ -e "$f" ] || continue
      case "$f" in *.template.md) continue;; esac
      return 0
    done
    return 1
  }
fi

if ! declare -F corpus_marker_present >/dev/null 2>&1; then
  corpus_marker_present() {
    local r
    for r in "$@"; do
      corpus_has_marker "$r" && return 0
    done
    return 1
  }
fi
