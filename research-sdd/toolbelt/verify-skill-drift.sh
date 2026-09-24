#!/usr/bin/env bash
# verify-skill-drift.sh — detect deployed skill(s) diverged from the kit source.
#
# Usage: verify-skill-drift.sh [--all | --harness <h>] [--home <dir>] [--profile <name>]
#   --all      check every harness registered in adapters.sh (RESEARCH_SDD_HARNESSES)
#              mutually exclusive with --harness; used by the SessionStart hook
#   --harness  single harness to check (default: claude)
#   --home     home dir used to resolve deployed skill paths (default: $HOME)
#   --profile  prompt profile to compare the deployed skill against (kit issue #993 WU2):
#              flag > $RESEARCH_SDD_PROFILE env > this harness's per-harness default
#              (adapters.sh _RSDD_DEFAULT_PROFILE). profile "claude" compares against the kit
#              source directly, byte-exact, exactly as before this flag existed. Any other
#              profile is re-rendered into a throwaway temp dir (never the kit, never $home) via
#              render-profile.sh and compared against THAT — propose-never-apply extended to
#              renders. Ignored (profile "claude" behaviour only) when adapters.sh predates this
#              feature (no rsdd_resolve_profile/rsdd_valid_profile) — e.g. a test fixture that
#              defines its own minimal adapters.sh.
#
# Exit codes for --all:
#   0  all installed harnesses in-sync or all absent (absent is normal — SILENT)
#   1  one or more installed harnesses diverged
#   2  one or more harnesses could not be checked (src missing, adapters.sh unavailable,
#      HOME unset or empty and no --home given, dangling symlink at deployed path)
#
# Exit codes for single-harness mode:
#   0  in-sync      deployed SKILL.md matches kit source byte-for-byte (SILENT)
#   1  diverged     deployed SKILL.md differs from kit source
#   2  could-not-run adapters.sh/kit source missing or unreadable; harness unknown;
#                   HOME unset or empty and no --home given;
#                   dangling symlink at deployed path
#   3  absent       no deployed skill found (harness not installed / never run)
#
# All non-silent output goes to STDERR. STDOUT is always empty (hook captures 2>&1).
# READ-ONLY: never writes to the filesystem.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
KIT_INSTALL="$(cd "$SELF_DIR/../install" 2>/dev/null && pwd)" \
  || { printf 'verify-skill-drift: ERROR: install dir not found\n' >&2; exit 2; }
ADAPTERS="$KIT_INSTALL/adapters.sh"
if [ ! -f "$ADAPTERS" ]; then
  printf 'verify-skill-drift: ERROR: adapters.sh not found: %s\n' "$ADAPTERS" >&2
  exit 2
fi
# shellcheck source=../install/adapters.sh
. "$ADAPTERS"

# Profile support (kit issue #993 WU2) is feature-detected, not assumed: a fixture adapters.sh
# (e.g. tests/fixtures/adapters-two-sources.sh) defines only the minimal rsdd_field subset this
# script needs and has no reason to also carry rsdd_resolve_profile/rsdd_valid_profile. When
# either is missing, every harness behaves exactly as profile "claude" always has — the kit
# source, byte-exact — so pre-existing tests built against that older adapters.sh keep working
# unmodified.
_VSD_HAS_PROFILE_SUPPORT=0
if declare -F rsdd_resolve_profile >/dev/null 2>&1 && declare -F rsdd_valid_profile >/dev/null 2>&1; then
  _VSD_HAS_PROFILE_SUPPORT=1
fi

# Every non-"claude" profile comparison re-renders into a throwaway temp dir (never the kit,
# never $home — propose-never-apply extended to renders). Collected here and swept once at exit
# regardless of which exit path is taken (could-not-run / absent / in-sync / diverged), so an
# --all run that renders several profiles never leaks more than the process lifetime.
_VSD_RENDER_TMPDIRS=()
_vsd_cleanup_renders() {
  local d
  for d in "${_VSD_RENDER_TMPDIRS[@]:-}"; do
    [ -n "$d" ] && rm -rf "$d"
  done
}
trap _vsd_cleanup_renders EXIT

