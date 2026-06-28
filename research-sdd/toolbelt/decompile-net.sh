#!/usr/bin/env bash
# decompile-net.sh — decompiles a .NET assembly (.dll/.exe) to C# with ilspycmd.
# For Siemens TIA Openness (api-openness, openness-labs/tools) and other managed binaries.
#
# Usage:
#   decompile-net.sh <in.dll|in.exe> <out-dir>          # full C# project
#   decompile-net.sh --list <in.dll>                    # list the assembly's types
#   decompile-net.sh --il <in.dll> <out-dir>            # dump IL instead of C#
set -euo pipefail

ILSPY="${ILSPYCMD:-/home/cristian/.dotnet/tools/ilspycmd}"
[ -x "$ILSPY" ] || { echo "ilspycmd not found at $ILSPY (install: dotnet tool install -g ilspycmd)" >&2; exit 3; }
# ilspycmd 8.2.0 targets net6.0; the system only has runtime 8 (net6 is EOL).
# Roll-forward to the highest available runtime instead of installing an old .NET.
export DOTNET_ROLL_FORWARD="${DOTNET_ROLL_FORWARD:-Major}"

case "${1:-}" in
  --list) exec "$ILSPY" --list-types "${2:?dll required}" ;;
  --il)   IN="${2:?dll}"; OUT="${3:?out-dir}"; mkdir -p "$OUT"; exec "$ILSPY" --il "$IN" -o "$OUT" ;;
esac

IN="${1:?usage: decompile-net.sh <in.dll|in.exe> <out-dir>}"
OUT="${2:?out-dir required}"
mkdir -p "$OUT"
# -p generates a navigable .csproj; without -p it dumps a single .cs
"$ILSPY" -p "$IN" -o "$OUT" || "$ILSPY" "$IN" -o "$OUT"
echo "OK: $IN -> $OUT  (ilspycmd)"
