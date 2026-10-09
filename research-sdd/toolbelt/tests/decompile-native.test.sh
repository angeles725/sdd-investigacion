#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; SOURCE="$HERE/../decompile-native.sh"
[ -x "$SOURCE" ] || { echo "FATAL: SUT not found: $SOURCE" >&2; exit 2; }
ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT; pass=0; fail=0
ok(){ echo "  PASS  $1"; pass=$((pass+1)); }; no(){ echo "  FAIL  $1"; fail=$((fail+1)); }
mkdir -p "$ROOT/toolbelt/lib" "$ROOT/gh/support" "$ROOT/jdk" "$ROOT/bin" "$ROOT/out"
cp "$SOURCE" "$ROOT/toolbelt/decompile-native.sh"
cat >"$ROOT/toolbelt/lib/tool-env.sh" <<'SH'
rsdd_resolve_java_home(){ printf '%s\n' "$TEST_ROOT/jdk"; }
rsdd_resolve_ghidra_home(){ printf '%s\n' "$TEST_ROOT/gh"; }
rsdd_resolve_r2(){ printf '%s\n' "$TEST_ROOT/bin/r2"; }
SH
cat >"$ROOT/toolbelt/corroborate-ghidra.sh" <<'SH'
#!/bin/sh
printf '%s\n' "$@" >"$RECORD"
SH
cat >"$ROOT/gh/support/analyzeHeadless" <<'SH'
#!/bin/sh
printf '%s\n' "$@" >"$RECORD"
# Simulate a real Ghidra import: create a program entry (depth >= 2) inside the project dir
# ($1), which is what analyzeHeadless produces when it actually imports a binary.
# HEADLESS_EMPTY=1 suppresses this to test the non-empty-output guard.
[ "${HEADLESS_EMPTY:-0}" = "1" ] || { mkdir -p "$1/ghidraproj.rep/00"; touch "$1/ghidraproj.rep/00/content.prp"; }
SH
cat >"$ROOT/bin/r2" <<'SH'
#!/bin/sh
printf '%s\n' "$@" >"$RECORD"
SH
chmod +x "$ROOT/toolbelt/corroborate-ghidra.sh" "$ROOT/gh/support/analyzeHeadless" "$ROOT/bin/r2"
SUT="$ROOT/toolbelt/decompile-native.sh"; INPUT="$ROOT/input with spaces.bin"; : >"$INPUT"

if TEST_ROOT="$ROOT" RECORD="$ROOT/evidence.args" "$SUT" ghidra-evidence "$INPUT" "$ROOT/out/evidence" \
  && [ "$(sed -n '1p' "$ROOT/evidence.args")" = --input ] && [ "$(sed -n '2p' "$ROOT/evidence.args")" = "$INPUT" ] \
  && [ "$(sed -n '3p' "$ROOT/evidence.args")" = --output ] && [ "$(sed -n '4p' "$ROOT/evidence.args")" = "$ROOT/out/evidence" ] \
  && [ "$(wc -l <"$ROOT/evidence.args")" -eq 4 ]; then ok 'evidence route forwards only safe input/output arguments'; else no 'evidence route forwarding'; fi
rm "$ROOT/toolbelt/corroborate-ghidra.sh"
TEST_ROOT="$ROOT" "$SUT" ghidra-evidence "$INPUT" "$ROOT/out/missing" 2>"$ROOT/missing.err"; rc=$?
if [ "$rc" -eq 3 ] && grep -q 'evidence adapter not found' "$ROOT/missing.err"; then ok 'missing evidence adapter fails explicitly'; else no 'missing adapter failure'; fi
if TEST_ROOT="$ROOT" RECORD="$ROOT/raw.args" "$SUT" ghidra "$INPUT" "$ROOT/out/raw" \
  && grep -Fxq -- '-import' "$ROOT/raw.args" && grep -Fxq -- "$INPUT" "$ROOT/raw.args"; then ok 'raw ghidra mode remains distinct'; else no 'raw ghidra mode'; fi
# B2 — Ghidra project dir must NOT start with a dot (Ghidra 12.1.2 rejects leading-dot path elements).
# The project dir is the FIRST argument to analyzeHeadless (from raw.args, line 1).
_proj_dir="$(head -1 "$ROOT/raw.args" 2>/dev/null)"
_proj_base="${_proj_dir##*/}"   # basename via parameter expansion (no external command — safe inside clean-PATH teeth run)
if [ "${_proj_base:-x}" = "ghidra-proj" ]; then
  ok "B2: ghidra project dir is 'ghidra-proj' (no leading dot — Ghidra 12.1.2 rejects dots)"
else
  no "B2: ghidra project dir is '${_proj_base:-<empty>}' (want 'ghidra-proj', not '.ghidra-proj')"