# _vsd_resolve_src <harness> <home> <src_relkit> <profile_flag> <out_src> <out_tmp> <out_profile>
# — resolves the path to compare the DEPLOYED skill against and writes it into the CALLER's
# <out_src> variable by name (printf -v); <out_tmp> receives the render's OWN throwaway tmp dir
# (empty string when there is none to track — profile "claude" or no profile support); <out_profile>
# receives the resolved profile name. profile "claude" (or no profile support at all): the kit
# source directly, unchanged. Any other profile: a fresh render-profile.sh render in a temp dir.
# Return codes: 0 ok · 2 could-not-run (mktemp/render failure) · 3 unknown profile.
#
# MUST be called DIRECTLY — never wrapped in `$(...)`. A command substitution runs the whole
# function in a SUBSHELL; a `printf -v` write there is invisible to the caller once the subshell
# exits, exactly like a plain variable assignment would be. That exact bug — the ORIGINAL version
# of this function returned its path over stdout for `$(...)` capture, and ALSO appended the tmp
# dir to $_VSD_RENDER_TMPDIRS directly — leaked one tmp dir per --all run (kit issue #1024 review
# F3): the array append happened in the subshell's own copy, never reaching the parent shell's
# array the EXIT trap actually sweeps. Named-output parameters sidestep the subshell entirely by
# requiring a direct call.
_vsd_resolve_src() {
  local h="$1" home="$2" src_relkit="$3" flag="$4" out_src="$5" out_tmp="$6" out_profile="$7"
  local profile pair tmp render_err
  if [ "$_VSD_HAS_PROFILE_SUPPORT" != 1 ]; then
    printf -v "$out_src" '%s' "$KIT/$src_relkit"
    printf -v "$out_tmp" ''
    printf -v "$out_profile" 'claude'
    return 0
  fi
  pair="$(rsdd_resolve_profile "$h" "$flag")"; profile="${pair%%:*}"
  if ! rsdd_valid_profile "$profile" "$KIT"; then
    return 3
  fi
  printf -v "$out_profile" '%s' "$profile"
  if [ "$profile" = "claude" ]; then
    printf -v "$out_src" '%s' "$KIT/$src_relkit"
    printf -v "$out_tmp" ''
    return 0
  fi
  tmp="$(mktemp -d)" || return 2
  if ! render_err="$("$KIT/toolbelt/render-profile.sh" "$profile" "$tmp" 2>&1)"; then
    printf 'verify-skill-drift: render-profile.sh failed for profile "%s": %s\n' "$profile" "$render_err" >&2
    rm -rf "$tmp"
    return 2
  fi
  printf -v "$out_src" '%s' "$tmp/$src_relkit"
  printf -v "$out_tmp" '%s' "$tmp"
  return 0
}

# _vsd_check_render_completeness <config_root> <profile> <kit> — for a NON-claude profile, verify
# the PERSISTED render dir (<config_root>/research-sdd/profile/<profile>/, kit issue #993 WU2)
# still exists and is intact: its 3 rendered files still match a fresh re-render, and a handful of
# representative F1-completion symlinks (kit issue #1024 review F1) still resolve. Prints one
# status word and returns 0 only for "ok"; every other outcome (missing/diverged/incomplete/error)
# is a drift or could-not-run state the caller must NEVER fold into "in sync" — before this fix, a
# missing/gutted render dir was invisible: only the deployed skill_path was ever compared, so
# "Kit path:" could point at nothing while the check still exited 0 (kit issue #1024 review F3).
_vsd_check_render_completeness() {
  local config_root="$1" profile="$2" kit="$3" render_dir tmp render_err rel f
  render_dir="$config_root/research-sdd/profile/$profile"
  if [ ! -d "$render_dir" ]; then
    printf 'missing\n'; return 1
  fi
  tmp="$(mktemp -d)" || { printf 'error\n'; return 2; }
  if ! render_err="$("$kit/toolbelt/render-profile.sh" "$profile" "$tmp" 2>&1)"; then
    rm -rf "$tmp"
    printf 'error\n'; return 2
  fi
  for rel in skills/research-sdd/SKILL.md PROMPT-LOOP.md METHODOLOGY.md; do
    if ! cmp -s "$tmp/$rel" "$render_dir/$rel" 2>/dev/null; then
      rm -rf "$tmp"
      printf 'diverged\n'; return 1
    fi
  done
  rm -rf "$tmp"
  for f in toolbelt TARGETS.md skills/README.md; do
    if [ ! -e "$render_dir/$f" ]; then
      printf 'incomplete\n'; return 1
    fi
  done
  printf 'ok\n'; return 0
}

