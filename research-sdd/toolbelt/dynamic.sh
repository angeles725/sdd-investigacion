#!/usr/bin/env bash
# dynamic.sh — DYNAMIC phase (METHODOLOGY §12): Frida instrumentation wrapper for
# LINUX-NATIVE targets. Builds and runs frida-trace / frida CLI probes against a
# live process and PRESERVES their raw output (and, for a hook, the script.js that
# produced it) under TARGET/sources/probes/ as [CERT-hw] evidence — the same
# preservation discipline probe.sh uses (same dir, same '# <name> run <ts>' header,
# same ts() helper), so blocks can cite what actually ran.
#
# Usage:
#   dynamic.sh frida-trace <target> <-i FUNC | -I MODULE> [frida-trace args...] <target-dir>
#   dynamic.sh frida-hook  <target> <script.js> <target-dir>
#   dynamic.sh boilerplate [func] [module]      # print an Interceptor.attach skeleton to stdout
#
# <target> is a Linux-native process name or pid. frida is a pipx/venv tool and is
# NOT assumed present: if the frida binary is absent, the RUN degrades gracefully
# (clear "install: install-tool.sh frida" hint + non-zero exit) instead of pretending
# it ran — but for frida-hook the script.js is preserved FIRST, independently.
# Override the resolved binaries with FRIDA_BIN / FRIDA_TRACE_BIN (portability + tests).
#
# EVIDENCE INTEGRITY: a "preserved: … [CERT-hw]" line is printed ONLY after the file
# is confirmed on disk. Every preservation step (mkdir/cp/tee) is exit-checked and
# every caller-derived path is passed after `--` so a dash-leading path can never be
# misparsed as an option. Filenames carry the PID so concurrent runs never overwrite
# each other's evidence. If preservation fails, the script emits an honest error and
# a non-zero exit — never a false citation.
#
# Exit codes: 0 ok · 2 bad args/validation · 3 frida absent (graceful degrade) ·
#             4 preservation setup failed (mkdir/cp) · 5 run preservation failed (tee/missing).
#             On SUCCESS the exit mirrors the wrapped tool's OWN exit code, which may
#             coincide with the wrapper's reserved 2-5 (a preserved [CERT-hw] log was
#             still written — read the 'preserved:'/'sha256(' lines, not just $?).
#
# SAFETY (METHODOLOGY §12): the dynamic phase is read-first, write-supervised. This
# wrapper only runs the frida script you hand it — do NOT wire a writing/destructive
# hook through it, and NEVER wire it into an autonomous loop. A bad hook can corrupt
# a live process's state.
set -uo pipefail

ts()        { date -u +%Y%m%dT%H%M%SZ; }
have()      { command -v "$1" >/dev/null 2>&1 || [ -x "$1" ]; }
sha256_of() { sha256sum -- "$1" | cut -d' ' -f1; }

# Reject a dash-leading value so mkdir/cp/tee/sha256sum can never misparse a
# caller-supplied path as an option (belt to the `--` suspenders below).
no_dash() { case "$1" in -*) return 1 ;; *) return 0 ;; esac; }
# A safe JS identifier for the boilerplate literals: letters/digits/_ . : $ - only,
# so an injected quote/newline can't break out of the single-quoted JS string.
# Bracket ordering is load-bearing: '-' is LEADING (literal range char, not a range),
# and '$' sits just before ']' so it stays literal instead of expanding as $- (the
# shell option-flags parameter) — otherwise legit '-'/'$' idents get rejected.
safe_ident() { case "$1" in ''|*[!-A-Za-z0-9_.:$]*) return 1 ;; *) return 0 ;; esac; }

FRIDA_BIN="${FRIDA_BIN:-frida}"
FRIDA_TRACE_BIN="${FRIDA_TRACE_BIN:-frida-trace}"

usage() {
  cat >&2 <<'EOF'
usage:
  dynamic.sh frida-trace <target> <-i FUNC | -I MODULE> [frida-trace args...] <target-dir>
  dynamic.sh frida-hook  <target> <script.js> <target-dir>
  dynamic.sh boilerplate [func] [module]
EOF
}

SUB="${1:-}"; [ -n "$SUB" ] || { usage; exit 2; }; shift

