#!/usr/bin/env bash
# verify-skill-drift.sh — detect a deployed skill diverged from the kit source.
#
# Usage: verify-skill-drift.sh [--harness <h>] [--home <dir>]
#   --harness  harness to check (default: claude; must be registered in adapters.sh)
#   --home     home dir used to resolve the deployed skill path (default: $HOME)
#
# Exit codes (§7 three-state guarantee — always distinguishable):
#   0  in-sync      deployed SKILL.md matches kit source byte-for-byte (SILENT)
#   1  diverged     deployed SKILL.md differs from kit source
#   2  could-not-run adapters.sh/kit source missing or unreadable; harness unknown
#   3  absent       no deployed skill found (harness not installed / never run)
#
# On any non-zero exit a single typed line is emitted to STDERR for logging;
# stdout is reserved for the hook message (consumed by verify-skill-drift-hook.sh).
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

harness="claude"
home="$HOME"
while [ $# -gt 0 ]; do
  case "$1" in
    --harness) harness="${2:-}"; shift 2 ;;
    --home)    home="${2:-}"; shift 2 ;;
    -h|--help)
      sed -n '3,18p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) printf 'verify-skill-drift: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

# Validate harness: rsdd_field exits 2 on unknown harness
if ! rsdd_field "$harness" config_root "$home" >/dev/null 2>&1; then
  printf 'verify-skill-drift: ERROR: unknown harness "%s"\n' "$harness" >&2
  exit 2
fi

src_relkit="$(rsdd_field "$harness" skill_src_relkit)"
KIT="$(cd "$KIT_INSTALL/.." && pwd)"
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

# Deployed file checks (absent = exit 3; not-regular = could-not-run)
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