all_mode=0
harness="claude"
harness_set=0
home=""   # resolved after arg parsing; --home wins over $HOME
profile_flag=""

while [ $# -gt 0 ]; do
  case "$1" in
    --all)     all_mode=1; shift ;;
    --harness)
      if [ $# -lt 2 ] || [ -z "${2:-}" ]; then
        printf 'verify-skill-drift: --harness requires a non-empty value\n' >&2; exit 2
      fi
      harness="$2"; harness_set=1; shift 2 ;;
    --home)
      if [ $# -lt 2 ] || [ -z "${2:-}" ]; then
        printf 'verify-skill-drift: --home requires a non-empty value\n' >&2; exit 2
      fi
      home="$2"; shift 2 ;;
    --profile)
      if [ $# -lt 2 ] || [ -z "${2:-}" ]; then
        printf 'verify-skill-drift: --profile requires a non-empty value\n' >&2; exit 2
      fi
      profile_flag="$2"; shift 2 ;;
    -h|--help)
      sed -n '3,32p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) printf 'verify-skill-drift: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

if [ "$all_mode" -eq 1 ] && [ "$harness_set" -eq 1 ]; then
  printf 'verify-skill-drift: --all and --harness are mutually exclusive\n' >&2
  exit 2
fi

# Resolve home: --home wins; fall back to $HOME; fail if neither is set or non-empty.
# This check is AFTER arg parsing so --home and --help work without HOME set.
if [ -z "$home" ]; then
  home="${HOME:-}"
fi
# SENTINEL-HOME-CHECK
if [ -z "$home" ]; then
  printf 'verify-skill-drift: could-not-run: HOME is unset or empty and no --home given\n' >&2
  exit 2
fi

KIT="$(cd "$KIT_INSTALL/.." && pwd)"

# Named-output receivers for _vsd_resolve_src (printf -v targets — see its own comment for why
# this must be a direct call, never $(...)). Pre-declared so shellcheck (SC2154) and `set -u`
# both see them as defined before _vsd_resolve_src's printf -v ever writes to them.
_vsd_src="" _vsd_tmp="" _vsd_profile=""