case "$SUB" in
  boilerplate)
    # Pure, deterministic scaffold. A user redirects this into a script.js and fills
    # in the specifics, then runs it via `dynamic.sh frida-hook`.
    FUNC="${1:-FUNCTION_NAME}"
    MODULE="${2:-}"
    safe_ident "$FUNC" || { echo "dynamic.sh: invalid func name (allowed: A-Za-z0-9_.:\$-): $FUNC" >&2; exit 2; }
    if [ -n "$MODULE" ]; then
      safe_ident "$MODULE" || { echo "dynamic.sh: invalid module name (allowed: A-Za-z0-9_.:\$-): $MODULE" >&2; exit 2; }
      MODARG="'$MODULE'"
    else
      MODARG="null"
    fi
    cat <<EOF
// Frida Interceptor skeleton — fill in the specifics, then run:
//   dynamic.sh frida-hook <target> <this-file.js> <target-dir>
// MODULE null = search every loaded module for the export.
const addr = Module.getExportByName($MODARG, '$FUNC');
Interceptor.attach(addr, {
  onEnter(args) {
    // dump incoming args (adjust count/types to the real signature)
    console.log('[+] $FUNC onEnter');
    console.log('    arg0 =', args[0]);
    console.log('    arg1 =', args[1]);
    this.t0 = Date.now();
  },
  onLeave(retval) {
    // dump (and optionally rewrite) the return value
    console.log('[+] $FUNC onLeave -> retval =', retval, '(' + (Date.now() - this.t0) + 'ms)');
  }
});
EOF
    exit 0 ;;

  frida-hook)
    # frida-hook <target> <script.js> <target-dir>
    [ "$#" -eq 3 ] || { usage; exit 2; }
    TARGET="$1"; SCRIPT="$2"; TDIR="$3"
    [ -n "$TARGET" ]    || { echo "dynamic.sh: empty <target>" >&2; exit 2; }
    no_dash "$TARGET"   || { echo "dynamic.sh: <target> must not start with '-': $TARGET" >&2; exit 2; }
    no_dash "$SCRIPT"   || { echo "dynamic.sh: <script.js> must not start with '-': $SCRIPT" >&2; exit 2; }
    no_dash "$TDIR"     || { echo "dynamic.sh: <target-dir> must not start with '-': $TDIR" >&2; exit 2; }
    [ -f "$SCRIPT" ]    || { echo "dynamic.sh: script not found: $SCRIPT" >&2; exit 2; }
    OUTDIR="$TDIR/sources/probes"
    mkdir -p -- "$OUTDIR" || { echo "dynamic.sh: cannot create preservation dir: $OUTDIR" >&2; exit 4; }
    # Preserve the reproduction recipe (the script.js) BEFORE any frida check —
    # per §12 "preserve the probe that produced it"; this must happen even on degrade.
    # PID in the name so concurrent runs never overwrite each other's evidence.
    SCRIPT_COPY="$OUTDIR/$(basename -- "$SCRIPT" .js)-$(ts)-$$.js"
    cp -- "$SCRIPT" "$SCRIPT_COPY" || { echo "dynamic.sh: failed to preserve script: $SCRIPT -> $SCRIPT_COPY" >&2; exit 4; }
    [ -f "$SCRIPT_COPY" ] || { echo "dynamic.sh: script copy missing after cp: $SCRIPT_COPY" >&2; exit 4; }
    echo "preserved script: $SCRIPT_COPY  sha256=$(sha256_of "$SCRIPT_COPY")"
    if ! have "$FRIDA_BIN"; then
      echo "frida not found — install: install-tool.sh frida" >&2
      exit 3
    fi
    OUT="$OUTDIR/frida-hook-$(ts)-$$.log"
    echo "== frida-hook: $FRIDA_BIN -l $SCRIPT_COPY $TARGET -> $OUT =="
    { echo "# frida-hook run $(ts)"; echo "# cmd: $FRIDA_BIN -l $SCRIPT_COPY $TARGET"; echo "---"; \
      "$FRIDA_BIN" -l "$SCRIPT_COPY" "$TARGET" 2>&1; } | tee -- "$OUT"
    # Capture the pipeline's exit array in ONE statement: any prior assignment would
    # reset $PIPESTATUS to a 1-element array and make tee_rc a dead constant 0.
    st=("${PIPESTATUS[@]}"); frida_rc=${st[0]:-0}; tee_rc=${st[1]:-0}
    if [ "$tee_rc" -ne 0 ] || [ ! -f "$OUT" ]; then
      echo "dynamic.sh: preservation FAILED — no evidence written to $OUT (tee rc=$tee_rc)" >&2
      exit 5
    fi
    echo "---"
    echo "preserved: $OUT  (cite as [CERT-hw] evidence; rc=$frida_rc)"
    echo "sha256($OUT)=$(sha256_of "$OUT")"
    echo "sha256($SCRIPT_COPY)=$(sha256_of "$SCRIPT_COPY")"
    exit "$frida_rc" ;;

  frida-trace)
    # frida-trace <target> <-i FUNC | -I MODULE> [args...] <target-dir>
    # target = first arg, target-dir = LAST arg, everything between = frida-trace args.
    [ "$#" -ge 3 ] || { usage; exit 2; }
    TARGET="$1"; shift
    [ -n "$TARGET" ]  || { echo "dynamic.sh: empty <target>" >&2; exit 2; }
    no_dash "$TARGET" || { echo "dynamic.sh: <target> must not start with '-': $TARGET" >&2; exit 2; }
    ARGS=("$@")
    n=${#ARGS[@]}
    TDIR="${ARGS[$((n-1))]}"
    unset 'ARGS[n-1]'
    FARGS=("${ARGS[@]}")   # frida-trace args (must include a selector WITH a value)
    no_dash "$TDIR" || { echo "dynamic.sh: <target-dir> must not start with '-': $TDIR" >&2; exit 2; }
    # A selector must carry its value. A bare -i/-I needs the NEXT element inside
    # FARGS; if it is the LAST element, its value was eaten by the target-dir slice
    # (the `frida-trace T -i D` 3-arg ambiguity) — refuse rather than silently drop
    # the real target and false-succeed. Combined -iFUNC / -IMODULE already carry it.
    HAS_VALUED_SEL=0; nf=${#FARGS[@]}; i=0
    while [ "$i" -lt "$nf" ]; do
      case "${FARGS[$i]}" in
        -i|-I)
          if [ "$((i+1))" -lt "$nf" ]; then HAS_VALUED_SEL=1; i=$((i+2)); continue
          else
            echo "dynamic.sh: ambiguous / not enough args: ${FARGS[$i]} needs a value" >&2
            echo "usage: dynamic.sh frida-trace <target> -i <func> <target-dir>" >&2
            exit 2
          fi ;;
        -i?*|-I?*) HAS_VALUED_SEL=1 ;;
      esac
      i=$((i+1))
    done
    [ "$HAS_VALUED_SEL" -eq 1 ] || { echo "dynamic.sh: frida-trace needs -i FUNC or -I MODULE" >&2; usage; exit 2; }
    OUTDIR="$TDIR/sources/probes"
    OUT="$OUTDIR/frida-trace-$(ts)-$$.log"
    if ! have "$FRIDA_TRACE_BIN"; then
      echo "frida-trace not found — install: install-tool.sh frida" >&2
      echo "intended output: $OUT"
      exit 3
    fi
    mkdir -p -- "$OUTDIR" || { echo "dynamic.sh: cannot create preservation dir: $OUTDIR" >&2; exit 4; }
    echo "== frida-trace: $FRIDA_TRACE_BIN ${FARGS[*]} $TARGET -> $OUT =="
    { echo "# frida-trace run $(ts)"; echo "# cmd: $FRIDA_TRACE_BIN ${FARGS[*]} $TARGET"; echo "---"; \
      "$FRIDA_TRACE_BIN" "${FARGS[@]}" "$TARGET" 2>&1; } | tee -- "$OUT"
    # Capture the pipeline's exit array in ONE statement (see frida-hook note).
    st=("${PIPESTATUS[@]}"); frida_rc=${st[0]:-0}; tee_rc=${st[1]:-0}
    if [ "$tee_rc" -ne 0 ] || [ ! -f "$OUT" ]; then
      echo "dynamic.sh: preservation FAILED — no evidence written to $OUT (tee rc=$tee_rc)" >&2
      exit 5
    fi
    echo "---"
    echo "preserved: $OUT  (cite as [CERT-hw] evidence; rc=$frida_rc)"
    echo "sha256($OUT)=$(sha256_of "$OUT")"
    exit "$frida_rc" ;;

  *) echo "unknown subcommand: $SUB (frida-trace|frida-hook|boilerplate)" >&2; usage; exit 2 ;;
esac
