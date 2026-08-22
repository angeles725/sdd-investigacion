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
# rsdd_resolve_dotnet_root (lib/tool-env.sh) is the single source of truth for this logic;
# decompile-net.sh and detect-tools.sh both use it so the resolution is DRY.
# DOTNET_ROOT priority: RSDD_DOTNET_ROOT override → ambient DOTNET_ROOT → derived from dotnet binary.
# Usability is validated by running ilspycmd --version with each candidate root; structural
# existence alone is not sufficient (an empty or too-old runtime dir causes apphost rc 131/150).
DOTNET_ROOT="$(rsdd_resolve_dotnet_root "$ILSPY")" || {
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