# ── --all mode: iterate every registered harness ──────────────────────────────
if [ "$all_mode" -eq 1 ]; then
  checked=0 in_sync=0 diverged_count=0 absent_count=0 err_count=0
  fix_shown=0          # number of per-harness fix lines emitted so far
  max_fix_lines=1      # cap: emit at most this many detailed fix lines (budget: headroom < 542 chars)
  also_names=""        # comma-separated names of diverged harnesses beyond the cap

  # SENTINEL-ALL-LOOP-FOR
  for h in $RESEARCH_SDD_HARNESSES; do
    checked=$((checked + 1))

    src_relkit="$(rsdd_field "$h" skill_src_relkit "$home")"  # SENTINEL-SRC-RELKIT-LOOKUP
    deployed="$(rsdd_field "$h" skill_path "$home")"

    # Deployed checks: dangling symlink → could-not-run (must precede the absent ! -e check)
    # SENTINEL-DANGLING-ALL
    if [ -L "$deployed" ] && [ ! -e "$deployed" ]; then
      err_count=$((err_count + 1))
      printf 'verify-skill-drift: could-not-run harness=%s (dangling symlink: %s)\n' "$h" "$deployed" >&2
      continue
    fi
    # Absent is normal — not installing a harness is not an error
    if [ ! -e "$deployed" ]; then
      absent_count=$((absent_count + 1))
      continue
    fi
    if [ ! -f "$deployed" ] || [ ! -r "$deployed" ]; then
      err_count=$((err_count + 1))
      printf 'verify-skill-drift: could-not-run harness=%s (deployed not a readable file: %s)\n' \
        "$h" "$deployed" >&2
      continue
    fi

    # Resolve $src (kit source, or a fresh profile render) only once deployed is known to exist
    # and be comparable — an absent/dangling/unreadable harness above must never pay for a
    # render it has no use for (kit issue #993 WU2). Called DIRECTLY (never via $(...)) so the
    # tmp-dir tracking append below happens in THIS shell, where the EXIT trap can see it —
    # kit issue #1024 review F3 (a command-substitution-wrapped call leaked one tmp dir here).
    _vsd_resolve_src "$h" "$home" "$src_relkit" "$profile_flag" _vsd_src _vsd_tmp _vsd_profile
    src_rc=$?
    if [ "$src_rc" -ne 0 ]; then
      err_count=$((err_count + 1))
      if [ "$src_rc" = 3 ]; then
        printf 'verify-skill-drift: could-not-run harness=%s (unknown profile)\n' "$h" >&2
      else
        printf 'verify-skill-drift: could-not-run harness=%s (profile render failed)\n' "$h" >&2
      fi
      continue
    fi
    src="$_vsd_src"
    [ -n "$_vsd_tmp" ] && _VSD_RENDER_TMPDIRS+=("$_vsd_tmp")

    # Source checks (could-not-run)
    if [ ! -f "$src" ] || [ ! -r "$src" ]; then
      err_count=$((err_count + 1))
      printf 'verify-skill-drift: could-not-run harness=%s (src missing: %s)\n' "$h" "$src" >&2
      continue
    fi

    # For a non-claude profile, the deployed skill_path matching $src is NOT sufficient — the
    # PERSISTED render dir it depends on at runtime (for "Kit path:" resolution) could be
    # missing, hand-edited, or incompletely linked (kit issue #1024 review F3). Never let that
    # collapse into "in sync".
    if [ "$_vsd_profile" != "claude" ]; then
      render_state="$(_vsd_check_render_completeness "$(rsdd_field "$h" config_root "$home")" "$_vsd_profile" "$KIT")"
      if [ "$render_state" != "ok" ] && cmp -s "$src" "$deployed"; then
        err_count=$((err_count + 1))
        printf 'verify-skill-drift: could-not-run harness=%s (render dir %s: %s)\n' "$h" "$render_state" \
          "$(rsdd_field "$h" config_root "$home")/research-sdd/profile/$_vsd_profile" >&2
        continue
      fi
    fi

    if cmp -s "$src" "$deployed"; then
      in_sync=$((in_sync + 1))
    else
      diverged_count=$((diverged_count + 1))
      # Show up to max_fix_lines detailed fix lines with deployed path (budget cap)
      if [ "$fix_shown" -lt "$max_fix_lines" ]; then
        dep_short="${deployed#"$home/"}"
        printf 'verify-skill-drift: fix: research-sdd-install.sh --harness %s --force-skill  # deployed: ~/%s\n' \
          "$h" "$dep_short" >&2
        fix_shown=$((fix_shown + 1))
      else
        # SENTINEL-ALSO-DIVERGED
        also_names="${also_names:+$also_names, }$h"
      fi
    fi
  done

  # List names of diverged harnesses beyond the cap — do NOT say "rerun" (output is capped, same result)
  if [ -n "$also_names" ]; then
    printf 'verify-skill-drift: also diverged: %s (same fix with --harness <name>)\n' "$also_names" >&2
  fi

  # Summary only on non-zero exit (in-sync/all-absent is truly silent)
  # SENTINEL-SUMMARY-GUARD
  if [ "$diverged_count" -gt 0 ] || [ "$err_count" -gt 0 ]; then
    printf 'verify-skill-drift: all: checked=%d in-sync=%d diverged=%d absent=%d could-not-run=%d\n' \
      "$checked" "$in_sync" "$diverged_count" "$absent_count" "$err_count" >&2
  fi

  if [ "$diverged_count" -gt 0 ]; then exit 1; fi
  # SENTINEL-ERR-EXIT2
  if [ "$err_count" -gt 0 ]; then exit 2; fi
  exit 0
