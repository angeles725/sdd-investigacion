#!/usr/bin/env bash
cat >/dev/null
n=$(( $(wc -l < /proc/net/dev) - 2 ))
i=0; s=""; while [ "$i" -lt "$n" ]; do s="${s}n"; i=$((i+1)); done
printf "%s" "$s"
