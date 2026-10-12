#!/usr/bin/env bash
# shim.sh — PATH shim for the kit-pr-pipeline suites. Symlinked as git / gh / gentle-ai / flock.
# Records every call to $SHIM_STATE/calls.log ("<name> <args>") and answers from $SHIM_STATE/rules.tsv:
#   name <TAB> arg-glob <TAB> rc <TAB> stdout-fixture|- <TAB> times|- <TAB> option|-
# The first rule whose name and glob match and whose `times` budget is not spent wins. stdout-fixture is a
# file under $SHIM_FIX. option `barrier=NAME:N`: touch a marker and wait until N shims sharing NAME ran at
# once (proves concurrent launches; a serial caller times out with rc 98). An unscripted call is rc 97, loud.
name="${0##*/}"
: "${SHIM_STATE:?SHIM_STATE unset}"
args="$*"
printf '%s %s\n' "$name" "$args" >> "$SHIM_STATE/calls.log"
i=0
if [ -f "$SHIM_STATE/rules.tsv" ]; then
  while IFS=$'\t' read -r rname pat rc out times opt; do
    i=$((i + 1))
    [ "$rname" = "$name" ] || continue
    # shellcheck disable=SC2053  # the pattern is a deliberate glob
    [[ "$args" == $pat ]] || continue
    hits=0
    [ -f "$SHIM_STATE/hit.$i" ] && hits="$(cat "$SHIM_STATE/hit.$i")"
    if [ "$times" != "-" ] && [ "$hits" -ge "$times" ]; then continue; fi
    echo $((hits + 1)) > "$SHIM_STATE/hit.$i"
    case "$opt" in
      barrier=*)
        key="${opt#barrier=}"; need="${key#*:}"; key="${key%%:*}"
        : > "$SHIM_STATE/barrier.$key.$$"
        n=0
        while [ "$(find "$SHIM_STATE" -maxdepth 1 -name "barrier.$key.*" | wc -l)" -lt "$need" ]; do
          n=$((n + 1))
          if [ "$n" -gt 50 ]; then echo "shim: barrier timeout (not concurrent)" >&2; exit 98; fi
          sleep 0.1
        done ;;
    esac
    if [ "$out" != "-" ]; then cat "$SHIM_FIX/$out"; fi
    exit "$rc"
  done < "$SHIM_STATE/rules.tsv"
fi
echo "shim: unscripted call: $name $args" >&2
exit 97