fi
# B3 — caller script dir must be on -scriptPath; -postScript must receive the basename only.
# Ghidra headless resolves -postScript by NAME against -scriptPath (analyzeHeadlessREADME.md
# §-postScript); passing a full path silently fails (script not found under that bare name).
# The separator for multiple -scriptPath directories is ';' (analyzeHeadlessREADME.md §-scriptPath).
mkdir -p "$ROOT/scripts"
: >"$ROOT/scripts/MyScript.java"
if TEST_ROOT="$ROOT" RECORD="$ROOT/b3.args" "$SUT" ghidra "$INPUT" "$ROOT/out/b3" --script "$ROOT/scripts/MyScript.java"; then
  if [ ! -s "$ROOT/b3.args" ]; then
    no "B3: analyzeHeadless stub not invoked (b3.args is absent or empty)"
  else
    _ps_val="$(sed -n '/^-postScript$/{n; p; q}' "$ROOT/b3.args")"
    _sp_val="$(sed -n '/^-scriptPath$/{n; p; q}' "$ROOT/b3.args")"
    if [ "$_ps_val" = "MyScript.java" ] \
      && <<<"$_sp_val" grep -Fq -- "$ROOT/scripts"; then
      ok "B3: -postScript gets basename; caller dir is on -scriptPath"
    else
      no "B3: -postScript='$_ps_val' -scriptPath='$_sp_val' (want basename + caller dir)"
    fi
  fi
else
  no "B3: ghidra --script invocation failed"
fi
# N1 — Ghidra exits 0 but writes no files to PROJ → must not print OK, exit non-zero.
# Controlled via HEADLESS_EMPTY=1: the analyzeHeadless stub skips the project.gpr sentinel
# when this variable is set. Without it (normal runs), the stub creates the sentinel so that
# the non-empty guard passes and existing tests are unaffected.
HEADLESS_EMPTY=1 TEST_ROOT="$ROOT" RECORD="$ROOT/n1.args" "$SUT" ghidra "$INPUT" "$ROOT/out/n1" \
  >"$ROOT/n1.out" 2>"$ROOT/n1.err"; _n1rc=$?
if [ "$_n1rc" -ne 0 ] && ! grep -q '^OK' "$ROOT/n1.out"; then
  ok "N1: Ghidra exits 0 + empty PROJ → wrapper exits non-zero, no OK"
else
  no "N1: Ghidra exits 0 + empty PROJ → must exit non-zero (got rc=$_n1rc)"
fi
if TEST_ROOT="$ROOT" PATH="$ROOT/bin:$PATH" RECORD="$ROOT/r2.args" "$SUT" r2 "$INPUT" \
  && grep -Fxq -- "$INPUT" "$ROOT/r2.args"; then ok 'r2 mode still dispatches'; else no 'r2 mode'; fi
# R2-brew: brew-only r2 — SUT must invoke the path returned by rsdd_resolve_r2, not bare r2.
# Use a separate SUT copy whose stub tool-env.sh returns a brew-style path (r2-brew binary).
mkdir -p "$ROOT/toolbelt-b2/lib" "$ROOT/toolbelt-b2/tests"
cp "$ROOT/toolbelt/decompile-native.sh" "$ROOT/toolbelt-b2/decompile-native.sh"
cat >"$ROOT/toolbelt-b2/lib/tool-env.sh" <<'SH'
rsdd_resolve_java_home(){ printf '%s\n' "$TEST_ROOT/jdk"; }
rsdd_resolve_ghidra_home(){ printf '%s\n' "$TEST_ROOT/gh"; }
rsdd_resolve_r2(){ printf '%s\n' "$TEST_ROOT/bin/r2-brew"; }
SH
cat >"$ROOT/bin/r2-brew" <<'SH'
#!/bin/sh
printf '%s\n' "$@" >"$RECORD"
SH
chmod +x "$ROOT/bin/r2-brew"
_sut_b2="$ROOT/toolbelt-b2/decompile-native.sh"
if TEST_ROOT="$ROOT" RECORD="$ROOT/r2-brew.args" "$_sut_b2" r2 "$INPUT" \
   && grep -Fxq -- "$INPUT" "$ROOT/r2-brew.args"; then
  ok 'R2-brew: SUT invokes rsdd_resolve_r2 brew result, not bare r2'
else
  no 'R2-brew: SUT invokes rsdd_resolve_r2 brew result, not bare r2'
fi
if ! command -v file >/dev/null 2>&1 || ! command -v strings >/dev/null 2>&1; then
  echo "  SKIP  quick mode (missing: file or strings)"
else
  if "$SOURCE" quick /bin/true >/dev/null; then ok 'quick mode still dispatches'; else no 'quick mode'; fi
fi

# Q2 — large strings output: quick mode must exit 0 when strings produces >40 lines.
# A 100-string synthetic binary causes head to close the pipe after 40 lines, sending
# SIGPIPE to strings.  The unpatched SUT (bare pipeline + set -euo pipefail) exits 141;
# the patched SUT exits 0.  Fixture generated at runtime — no binary committed.
if ! command -v file >/dev/null 2>&1 || ! command -v strings >/dev/null 2>&1; then
  echo "  SKIP  Q2 large-strings (missing: file or strings)"
