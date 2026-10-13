#!/usr/bin/env bash
# SessionStart hook wrapper — runs sweep-retros.sh and emits its output as
# additionalContext so pending §18 retros surface when the supervisor project opens.
# Default: SUMMARY mode — oldest 5 PENDING rows; absent targets collapsed to one line.
# Pass --full to emit the complete sweep output unchanged (byte-identical to old default).
# Wired from .claude/settings.json (SessionStart). Read-only.
# RSDD-SELF-DIR (kit #1675): own directory from BASH_SOURCE with symlinks followed - never $0 or the caller's cwd.
_rsdd_s="${BASH_SOURCE[0]}"; _rsdd_n=0
while [ -L "$_rsdd_s" ] && [ "$_rsdd_n" -lt 40 ]; do _rsdd_n=$((_rsdd_n + 1)); _rsdd_t="$(readlink -- "$_rsdd_s")" || break; case "$_rsdd_t" in /*) _rsdd_s="$_rsdd_t" ;; *) _rsdd_s="$(dirname -- "$_rsdd_s")/$_rsdd_t" ;; esac; done
if [ -L "$_rsdd_s" ]; then echo "${0##*/}: degraded: self-dir symlink resolution incomplete (hop limit or readlink failure) at $_rsdd_s" >&2; fi
_RSDD_SELF="$(CDPATH='' cd -- "$(dirname -- "$_rsdd_s")" && pwd -P)"; unset _rsdd_s _rsdd_n _rsdd_t
here="$_RSDD_SELF"
# shellcheck source=lib/hook-emit.sh
. "$here/lib/hook-emit.sh" 2>/dev/null || { printf 'Research-SDD hook: lib/hook-emit.sh missing beside %s\n' "$0"; exit 0; }   # SENTINEL-HOOK-EMIT-GUARD: a missing lib must announce itself, never mean empty stdout (#1877)

# Stale-checkout-FIRST (kit issue #2215): this is the first SessionStart hook, so a stale shared kit checkout is reported before
# any kit-content WARN (tool catalog, registry, install --verify) is read: those can be artifacts of the stale tree. Local refs
# only - no fetch (lib/checkout-freshness.sh). At most ONE line of <= 300 chars, only when behind by more than
# RESEARCH_SDD_KIT_STALE_MAX_COMMITS (default 20). `degraded` (not measurable) is never reported as fresh, but it cannot be
# cleared at session start either, so it is silent unless RESEARCH_SDD_KIT_STALE_VERBOSE=1. RESEARCH_SDD_KIT_STALE_CHECK=off
# opts out; RESEARCH_SDD_KIT_DIR overrides the kit dir. A missing lib announces itself (never an empty, confident nothing).
stale_line=""
if [ "${RESEARCH_SDD_KIT_STALE_CHECK:-}" != "off" ]; then   # SENTINEL-STALE-FIRST
  if . "$here/lib/checkout-freshness.sh" 2>/dev/null; then
    _kdir="${RESEARCH_SDD_KIT_DIR:-$here/..}"
    _rec="$(rsdd_checkout_freshness "$_kdir" "${RESEARCH_SDD_KIT_STALE_MAX_COMMITS:-}")"
    case "$_rec" in
      state=stale*)
        _n="${_rec#*behind=}"; _n="${_n%% *}"; _ref="${_rec#*ref=}"; _ref="${_ref%% *}"; _age="${_rec##*age=}"
        _disp="$(cd -P "$_kdir" 2>/dev/null && pwd -P)"; _disp="${_disp:-$_kdir}"; case "$_disp" in "$HOME"/*) _disp="~${_disp#"$HOME"}" ;; esac
        stale_line="STALE KIT CHECKOUT: behind $_ref by $_n commits (last fetch $_age ago, local refs). Catalog/registry/install --verify warnings below may be artifacts. Fix (no live session): cd $_disp && git fetch && git merge --ff-only $_ref"
        stale_line="${stale_line:0:300}" ;;
      state=degraded*)
        [ "${RESEARCH_SDD_KIT_STALE_VERBOSE:-}" != "1" ] || stale_line="KIT CHECKOUT FRESHNESS unknown (${_rec#*reason=}): kit-content warnings below cannot be ruled stale." ;;
    esac
  else
    stale_line="KIT CHECKOUT FRESHNESS unknown (lib/checkout-freshness.sh missing beside $0): kit-content warnings below cannot be ruled stale."
  fi
fi

# Parse --full flag (any position).
_full=0
for _arg in "$@"; do
  case "$_arg" in --full) _full=1 ;; esac
done

out="$("$here/sweep-retros.sh" 2>&1)"; rc=$?

# Operational failure: the sweep could not run — surface rather than pass silently.
if [ "$rc" -ne 0 ]; then
  hdr="${stale_line:+$stale_line$'\n'}Research-SDD retro sweep could not run (exit $rc — check TARGETS.md and lib/ helper):"
  rsdd_hook_emit "$hdr" "$out"
  exit 0
fi

# SUMMARY MODE (default): filter sweep output to oldest 5 PENDING blocks, one collapsed
# absent-target line, and the Summary: line.  All other lines (WARN, MISSING-RETRO, waived,
# per-target INFO lines) are suppressed — the user runs --full to see them.
# --full passes the full sweep output through unchanged.
if [ "$_full" = 0 ]; then
  out="$(printf '%s\n' "$out" | awk '
    BEGIN { pcnt=0; limit=5; in_pb=0 }

    # Suppress verbose lines visible only in --full mode.
    /^WARN:/         { next }
    /^MISSING-RETRO:/ { next }
    /^waived:/       { next }

    # Drop individual per-target absent-input INFO lines — collapsed to aggregate below.
    /^INFO: corpus not found \(absent-input\):/ { next }

    # Aggregate absent-input line: swap the "see INFO lines above" pointer for --full hint.
    /^INFO: [0-9]+ target\(s\) not traversed \(absent-input\)/ {
      sub(/see INFO lines above\.?/, "run --full to list them.")
      print; next  # ABSENT-COLLAPSE-PRINT
    }

    # PENDING header — start a new block; count determines whether to show it.
    /^PENDING  / {
      pcnt++
      in_pb = (pcnt <= limit)
      if (in_pb) print
      next
    }

    # Continuation lines belonging to a PENDING block (9-space indent).
    /^         / {
      if (in_pb) print
      next
    }

    # Summary: line is emitted BYTE-IDENTICAL in both modes; prepend "N more" when needed.
    /^Summary:/ {
      if (pcnt > limit)
        printf "\342\200\246 and %d more \342\200\224 run sweep-retros.sh --full\n", (pcnt - limit)
      print; next  # SUMMARY-LINE-PRINT
    }

    # Everything else: Nothing to review, empty lines.
    { in_pb=0; print }
  ')"
fi

rsdd_hook_emit "${stale_line:+$stale_line$'\n'}Research-SDD retro sweep (supervisor project):" "$out"
