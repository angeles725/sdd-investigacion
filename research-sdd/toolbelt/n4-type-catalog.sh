#!/usr/bin/env bash
# n4-type-catalog.sh — static catalog of Slotomatic slot declarations (n4-type-catalog.v1).
# Wrapper around n4_type_catalog.py (python3, stdlib only). See n4-type-catalog.v1.md.
set -euo pipefail
HERE="${BASH_SOURCE[0]%/*}"
HERE="$(cd "$HERE" && pwd)"
# Runtime-dependency probe (CLAUDE.md §7): a missing interpreter is a typed degraded state, never a silent pass.
if ! command -v python3 >/dev/null 2>&1; then
  echo "n4-type-catalog: degraded — python3 not found; no catalog produced" >&2
  exit 2
fi
exec python3 "$HERE/n4_type_catalog.py" "$@"
