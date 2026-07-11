#!/usr/bin/env bash
# serial-console.sh — DYNAMIC phase (METHODOLOGY §12): READ-ONLY serial/COM
# acquisition helper for a LIVE-INSTALL device reached over a serial port when
# SSH/Telnet are off and the network path fails. It drives a Windows
# `System.IO.Ports.SerialPort` from Windows PowerShell over WSL interop
# (open COM port → set baud → write ONE command → read the response) and
# PRESERVES the raw response under TARGET/sources/probes/ as [CERT-hw] evidence —
# same preservation discipline probe.sh/dynamic.sh use (same dir, same
# '# <name> run <ts>' header, same ts() helper), so blocks can cite what ran.
#
# Usage:
#   serial-console.sh list                                          # enumerate COM ports (PowerShell)
#   serial-console.sh check                                         # verify WSL→Windows interop is alive
#   serial-console.sh run <target-dir> <com-port> <baud> <command>  # send one READ command, preserve output
#
# The serial link is reached through Windows, not Linux: WSL has no /dev/ttyS
# for a host COM port, so we shell out to `powershell.exe` and let .NET own the
# port. Override the resolved binary with POWERSHELL_BIN (portability + tests).
#
# WSLInterop binfmt GOTCHA: if `powershell.exe` / `cmd.exe` fail with
# "exec format error", the WSLInterop binfmt_misc handler was dropped (a common
# casualty of `wsl --shutdown`, a systemd/binfmt race, or a docker-desktop
# restart). Re-register it from INSIDE WSL (root):
#   sudo sh -c 'echo :WSLInterop:M::MZ::/init:PF > /proc/sys/fs/binfmt_misc/register'
# (if a stale entry lingers, `echo -1 > /proc/sys/fs/binfmt_misc/WSLInterop` first).
# `serial-console.sh check` detects this and prints the fix instead of a false run.
#
# SAFETY (METHODOLOGY §12): the dynamic phase is read-first, write-supervised.
# This wrapper sends ONLY the single command you hand it — do NOT wire a
# config-changing / destructive command (or a reboot) through it without explicit
# user OK, and NEVER wire it into an autonomous loop. A bad serial command can
# brick a live device just as a bad network write can.
#
# EVIDENCE INTEGRITY: a "preserved: … [CERT-hw]" line is printed ONLY after the
# file is confirmed on disk AND the tee that wrote it succeeded. mkdir is
# exit-checked and every caller-derived path is passed after `--` so a
# dash-leading path can never be misparsed as an option. If preservation fails,
# the script emits an honest error and a non-zero exit — never a false citation.
#
# Exit codes: 0 ok · 2 bad args/validation · 3 interop/powershell absent (graceful
#             degrade) · 4 preservation setup failed (mkdir) · 5 run preservation
#             failed (tee/missing). On a successful RUN the exit mirrors PowerShell's
#             OWN exit code.
set -uo pipefail

ts()   { date -u +%Y%m%dT%H%M%SZ; }
have() { command -v "$1" >/dev/null 2>&1 || [ -x "$1" ]; }
# Reject a dash-leading value so mkdir/tee can never misparse a caller-supplied
# path as an option (belt to the `--` suspenders below).
no_dash() { case "$1" in -*) return 1 ;; *) return 0 ;; esac; }

POWERSHELL_BIN="${POWERSHELL_BIN:-powershell.exe}"

# Emit the binfmt re-registration hint (the WSLInterop gotcha) and return 3.
interop_absent() {
  echo "serial-console.sh: cannot reach Windows PowerShell ($POWERSHELL_BIN)." >&2
  echo "  If this is 'exec format error', WSLInterop binfmt_misc was dropped. Re-register (root, inside WSL):" >&2
  echo "    sudo sh -c 'echo :WSLInterop:M::MZ::/init:PF > /proc/sys/fs/binfmt_misc/register'" >&2
  echo "  (clear a stale handler first: echo -1 > /proc/sys/fs/binfmt_misc/WSLInterop)" >&2
  return 3
}

usage() {
  cat >&2 <<'EOF'
usage:
  serial-console.sh list
  serial-console.sh check
  serial-console.sh run <target-dir> <com-port> <baud> <command>
EOF
}

MODE="${1:-}"; [ -n "$MODE" ] || { usage; exit 2; }; shift

