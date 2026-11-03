#!/usr/bin/env bash
# Stub decompiler wrapper for the java-fidelity parity cases; <Class>.mode beside it picks the behaviour.
in="$1"; out="$2"; name="$(basename "$in" .class)"; here="$(dirname "$0")"
mode="$(cat "$here/$name.mode" 2>/dev/null || echo copy)"
text="$(cat "$in")"; src="${text#src:}"; src="${src%%$'\n'*}"
mkdir -p "$out"
case "$mode" in
  copy)     printf '%s\n' "$src" > "$out/$name.java"; echo "OK: $in -> $out (engine=stub)" ;;
  diverge)  printf '%s\n' "${src/+ 1/+ 2}" > "$out/$name.java"; echo "OK: $in -> $out (engine=stub)" ;;
  broken)   printf 'class %s { SYNTAX }\n' "$name" > "$out/$name.java"; echo "OK: $in -> $out (engine=stub)" ;;
  fail)     echo "boom" >&2; exit 1 ;;
  none)     echo "OK: $in -> $out (engine=stub)" ;;
  missing)  echo "no engine" >&2; exit 3 ;;
  fallback) printf '%s\n' "$src" > "$out/$name.java"; echo "DEGRADED: $in -> $out  (engine=stub units=1 primary=error)"; echo "UNIT: $name reason=error fallback=cfr result=ok"; exit 4 ;;
  hang)     exec sleep 30 ;;
esac
