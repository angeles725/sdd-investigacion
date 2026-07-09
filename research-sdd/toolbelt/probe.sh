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
# EVIDENCE INTEGRITY: a "preserved: … [CERT-hw]" line is printed ONLY after the file
# is confirmed on disk AND the tee that wrote it succeeded. mkdir is exit-checked and
# every caller-derived path is passed after `--` so a dash-leading path can never be
# misparsed as an option. If preservation fails, the script emits an honest error and
# a non-zero exit — never a false citation.
#
# Exit codes: 0 ok · 2 bad args/validation · 4 preservation setup failed (mkdir) ·
#             5 run preservation failed (tee/missing). On SUCCESS the exit mirrors the
#             wrapped probe's OWN exit code.
set -uo pipefail

ts() { date -u +%Y%m%dT%H%M%SZ; }
# Reject a dash-leading value so mkdir/tee can never misparse a caller-supplied
# path as an option (belt to the `--` suspenders below).
no_dash() { case "$1" in -*) return 1 ;; *) return 0 ;; esac; }

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
    no_dash "$TDIR" || { echo "probe.sh: <target-dir> must not start with '-': $TDIR" >&2; exit 2; }
    OUTDIR="$TDIR/sources/probes"
    mkdir -p -- "$OUTDIR" || { echo "probe.sh: cannot create preservation dir: $OUTDIR" >&2; exit 4; }
    NAME="$(basename "${1%% *}" | sed 's/[^A-Za-z0-9._-]/_/g')"
    OUT="$OUTDIR/${NAME%.*}-$(ts).txt"
    echo "== probe: $* -> $OUT =="
    # Tee raw stdout+stderr to the preserved evidence file AND the console.
    { echo "# probe run $(ts)"; echo "# cmd: $*"; echo "---"; "$@" 2>&1; } | tee -- "$OUT"
    # Capture the pipeline's exit array in ONE statement: any prior assignment would
    # reset $PIPESTATUS to a 1-element array and make tee_rc a dead constant 0.
    # PIPESTATUS[0] is the brace group (the probe), PIPESTATUS[1] is tee.
    st=("${PIPESTATUS[@]}"); cmd_rc=${st[0]:-0}; tee_rc=${st[1]:-0}
    if [ "$tee_rc" -ne 0 ] || [ ! -f "$OUT" ]; then
      echo "probe.sh: preservation FAILED — no evidence written to $OUT (tee rc=$tee_rc)" >&2
      exit 5
    fi
    echo "---"
    echo "preserved: $OUT  (cite as [CERT-hw] evidence; rc=$cmd_rc)"
    exit "$cmd_rc"
    ;;
  *) echo "unknown mode: $MODE (check|run)" >&2; exit 2 ;;
esac