case "$MODE" in
  check)
    have "$POWERSHELL_BIN" || { interop_absent; exit 3; }
    # A trivial round-trip proves the interop handler actually executes the PE,
    # not just that the file exists on PATH.
    if out=$("$POWERSHELL_BIN" -NoProfile -Command 'Write-Output OK' 2>&1) && [ "${out%$'\r'}" = "OK" ]; then
      echo "interop: OK ($POWERSHELL_BIN reachable)"
      exit 0
    fi
    echo "serial-console.sh: powershell.exe present but did not execute cleanly:" >&2
    printf '  %s\n' "$out" >&2
    interop_absent; exit 3 ;;

  list)
    have "$POWERSHELL_BIN" || { interop_absent; exit 3; }
    echo "== COM ports (System.IO.Ports.SerialPort::GetPortNames) =="
    "$POWERSHELL_BIN" -NoProfile -Command '[System.IO.Ports.SerialPort]::GetPortNames()'
    exit "$?" ;;

  run)
    # run <target-dir> <com-port> <baud> <command>
    [ "$#" -eq 4 ] || { usage; exit 2; }
    TDIR="$1"; PORT="$2"; BAUD="$3"; CMD="$4"
    no_dash "$TDIR" || { echo "serial-console.sh: <target-dir> must not start with '-': $TDIR" >&2; exit 2; }
    case "$PORT" in COM[0-9]|COM[0-9][0-9]) ;; *) echo "serial-console.sh: <com-port> must be COM<N> (e.g. COM3): $PORT" >&2; exit 2 ;; esac
    case "$BAUD" in ''|*[!0-9]*) echo "serial-console.sh: <baud> must be numeric: $BAUD" >&2; exit 2 ;; esac
    [ -n "$CMD" ] || { echo "serial-console.sh: empty <command>" >&2; exit 2; }
    have "$POWERSHELL_BIN" || { interop_absent; exit 3; }

    OUTDIR="$TDIR/sources/probes"
    mkdir -p -- "$OUTDIR" || { echo "serial-console.sh: cannot create preservation dir: $OUTDIR" >&2; exit 4; }
    OUT="$OUTDIR/serial-$PORT-$(ts).txt"

    # Drive .NET's SerialPort from PowerShell: open, write ONE line, drain the
    # response, close. The port name / baud / command are passed as PowerShell
    # ARGS ($args[0..2]), never string-interpolated, so a quote/newline in the
    # command cannot break out of the script body.
    PS_SCRIPT='
$ErrorActionPreference = "Stop"
$name = $args[0]; $baud = [int]$args[1]; $cmd = $args[2]
$port = New-Object System.IO.Ports.SerialPort $name, $baud, ([System.IO.Ports.Parity]::None), 8, ([System.IO.Ports.StopBits]::One)
$port.ReadTimeout = 4000
$port.NewLine = "`n"
try {
  $port.Open()
  $port.WriteLine($cmd)
  Start-Sleep -Milliseconds 800
  Write-Output $port.ReadExisting()
} finally {
  if ($port.IsOpen) { $port.Close() }
}'
    echo "== serial run: [$PORT @ $BAUD] $CMD -> $OUT =="
    { echo "# serial-console run $(ts)"; echo "# port: $PORT  baud: $BAUD  cmd: $CMD"; echo "---"; \
      "$POWERSHELL_BIN" -NoProfile -Command "$PS_SCRIPT" "$PORT" "$BAUD" "$CMD" 2>&1; } | tee -- "$OUT"
    # Capture the pipeline's exit array in ONE statement: any prior assignment
    # would reset $PIPESTATUS to a 1-element array and make tee_rc a dead 0.
    st=("${PIPESTATUS[@]}"); ps_rc=${st[0]:-0}; tee_rc=${st[1]:-0}
    if [ "$tee_rc" -ne 0 ] || [ ! -f "$OUT" ]; then
      echo "serial-console.sh: preservation FAILED — no evidence written to $OUT (tee rc=$tee_rc)" >&2
      exit 5
    fi
    echo "---"
    echo "preserved: $OUT  (cite as [CERT-hw] evidence; rc=$ps_rc)"
    exit "$ps_rc" ;;

  *) echo "unknown mode: $MODE (list|check|run)" >&2; usage; exit 2 ;;
esac
