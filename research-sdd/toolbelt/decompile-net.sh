#!/usr/bin/env bash
# decompile-net.sh — decompiles a .NET assembly (.dll/.exe) to C# with ilspycmd.
# For Siemens TIA Openness (api-openness, openness-labs/tools) and other managed binaries.
#
# Usage:
#   decompile-net.sh <in.dll|in.exe> <out-dir>          # full C# project
#   decompile-net.sh --list <in.dll>                    # list the assembly's types
#   decompile-net.sh --il <in.dll> <out-dir>            # dump IL instead of C#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/tool-env.sh
source "$HERE/lib/tool-env.sh"

ILSPY="$(rsdd_resolve_ilspy)" || { echo "ilspycmd not found (set ILSPYCMD, add to PATH, or: dotnet tool install -g ilspycmd)" >&2; exit 3; }
# Locate the .NET runtime for the ilspycmd apphost.
# ilspycmd is resolved via rsdd_resolve_ilspy (see lib/tool-env.sh).
# DOTNET_ROOT priority: RSDD_DOTNET_ROOT override → existing DOTNET_ROOT → derived from dotnet binary.
# Usability is validated by running ilspycmd --version with each candidate root; structural
# existence alone is not sufficient (an empty or too-old runtime dir causes apphost rc 131/150).

# _rsdd_dotnet_probe ROOT — return 0 iff ROOT is a usable ilspycmd runtime root.
# Pre-filter: shared/Microsoft.NETCore.App must exist (cheap structural check).
# Real gate: DOTNET_ROOT=ROOT ilspycmd --version exits 0 within RSDD_PROBE_TIMEOUT seconds.
_rsdd_dotnet_probe() {
  local root="$1" timeout_bin
  [ -d "$root/shared/Microsoft.NETCore.App" ] || return 1
  timeout_bin="$(command -v timeout 2>/dev/null || true)"
  if [ -x "${timeout_bin:-}" ]; then
    DOTNET_ROOT="$root" "$timeout_bin" "${RSDD_PROBE_TIMEOUT:-10}" "$ILSPY" --version >/dev/null 2>&1
  else
    DOTNET_ROOT="$root" "$ILSPY" --version >/dev/null 2>&1
  fi
}

_rsdd_dotnet_root() {
  local candidate dir parent dotnet_bin

  # RSDD_DOTNET_ROOT: kit's own explicit knob. Authoritative — if set but does not
  # probe clean, fail closed; do NOT fall through to a different runtime (mirrors
  # the *_JAR resolver discipline: "explicit override is authoritative; a typo must
  # never be silently masked by a fallback").
  if [ -n "${RSDD_DOTNET_ROOT:-}" ]; then
    if _rsdd_dotnet_probe "${RSDD_DOTNET_ROOT}"; then
      printf '%s\n' "${RSDD_DOTNET_ROOT}"; return 0
    fi
    echo "ERROR: RSDD_DOTNET_ROOT='${RSDD_DOTNET_ROOT}' is set but ilspycmd --version failed with it (usability probe failed). Fix or unset RSDD_DOTNET_ROOT." >&2
    return 1
  fi

  # Ambient DOTNET_ROOT (set by environment/distro, not the kit): try it, but allow
  # fall-through if the probe fails. This fixes silent shadowing by an old runtime
  # (e.g. /usr/lib/dotnet holding only .NET 8 when ilspycmd requires net10.0).
  if [ -n "${DOTNET_ROOT:-}" ]; then
    _rsdd_dotnet_probe "${DOTNET_ROOT}" && { printf '%s\n' "${DOTNET_ROOT}"; return 0; }
    # Fall through to derivation.
  fi

  # Derive from the dotnet binary on PATH.
  dotnet_bin="$(command -v dotnet 2>/dev/null || true)"
  [ -x "$dotnet_bin" ] || return 1
  dir="$(dirname "$(realpath "$dotnet_bin")")"
  parent="$(dirname "$dir")"
  # Check the binary directory first (stock/tarball installs place shared/ alongside dotnet).
  # Also check the libexec sibling (brew wraps dotnet from bin/ with the runtime in libexec/).
  for candidate in "$dir" "$parent/libexec"; do
    _rsdd_dotnet_probe "$candidate" && { printf '%s\n' "$candidate"; return 0; }
  done
  return 1
}
DOTNET_ROOT="$(_rsdd_dotnet_root)" || {
  echo "ERROR: DOTNET_ROOT could not be resolved. Set DOTNET_ROOT or RSDD_DOTNET_ROOT to the directory containing shared/Microsoft.NETCore.App, or ensure 'dotnet' is on PATH." >&2
  exit 3 # DOTNET_ROOT_UNRESOLVED
}
export DOTNET_ROOT
# DOTNET_ROLL_FORWARD=Major: kept for resilience if the installed runtime patch version
# differs from what ilspycmd targets; does not override an explicit caller-provided value.
export DOTNET_ROLL_FORWARD="${DOTNET_ROLL_FORWARD:-Major}"

case "${1:-}" in
  --list) exec "$ILSPY" -l c "${2:?dll required}" ;;
  --il)   IN="${2:?dll}"; OUT="${3:?out-dir}"; mkdir -p "$OUT"; exec "$ILSPY" --il "$IN" -o "$OUT" ;;
esac

IN="${1:?usage: decompile-net.sh <in.dll|in.exe> <out-dir>}"
OUT="${2:?out-dir required}"
mkdir -p "$OUT"
# -p generates a navigable .csproj; without -p it dumps a single .cs
"$ILSPY" -p "$IN" -o "$OUT" || "$ILSPY" "$IN" -o "$OUT"
echo "OK: $IN -> $OUT  (ilspycmd)"