fi

# ── Single-harness mode ───────────────────────────────────────────────────────

# Validate harness: rsdd_field exits 2 on unknown harness
if ! rsdd_field "$harness" config_root "$home" >/dev/null 2>&1; then
  printf 'verify-skill-drift: ERROR: unknown harness "%s"\n' "$harness" >&2
  exit 2
fi

src_relkit="$(rsdd_field "$harness" skill_src_relkit "$home")"
deployed="$(rsdd_field "$harness" skill_path "$home")"

# Called DIRECTLY (never via $(...)) — see _vsd_resolve_src's own comment: a command-substitution
# wrapper would run it in a subshell where the tmp-dir append is invisible to this shell's EXIT
# trap (kit issue #1024 review F3).
_vsd_resolve_src "$harness" "$home" "$src_relkit" "$profile_flag" _vsd_src _vsd_tmp _vsd_profile
src_rc=$?
if [ "$src_rc" -ne 0 ]; then
  if [ "$src_rc" = 3 ]; then
    printf 'verify-skill-drift: ERROR: unknown profile for harness "%s"\n' "$harness" >&2
  else
    printf 'verify-skill-drift: ERROR: could not render profile for harness "%s"\n' "$harness" >&2
  fi
  exit 2
fi
src="$_vsd_src"
[ -n "$_vsd_tmp" ] && _VSD_RENDER_TMPDIRS+=("$_vsd_tmp")

# Source file checks (could-not-run)
if [ ! -f "$src" ]; then
  printf 'verify-skill-drift: ERROR: kit source not found: %s\n' "$src" >&2
  exit 2
fi
if [ ! -r "$src" ]; then
  printf 'verify-skill-drift: ERROR: kit source not readable: %s\n' "$src" >&2
  exit 2
fi

# Deployed file checks: dangling symlink → could-not-run (must precede absent ! -e check)
# SENTINEL-DANGLING-SINGLE
if [ -L "$deployed" ] && [ ! -e "$deployed" ]; then
  printf 'verify-skill-drift: could-not-run harness=%s (dangling symlink: %s)\n' "$harness" "$deployed" >&2
  exit 2
fi
# Absent = exit 3; not-regular = could-not-run
if [ ! -e "$deployed" ]; then
  printf 'verify-skill-drift: absent harness=%s deployed=%s\n' "$harness" "$deployed" >&2
  exit 3
fi
if [ ! -f "$deployed" ]; then
  printf 'verify-skill-drift: ERROR: deployed path exists but is not a regular file: %s\n' "$deployed" >&2
  exit 2
fi
if [ ! -r "$deployed" ]; then
  printf 'verify-skill-drift: ERROR: deployed skill not readable: %s\n' "$deployed" >&2
  exit 2
fi

# Byte-for-byte comparison
if cmp -s "$src" "$deployed"; then
  # For a non-claude profile, matching $src alone is not sufficient — the PERSISTED render dir
  # it depends on at runtime (for "Kit path:" resolution) could be missing, hand-edited, or
  # incompletely linked (kit issue #1024 review F3). Never let that collapse into "in sync".
  if [ "$_vsd_profile" != "claude" ]; then
    render_state="$(_vsd_check_render_completeness "$(rsdd_field "$harness" config_root "$home")" "$_vsd_profile" "$KIT")"
    if [ "$render_state" != "ok" ]; then
      printf 'verify-skill-drift: could-not-run harness=%s (render dir %s: %s)\n' "$harness" "$render_state" \
        "$(rsdd_field "$harness" config_root "$home")/research-sdd/profile/$_vsd_profile" >&2
      exit 2
    fi
  fi
  exit 0  # in-sync — silent
fi

printf 'verify-skill-drift: diverged harness=%s deployed=%s\n' "$harness" "$deployed" >&2
exit 1