else
  _big="$ROOT/big.bin"
  # Each string is ~2010 chars; 100 strings ≈ 200 KB >> 64 KB pipe buffer.
  # strings -n 6 produces 100 output lines; head closes the pipe after 40,
  # triggering SIGPIPE on strings before it finishes writing.
  awk 'BEGIN{s=sprintf("%2000s","");gsub(/ /,"A",s);for(i=1;i<=100;i++)printf "LONGSTR%04d%s\n",i,s}' >"$_big"
  # Stub readelf to exit 0 so the test isolates the strings SIGPIPE path only.
  # Without this, the readelf PIPESTATUS guard surfaces readelf's non-zero exit on
  # the synthetic non-ELF file, which is correct behaviour but not what Q2 tests.
  _q2_stubdir="$ROOT/q2stubs"; mkdir -p "$_q2_stubdir"
  printf '#!/bin/sh\nexit 0\n' >"$_q2_stubdir/readelf"; chmod +x "$_q2_stubdir/readelf"
  if PATH="$_q2_stubdir:$PATH" "$SOURCE" quick "$_big" >"$ROOT/q2.out" 2>&1; then
    if grep -q 'LONGSTR' "$ROOT/q2.out"; then
      ok "Q2: quick exits 0 and emits strings section when output exceeds 40 lines"
    else
      no "Q2: quick exits 0 but strings section absent from output"
    fi
  else
    no "Q2: quick exits non-zero (want 0) — SIGPIPE not handled in strings pipeline"
  fi
fi

# Q3 — genuine strings failure must NOT be silently swallowed.
# A stub strings that exits 1 simulates a binary that cannot be opened.
# The proper fix surfaces this (non-zero rc or explicit diagnostic); a blanket
# '|| true' fix swallows it silently.  Mutation M10 below confirms Q3 catches that.
if ! command -v file >/dev/null 2>&1; then
  echo "  SKIP  Q3 strings-failure (missing: file)"
else
  _stubdir="$ROOT/stubstrings"
  mkdir -p "$_stubdir"
  printf '#!/bin/sh\necho "strings: stub: cannot open" >&2\nexit 1\n' >"$_stubdir/strings"
  chmod +x "$_stubdir/strings"
  PATH="$_stubdir:$PATH" "$SOURCE" quick /bin/true >"$ROOT/q3.out" 2>"$ROOT/q3.err"; _q3rc=$?
  if [ "$_q3rc" -ne 0 ] || grep -q 'strings failed' "$ROOT/q3.err"; then
    ok "Q3: genuine strings failure surfaces (rc=$_q3rc, not silently swallowed)"
  else
    no "Q3: genuine strings failure silently swallowed (rc=0, no diagnostic)"
  fi
fi

# Q4 — genuine readelf failure must NOT be silently swallowed.
# A stub readelf that exits 2 simulates a binary that cannot be analyzed.
# The proper fix surfaces this (non-zero rc or explicit diagnostic); a blanket
# '|| true' fix swallows it silently.  Mutation M11 below confirms Q4 catches that.
if ! command -v file >/dev/null 2>&1; then
  echo "  SKIP  Q4 readelf-failure (missing: file)"
else
  _stubdir_q4="$ROOT/stubreadelf"
  mkdir -p "$_stubdir_q4"
  printf '#!/bin/sh\necho "readelf: stub: cannot open" >&2\nexit 2\n' >"$_stubdir_q4/readelf"
  chmod +x "$_stubdir_q4/readelf"
  PATH="$_stubdir_q4:$PATH" "$SOURCE" quick /bin/true >"$ROOT/q4.out" 2>"$ROOT/q4.err"; _q4rc=$?
  if [ "$_q4rc" -ne 0 ] || grep -q 'readelf failed' "$ROOT/q4.err"; then
    ok "Q4: genuine readelf failure surfaces (rc=$_q4rc, not silently swallowed)"
  else
    no "Q4: genuine readelf failure silently swallowed (rc=0, no diagnostic)"
  fi
fi

