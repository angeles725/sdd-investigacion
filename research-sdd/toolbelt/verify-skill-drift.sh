#!/usr/bin/env bash
# verify-skill-drift.sh — detect deployed skill(s) diverged from the kit source.
#
# Usage: verify-skill-drift.sh [--all | --harness <h>] [--home <dir>]
#   --all      check every harness registered in adapters.sh (RESEARCH_SDD_HARNESSES)
#              mutually exclusive with --harness; used by the SessionStart hook
#   --harness  single harness to check (default: claude)
#   --home     home dir used to resolve deployed skill paths (default: $HOME)
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

all_mode=0
harness="claude"
harness_set=0
home=""   # resolved after arg parsing; --home wins over $HOME

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
    -h|--help)
      sed -n '3,23p' "$0" | sed 's/^# \{0,1\}//'
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
    src="$KIT/$src_relkit"
    deployed="$(rsdd_field "$h" skill_path "$home")"

    # Source checks (could-not-run)
    if [ ! -f "$src" ] || [ ! -r "$src" ]; then
      err_count=$((err_count + 1))
      printf 'verify-skill-drift: could-not-run harness=%s (src missing: %s)\n' "$h" "$src" >&2
      continue
    fi

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
src="$KIT/$src_relkit"
deployed="$(rsdd_field "$harness" skill_path "$home")"

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
  exit 0  # in-sync — silent
fi

printf 'verify-skill-drift: diverged harness=%s deployed=%s\n' "$harness" "$deployed" >&2
exit 1
