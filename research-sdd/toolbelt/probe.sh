#!/usr/bin/env bash
# probe.sh — DYNAMIC phase (METHODOLOGY §12): run a READ-ONLY probe against a
# live system and PRESERVE its raw output as [CERT-hw] evidence under
# TARGET/sources/probes/. The probe itself (a port of the decompiled protocol)
# is the caller's; this wrapper runs it, timestamps and preserves the output so
# blocks can cite it.
#
# Usage:
#   probe.sh check <ip> <port> [port...]                 # TCP reachability (no data sent)
#   probe.sh run <target-dir> <probe-cmd> [args...]      # run probe, preserve raw output
#
# SAFETY (METHODOLOGY §12): the dynamic phase is read-first, write-supervised.
# This wrapper only runs what you pass it — do NOT wire destructive/writing probes
# through it without explicit user approval. A bad write can brick a real device.
set -uo pipefail

ts() { date -u +%Y%m%dT%H%M%SZ; }

MODE="${1:?usage: probe.sh check <ip> <port...> | run <target-dir> <probe-cmd> [args...]}"; shift

case "$MODE" in
  check)
    IP="${1:?ip}"; shift
    [ "$#" -gt 0 ] || { echo "usage: probe.sh check <ip> <port...>" >&2; exit 2; }
    echo "== reachability $IP =="
    for p in "$@"; do
      timeout 3 bash -c "echo > /dev/tcp/$IP/$p" 2>/dev/null \
        && echo "  $p: OPEN" || echo "  $p: closed/unreachable"
    done
    ping -c1 -W2 "$IP" >/dev/null 2>&1 && echo "  ping: OK" || echo "  ping: no reply"
    ;;
  run)
    TDIR="${1:?target-dir}"; shift
    [ "$#" -gt 0 ] || { echo "usage: probe.sh run <target-dir> <probe-cmd> [args...]" >&2; exit 2; }
    OUTDIR="$TDIR/sources/probes"; mkdir -p "$OUTDIR"
    NAME="$(basename "${1%% *}" | sed 's/[^A-Za-z0-9._-]/_/g')"
    OUT="$OUTDIR/${NAME%.*}-$(ts).txt"
    echo "== probe: $* -> $OUT =="
    # Tee raw stdout+stderr to the preserved evidence file AND the console.
    { echo "# probe run $(ts)"; echo "# cmd: $*"; echo "---"; "$@" 2>&1; } | tee "$OUT"
    rc=${PIPESTATUS[0]:-0}
    echo "---"
    echo "preserved: $OUT  (cite as [CERT-hw] evidence; rc=$rc)"
    exit "$rc"
    ;;
  *) echo "unknown mode: $MODE (check|run)" >&2; exit 2 ;;
esac