# TEETH — prove the guard is per-test, not suite-level.
# Run inner call with a clean PATH that omits file and strings; the host-independent
# tests must still produce ≥4 passes. A suite-level guard produces 0 (exits early).
if [ "${1:-}" = "--prove-teeth" ]; then
  # lib/mutant.sh is sourced only on this path (this block precedes every helper use); every helper the
  # controls call is probed. Mutants are built into $ROOT/mut/<name>/ (under the suite's own temp root,
  # removed by the single EXIT trap above) next to a staged stub lib/tool-env.sh, never beside the SUT.
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  mutant_bootstrap mutant_chain mutant_built mutant_tooth mutant_or_count mutant_chain_or_count mutant_built_or_count || exit 2
  # A refused build counts ONE failure here and its tooth is never run.
  mk(){ mutant_chain_or_count fail "$@" || return 1; }
  mkb(){ mutant_built_or_count fail "$@" || return 1; }
  tt(){ if mutant_tooth "$@"; then pass=$((pass+1)); else fail=$((fail+1)); fi; }
  # Crash signatures: a mutant that dies this way must never read as a bite.
  CRASH_RE='integer expression expected|syntax error|unbound variable|Traceback|ImportError|command not found'
  # _nn_stage DIR LIB — stage a stub lib/tool-env.sh beside a mutant SUT (it sources $HERE/lib/tool-env.sh
  # relative to $0) and verify it; a failure is counted once here and the caller skips the build + tooth.
  _nn_stage() {
    if mkdir -p "$1/lib" && cp "$2" "$1/lib/tool-env.sh" && cmp -s "$2" "$1/lib/tool-env.sh"; then return 0; fi
    fail=$((fail+1)); printf '  FAIL  could not stage lib/tool-env.sh beside mutant dir %s\n' "$1"; return 1
  }
  # The _nn_* drivers each run one base scenario in a FRESH dir against the SUT path in $1 and print one
  # anchored KEY_FACT=... line derived from the SAME record file the base test asserts on. They return the
  # wrapper's own exit code, so mutant_tooth's GOOD_RC / BAD_RC are the wrapper's exit codes.
  # M9: quick mode with an endless 'strings' stub (dir in $2 first on PATH). Prints M9_PIPE=none when the
  # wrapper exits 0, sigpipe when it dies with 141, epipe when it fails with 'Broken pipe' (runner ignores
  # SIGPIPE); returns 0 for none, 1 for sigpipe/epipe, the raw rc otherwise (an unclassified failure).
  # The wrapper's stdout is discarded (40 x 6 KB stub lines); stderr is kept for the crash screen.
  _nn_m9() {
    local d rc p=other; d="$(mktemp -d "$ROOT/m9.XXXXXX")"
    env PATH="$2:$PATH" bash "$1" quick /bin/true >"$d/out" 2>"$d/err"; rc=$?
    cat "$d/err"; grep '^== strings' "$d/out"
    if [ "$rc" -eq 0 ]; then p=none
    elif [ "$rc" -eq 141 ]; then p=sigpipe
    elif grep -qi 'Broken pipe' "$d/err"; then p=epipe; fi
    echo "M9_PIPE=$p"
    case "$p" in none) return 0 ;; sigpipe|epipe) return 1 ;; *) return "$rc" ;; esac
  }
  # B3: -postScript gets the basename; the caller dir is on -scriptPath.
  _nn_b3() {
    local d rc ps sp h=0 p=OTHER s=0; d="$(mktemp -d "$ROOT/b3.XXXXXX")"
    mkdir -p "$d/scripts"; : >"$d/scripts/MyScript.java"
    TEST_ROOT="$ROOT" RECORD="$d/args" bash "$1" ghidra "$INPUT" "$d/out" --script "$d/scripts/MyScript.java" >/dev/null 2>"$d/err"; rc=$?
    cat "$d/err"
    ps="$(sed -n '/^-postScript$/{n; p; q}' "$d/args" 2>/dev/null)"
    sp="$(sed -n '/^-scriptPath$/{n; p; q}' "$d/args" 2>/dev/null)"
    if [ "$ps" = "MyScript.java" ]; then p=BASENAME; elif [ "$ps" = "$d/scripts/MyScript.java" ]; then p=FULLPATH; fi
    if <<<"$sp" grep -Fq -- "$d/scripts"; then s=1; fi
    if [ "$p" = BASENAME ] && [ "$s" -eq 1 ]; then h=1; fi
    echo "B3_FACT=holds:$h postscript:$p scriptpath:$s"
    return "$rc"
  }
  # N1: Ghidra exits 0 but writes no project files -> wrapper exits non-zero and prints no OK.
  _nn_mn1() {
    local d rc o=0 h=0; d="$(mktemp -d "$ROOT/mn1.XXXXXX")"
    HEADLESS_EMPTY=1 TEST_ROOT="$ROOT" RECORD="$d/args" bash "$1" ghidra "$INPUT" "$d/out" >"$d/out.txt" 2>"$d/err"; rc=$?
    cat "$d/err"
    if grep -q '^OK' "$d/out.txt"; then o=1; fi
    if [ "$rc" -ne 0 ] && [ "$o" -eq 0 ]; then h=1; fi
    echo "MN1_FACT=holds:$h ok:$o"
    return "$rc"
  }
  # MX1: explicit GHIDRA_MAXMEM is forwarded as MAXMEM (the mx1 analyzeHeadless stub records it in RECORD.maxmem).
  # MAXMEM is unset first so an ambient value can never mask a mutant that stops exporting it.
  _nn_mx1() {
    local d rc m h=0; d="$(mktemp -d "$ROOT/mx1.XXXXXX")"
    env -u MAXMEM GHIDRA_MAXMEM=8g TEST_ROOT="$ROOT" RECORD="$d/args" bash "$1" ghidra "$INPUT" "$d/out" >/dev/null 2>"$d/err"; rc=$?
    cat "$d/err"
    m="$(cat "$d/args.maxmem" 2>/dev/null)"
    if [ "$m" = "8g" ]; then h=1; fi
    echo "MX1_FACT=holds:$h maxmem:${m:-EMPTY}"
    return "$rc"
  }
  # PDB1: --pdb stages the PDB and imports the binary from pdb-stage/; the staged copy must also exist.
  _nn_pdb1() {   # $1 = SUT, $2 = PDB file to stage
    local d rc imp i=DIRECT st=0 h=0; d="$(mktemp -d "$ROOT/pdb1.XXXXXX")"
    GHIDRA_MAXMEM="" TEST_ROOT="$ROOT" RECORD="$d/args" bash "$1" ghidra "$INPUT" "$d/out" --pdb "$2" >/dev/null 2>"$d/err"; rc=$?
    cat "$d/err"
    imp="$(awk '/^-import$/{getline; print; exit}' "$d/args" 2>/dev/null)"
    if <<<"$imp" grep -q 'pdb-stage'; then i=STAGE; fi
    if [ -f "$d/out/pdb-stage/$(basename "$2")" ]; then st=1; fi
    if [ "$i" = STAGE ]; then h=1; fi
    echo "PDB1_FACT=holds:$h import:$i staged:$st"
    return "$rc"
  }
  echo "-- teeth: per-test guard must not collapse into a suite-level skip --"
  _clean="$ROOT/clean-bin"; mkdir -p "$_clean"
  for _c in bash mktemp rm mkdir cp chmod cat sed grep wc dirname basename head; do
    _p="$(builtin command -v "$_c" 2>/dev/null)"
    [ -n "$_p" ] && ln -s "$_p" "$_clean/$_c"
  done
  _out="$(PATH="$_clean" bash "$HERE/decompile-native.test.sh" 2>&1)"
  _np="$(printf '%s\n' "$_out" | grep -oE '^== [0-9]+' | grep -oE '[0-9]+')"
  if [ "${_np:-0}" -ge 6 ]; then
    ok "teeth: per-test guard keeps ≥6 host-independent tests with file/strings absent (${_np} passed)"
  else
    no "teeth: per-test guard collapsed; ${_np:-0} tests ran without file/strings (want ≥6)"
  fi
  # M7 guard: on a tool-less PATH the quick-mode guard must emit SKIP (not FAIL).
  # M7 mutation: removing `else` puts the run inside the then-block, so it fires when
  # tools are absent and the SUT exits 127 (set -euo pipefail + file missing) → FAIL.
  if <<<"$_out" grep -qF '  SKIP  quick mode' \
     && ! <<<"$_out" grep -qF '  FAIL  quick mode'; then
    ok "M7-base: clean-PATH run emits SKIP (not FAIL) for quick mode — guard working"
  else
    no "M7-base: quick mode did not emit SKIP-only in clean-PATH run — guard absent or broken"
  fi
  echo "-- M7 mutation: remove else so quick-mode runs inside the then-block --"
  # The mutant is a copy of THIS suite, not of the SUT, so it keeps its own observation (the mutant suite's
  # output on a tool-less PATH); only its BUILD moves to lib/mutant.sh (refuses a no-op awk). It is placed in
  # toolbelt/tests/ so HERE/../decompile-native.sh resolves to the SUT copy.
  mkdir -p "$ROOT/toolbelt/tests"
  _m7="$ROOT/toolbelt/tests/decompile-native.M7.test.sh"
  awk '/echo "  SKIP  quick mode/{print; getline; if ($0 !~ /^else$/) print; next} {print}' \
    "$HERE/decompile-native.test.sh" > "$_m7"
  if mkb "M7 teeth: build" "$HERE/decompile-native.test.sh" "$_m7"; then
    chmod +x "$_m7"
    _m7out="$(PATH="$_clean" bash "$_m7" 2>&1)"
    if <<<"$_m7out" grep -qF '  FAIL  quick mode'; then
      ok "M7-killed: else-removed mutant FAILs quick mode on tool-less PATH — M7 detected"
    else
      no "M7-killed: mutant did not FAIL quick mode on tool-less PATH — M7 survived (THEATER)"
    fi
  fi
  echo "-- M9 mutation: revert strings pipeline to bare (no SIGPIPE guard) → must go red --"
  # Guard: file is needed for the quick-mode preamble; strings must exist on the host
  # (mirroring Q2's guard style) so the scenario is meaningful.
  if ! command -v file >/dev/null 2>&1 || ! command -v strings >/dev/null 2>&1; then
    echo "  SKIP  M9 (tools unavailable: missing file or strings)"
  else
    # Inject a controlled strings stub: uses 'yes' (a C program) to produce infinite
    # ~6 KB lines.  'yes' is exec'd by the shell, so bash restores SIGPIPE to SIG_DFL
    # before exec — when head -40 closes the read end of the pipe, yes's next write
    # raises SIGPIPE immediately (POSIX guarantee), killing yes with exit 141 regardless
    # of pipe buffer size.  The stub shell exits 141 (last-command exit code), so
    # PIPESTATUS[0]=141 in the mutant.  Failsafe: yes terminates on SIGPIPE; cannot hang.
    # This mechanism is pipe-capacity-independent: even a small binary (e.g. /bin/true)
    # suffices — the stub ignores its arguments and always generates >1 MB of output.
    _m9_stubdir="$ROOT/m9stubs"
    mkdir -p "$_m9_stubdir"
    cat > "$_m9_stubdir/strings" << 'STUBEOF'
#!/bin/sh
# Controlled strings stub for deterministic M9 mutation control.
# 'yes' is a C program; bash restores SIGPIPE to SIG_DFL before exec, so when
# head -40 closes the read pipe yes's next write raises SIGPIPE -> exit 141.
# Pipe-capacity-independent: yes produces infinite output, never exits before SIGPIPE.
_line="STUB_CONTROLLED_$(printf '%6000s' '' | tr ' ' 'A')"
# A runner that started with SIGPIPE ignored makes yes see EPIPE (rc 1) instead of dying of the signal;
# report the same 141 a real strings killed by SIGPIPE would, so the stub behaves alike either way.
yes "$_line" || exit 141
STUBEOF
    chmod +x "$_m9_stubdir/strings"
    # Mutant: bare pipeline (SIGPIPE guard removed). Run with the stub strings first on PATH and /bin/true
    # as the binary (tiny) to prove the mechanism is independent of fixture/binary size. Exit codes are the
    # wrapper's: original tolerates 141 and exits 0; the mutant dies with the pipeline's 141. The anchored
    # section header proves both runs reached the strings stage (a crash before it is not a bite).
    if _nn_stage "$ROOT/mut/m9" "$ROOT/toolbelt/lib/tool-env.sh" \
       && mk "M9 teeth: build" "$SOURCE" "$ROOT/mut/m9/decompile-native.sh" 's/ || { _sp=.*//'; then
      # The driver classifies the pipe outcome, so the bite does not depend on how the runner set SIGPIPE:
      # default disposition -> yes dies of SIGPIPE (rc 141 = sigpipe); SIGPIPE ignored by the runner ->
      # yes sees EPIPE ('Broken pipe', rc 1 = epipe). Either way the bare pipeline fails and the driver
      # returns 1; the original must exit 0 (M9_PIPE=none).
      tt "M9-killed: bare pipeline mutant dies on the closed pipe via controlled stub — pipe-capacity-independent" 0 1 \
        "$ROOT/mut/m9/decompile-native.sh" --orig "$SUT" \
        --good-has '^M9_PIPE=none$' --bad-has '^M9_PIPE=(sigpipe|epipe)$' --bad-lacks "$CRASH_RE" \
        -- _nn_m9 @SUT@ "$_m9_stubdir"
    fi
  fi
  echo "-- M10 mutation: blanket || true swallows genuine strings failure → Q3 must go red --"
  # Guard: same tools needed as M9 (file for quick preamble, strings to keep scenario valid).
  if ! command -v file >/dev/null 2>&1 || ! command -v strings >/dev/null 2>&1; then
    echo "  SKIP  M10 (tools unavailable: missing file or strings)"
  else
    # Replaces the PIPESTATUS handler with || true, silencing genuine failure: the original exits 1 with
    # 'strings failed (rc=1)', the mutant exits 0 with no diagnostic.
    _stubdir_m10="$ROOT/stubstrings_m10"
    mkdir -p "$_stubdir_m10"
    printf '#!/bin/sh\necho "strings: stub" >&2\nexit 1\n' >"$_stubdir_m10/strings"
    chmod +x "$_stubdir_m10/strings"
    if _nn_stage "$ROOT/mut/m10" "$ROOT/toolbelt/lib/tool-env.sh" \
       && mk "M10 teeth: build" "$SOURCE" "$ROOT/mut/m10/decompile-native.sh" 's/ || { _sp=.*/ || true/'; then
      tt "M10-killed: blanket || true mutant swallows genuine failure (rc=0, no diagnostic) — Q3 detection confirmed" 1 0 \
        "$ROOT/mut/m10/decompile-native.sh" --orig "$SUT" \
        --good-has 'strings failed \(rc=1\)' --bad-has '^== strings \(first 40\) ==$' \
        --bad-lacks "strings failed|$CRASH_RE" \
        -- env PATH="$_stubdir_m10:$PATH" bash @SUT@ quick /bin/true
    fi
  fi
  echo "-- M11 mutation: revert readelf pipeline to || true → Q4 must go red --"
  # Guard: file is needed by the quick-mode preamble (echo "== file =="; file "$BIN").
  if ! command -v file >/dev/null 2>&1; then
    echo "  SKIP  M11 (tools unavailable: missing file)"
  else
    # Revert only the readelf guard; the strings guard is unaffected because the address regex
    # /readelf.*head/ matches only the readelf pipeline line. Original: exit 2 + 'readelf failed (rc=2)';
    # mutant: exit 0, no diagnostic, and it still reaches the strings section.
    _stubdir_m11="$ROOT/stubreadelf_m11"
    mkdir -p "$_stubdir_m11"
    printf '#!/bin/sh\necho "readelf: stub" >&2\nexit 2\n' >"$_stubdir_m11/readelf"
    chmod +x "$_stubdir_m11/readelf"
    if _nn_stage "$ROOT/mut/m11" "$ROOT/toolbelt/lib/tool-env.sh" \
       && mk "M11 teeth: build" "$SOURCE" "$ROOT/mut/m11/decompile-native.sh" '/readelf.*head/s/ || { _sp=.*/ || true/'; then
      tt "M11-killed: blanket || true mutant swallows readelf failure (rc=0, no diagnostic) — Q4 detection confirmed" 2 0 \
        "$ROOT/mut/m11/decompile-native.sh" --orig "$SUT" \
        --good-has 'readelf failed \(rc=2\)' --bad-has '^== strings \(first 40\) ==$' \
        --bad-lacks "readelf failed|$CRASH_RE" \
        -- env PATH="$_stubdir_m11:$PATH" bash @SUT@ quick /bin/true
    fi
  fi
  echo "-- M9/M10/M11 absent-tools guard: restricted PATH must emit SKIP, never a false kill --"
  # Build a minimal PATH containing neither 'file' nor 'strings' to verify the guards.
  _absent_dir="$ROOT/absent-tools"
  mkdir -p "$_absent_dir"
  for _t in bash sh awk sed grep printf tr wc mkdir mktemp rm chmod; do
    _tp=$(command -v "$_t" 2>/dev/null) && [ -n "$_tp" ] && ln -sf "$_tp" "$_absent_dir/$_t" 2>/dev/null || true
  done
  _guard_out=$(PATH="$_absent_dir" bash -c '
if ! command -v file >/dev/null 2>&1 || ! command -v strings >/dev/null 2>&1; then
    echo "  SKIP  M9 (tools unavailable: missing file or strings)"
    echo "  SKIP  M10 (tools unavailable: missing file or strings)"
fi
if ! command -v file >/dev/null 2>&1; then
    echo "  SKIP  M11 (tools unavailable: missing file)"
fi
')
  if <<<"$_guard_out" grep -qF '  SKIP  M9' \
     && <<<"$_guard_out" grep -qF '  SKIP  M10' \
     && <<<"$_guard_out" grep -qF '  SKIP  M11'; then
    ok "M9/M10/M11-guard: absent file/strings → SKIP emitted (no false kill possible)"
  else
    no "M9/M10/M11-guard: absent tools did not emit expected SKIPs — guard broken"
  fi
  echo "-- B3 mutation: remove basename from -postScript; B3 must expose full path --"
  if _nn_stage "$ROOT/mut/b3" "$ROOT/toolbelt/lib/tool-env.sh" \
     && mk "B3 teeth: build" "$SOURCE" "$ROOT/mut/b3/decompile-native.sh" 's/$(basename "$_script")/$_script/'; then
    tt "B3 teeth: mutant exposes full path to -postScript — B3 detection confirmed" 0 0 "$ROOT/mut/b3/decompile-native.sh" \
      --orig "$SUT" --good-has '^B3_FACT=holds:1 postscript:BASENAME scriptpath:1$' \
      --bad-has '^B3_FACT=holds:0 postscript:FULLPATH scriptpath:1$' --bad-lacks "$CRASH_RE" -- _nn_b3 @SUT@
  fi
  echo "-- MN1 mutation: remove PROJ non-empty guard; N1 must go RED --"
  # The mutant removes exactly the 'find ... -mindepth' guard line from the ghidra case. Running the
  # empty-output stub (HEADLESS_EMPTY=1) against it must print OK and exit 0 (original: exit 1, no OK) —
  # confirming N1 has teeth (the guard is the only thing that stops OK on empty PROJ).
  if _nn_stage "$ROOT/mut/mn1" "$ROOT/toolbelt/lib/tool-env.sh" \
     && mk "MN1 teeth: build" "$SOURCE" "$ROOT/mut/mn1/decompile-native.sh" \
          '/^ *\[ -n "\$(find "\$PROJ" -mindepth 2 .*exit 1; }$/d'; then
    tt "MN1-killed: guard-removed mutant exits 0+OK on empty PROJ → N1 bites" 1 0 "$ROOT/mut/mn1/decompile-native.sh" \
      --orig "$SUT" --good-has '^MN1_FACT=holds:1 ok:0$' --bad-has '^MN1_FACT=holds:0 ok:1$' \
      --bad-lacks "$CRASH_RE" -- _nn_mn1 @SUT@
  fi
fi

# ==================== MX1/MX2 — GHIDRA_MAXMEM + auto-RAM (#588) ====================
# Dedicated gh stub that records MAXMEM to $RECORD.maxmem so the tests can assert on it.
mkdir -p "$ROOT/mx1-gh/support" "$ROOT/mx1-toolbelt/lib"
cat >"$ROOT/mx1-gh/support/analyzeHeadless" <<'SH'
#!/bin/sh
printf '%s\n' "$@" >"$RECORD"
printf '%s\n' "${MAXMEM:-}" >"${RECORD}.maxmem"
mkdir -p "$1/ghidra-proj.rep/00"; touch "$1/ghidra-proj.rep/00/content.prp"
SH
chmod +x "$ROOT/mx1-gh/support/analyzeHeadless"
cp "$ROOT/toolbelt/decompile-native.sh" "$ROOT/mx1-toolbelt/decompile-native.sh"
cat >"$ROOT/mx1-toolbelt/lib/tool-env.sh" <<'SH'
rsdd_resolve_java_home(){ printf '%s\n' "${TEST_ROOT}/jdk"; }
rsdd_resolve_ghidra_home(){ printf '%s\n' "${TEST_ROOT}/mx1-gh"; }
rsdd_resolve_r2(){ printf '%s\n' "${TEST_ROOT}/bin/r2"; }
SH
_mx1_sut="$ROOT/mx1-toolbelt/decompile-native.sh"

# MX1: explicit GHIDRA_MAXMEM is forwarded as MAXMEM to analyzeHeadless
GHIDRA_MAXMEM=8g TEST_ROOT="$ROOT" RECORD="$ROOT/mx1.args" \
  bash "$_mx1_sut" ghidra "$INPUT" "$ROOT/out/mx1" >/dev/null 2>&1
_mx1_maxmem="$(cat "${ROOT}/mx1.args.maxmem" 2>/dev/null)"
[ "$_mx1_maxmem" = "8g" ] \
  && ok "MX1: GHIDRA_MAXMEM=8g exported as MAXMEM=8g to analyzeHeadless" \
  || no "MX1: MAXMEM was '${_mx1_maxmem:-<empty>}' (want 8g — GHIDRA_MAXMEM not passed through)"

# MX2: auto-detect from /proc/meminfo when GHIDRA_MAXMEM unset
if [ -f /proc/meminfo ]; then
  unset GHIDRA_MAXMEM
  RECORD="$ROOT/mx2.args" TEST_ROOT="$ROOT" \
    bash "$_mx1_sut" ghidra "$INPUT" "$ROOT/out/mx2" >/dev/null 2>&1
  _mx2_maxmem="$(cat "${ROOT}/mx2.args.maxmem" 2>/dev/null)"
  [ -n "$_mx2_maxmem" ] \
    && ok "MX2: auto-RAM: MAXMEM='$_mx2_maxmem' set from /proc/meminfo when GHIDRA_MAXMEM unset" \
    || no "MX2: MAXMEM empty when GHIDRA_MAXMEM unset on a machine with /proc/meminfo"
else
  echo "  SKIP  MX2 (/proc/meminfo absent — auto-RAM not testable on this OS)"
fi

# ==================== PDB1/PDB2 — --pdb staging (#588) ====================
# PDB1: --pdb stages the PDB alongside the binary for Ghidra symbol resolution
_pdb_src="$ROOT/target.pdb"; printf 'PDB-placeholder\n' >"$_pdb_src"
GHIDRA_MAXMEM="" RECORD="$ROOT/pdb1.args" TEST_ROOT="$ROOT" \
  bash "$_mx1_sut" ghidra "$INPUT" "$ROOT/out/pdb1" --pdb "$_pdb_src" >/dev/null 2>&1
_pdb1_import="$(awk '/^-import$/{getline; print; exit}' "$ROOT/pdb1.args" 2>/dev/null)"
<<<"$_pdb1_import" grep -q 'pdb-stage' \
  && ok "PDB1: --pdb caused binary to be imported from pdb-stage/ subdirectory" \
  || no "PDB1: import path '${_pdb1_import:-<empty>}' not under pdb-stage (staging not implemented)"
_pdb1_staged="$ROOT/out/pdb1/pdb-stage/$(basename "$_pdb_src")"
[ -f "$_pdb1_staged" ] \
  && ok "PDB1: PDB file staged alongside binary in pdb-stage/" \
  || no "PDB1: PDB not at expected stage path '${_pdb1_staged}' (staging not implemented)"

# PDB2: without --pdb, binary is imported directly (no pdb-stage subdir)
GHIDRA_MAXMEM="" RECORD="$ROOT/pdb2.args" TEST_ROOT="$ROOT" \
  bash "$_mx1_sut" ghidra "$INPUT" "$ROOT/out/pdb2" >/dev/null 2>&1
_pdb2_import="$(awk '/^-import$/{getline; print; exit}' "$ROOT/pdb2.args" 2>/dev/null)"
<<<"$_pdb2_import" grep -q 'pdb-stage' \
  && no "PDB2: import path contains 'pdb-stage' even without --pdb" \
  || ok "PDB2: without --pdb, binary imported directly (no pdb-stage)"

if [ "${1:-}" = "--prove-teeth" ]; then
  # lib/mutant.sh was sourced by the first teeth block; probe every helper this block calls again.
  for _fn in mutant_chain mutant_tooth _nn_stage _nn_mx1 _nn_pdb1; do
    declare -F "$_fn" >/dev/null || { echo "FATAL: teeth helper $_fn is not defined" >&2; exit 2; }
  done
  echo "-- teeth-mx1: neuter MAXMEM export; MX1 must go red --"
  # Mutant dir carries the mx1 stub lib (points at mx1-gh, whose analyzeHeadless records MAXMEM).
  if _nn_stage "$ROOT/mut/mx1" "$ROOT/mx1-toolbelt/lib/tool-env.sh" \
     && mk "teeth-mx1: build" "$SOURCE" "$ROOT/mut/mx1/decompile-native.sh" \
          's/export MAXMEM="\$GHIDRA_MAXMEM"/: # MX1-MAXMEM-MUTANT/'; then
    tt "teeth-mx1: mutant does not export MAXMEM=8g — MX1 detection confirmed" 0 0 "$ROOT/mut/mx1/decompile-native.sh" \
      --orig "$_mx1_sut" --good-has '^MX1_FACT=holds:1 maxmem:8g$' --bad-has '^MX1_FACT=holds:0 maxmem:EMPTY$' \
      --bad-lacks "$CRASH_RE" -- _nn_mx1 @SUT@
  fi

  echo "-- teeth-pdb1: neuter PDB stage path; PDB1 import-path check must go red --"
  if _nn_stage "$ROOT/mut/pdb1" "$ROOT/mx1-toolbelt/lib/tool-env.sh" \
     && mk "teeth-pdb1: build" "$SOURCE" "$ROOT/mut/pdb1/decompile-native.sh" \
          's|.*# PDB1-STAGE-PATH-SENTINEL.*|    _import_bin="$BIN"  # PDB1-STAGE-PATH-SENTINEL [MUTANT]|'; then
    tt "teeth-pdb1: mutant import path not under pdb-stage — PDB1 detection confirmed" 0 0 "$ROOT/mut/pdb1/decompile-native.sh" \
      --orig "$_mx1_sut" --good-has '^PDB1_FACT=holds:1 import:STAGE staged:1$' \
      --bad-has '^PDB1_FACT=holds:0 import:DIRECT staged:1$' --bad-lacks "$CRASH_RE" -- _nn_pdb1 @SUT@ "$_pdb_src"
  fi
fi

echo "== $pass passed · $fail failed =="; [ "$fail" -eq 0 ]
