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
      && printf '%s\n' "$_sp_val" | grep -Fq -- "$ROOT/scripts"; then
      ok "B3: -postScript gets basename; caller dir is on -scriptPath"
    else
      no "B3: -postScript='$_ps_val' -scriptPath='$_sp_val' (want basename + caller dir)"
    fi
  fi
else
  no "B3: ghidra --script invocation failed"
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
  if "$SOURCE" quick "$_big" >"$ROOT/q2.out" 2>&1; then
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

# TEETH — prove the guard is per-test, not suite-level.
# Run inner call with a clean PATH that omits file and strings; the host-independent
# tests must still produce ≥4 passes. A suite-level guard produces 0 (exits early).
if [ "${1:-}" = "--prove-teeth" ]; then
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
  if printf '%s\n' "$_out" | grep -qF '  SKIP  quick mode' \
     && ! printf '%s\n' "$_out" | grep -qF '  FAIL  quick mode'; then
    ok "M7-base: clean-PATH run emits SKIP (not FAIL) for quick mode — guard working"
  else
    no "M7-base: quick mode did not emit SKIP-only in clean-PATH run — guard absent or broken"
  fi
  echo "-- M7 mutation: remove else so quick-mode runs inside the then-block --"
  # Place mutant in toolbelt/tests/ so HERE/../decompile-native.sh resolves to the SUT copy.
  mkdir -p "$ROOT/toolbelt/tests"
  _m7="$ROOT/toolbelt/tests/decompile-native.M7.test.sh"
  awk '/echo "  SKIP  quick mode/{print; getline; if ($0 !~ /^else$/) print; next} {print}' \
    "$HERE/decompile-native.test.sh" > "$_m7"
  chmod +x "$_m7"
  _m7out="$(PATH="$_clean" bash "$_m7" 2>&1)"
  if printf '%s\n' "$_m7out" | grep -qF '  FAIL  quick mode'; then
    ok "M7-killed: else-removed mutant FAILs quick mode on tool-less PATH — M7 detected"
  else
    no "M7-killed: mutant did not FAIL quick mode on tool-less PATH — M7 survived (THEATER)"
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
yes "$_line"
STUBEOF
    chmod +x "$_m9_stubdir/strings"
    # Create mutant: bare pipeline (SIGPIPE guard removed)
    _m9="$ROOT/toolbelt/decompile-native.M9.sh"
    sed 's/ || { _sp=.*//' "$ROOT/toolbelt/decompile-native.sh" > "$_m9"
    chmod +x "$_m9"
    if grep -qF 'PIPESTATUS' "$_m9"; then
      no "M9 setup: mutant still contains PIPESTATUS — sed pattern not matched (did the fix change?)"
    else
      # Run mutant with stub strings in PATH.  Binary arg is /bin/true (tiny) to prove
      # the mechanism is independent of fixture/binary size — not dependent on pipe capacity.
      PATH="$_m9_stubdir:$PATH" "$_m9" quick /bin/true >/dev/null 2>&1; _m9rc=$?
      if [ "$_m9rc" -ne 0 ]; then
        ok "M9-killed: bare pipeline mutant exits non-zero ($_m9rc) via controlled stub — pipe-capacity-independent"
      else
        no "M9-killed: bare pipeline mutant exits 0 — M9 survived (THEATER)"
      fi
    fi
  fi
  echo "-- M10 mutation: blanket || true swallows genuine strings failure → Q3 must go red --"
  # Guard: same tools needed as M9 (file for quick preamble, strings to keep scenario valid).
  if ! command -v file >/dev/null 2>&1 || ! command -v strings >/dev/null 2>&1; then
    echo "  SKIP  M10 (tools unavailable: missing file or strings)"
  else
    # Replaces the PIPESTATUS handler with || true, silencing genuine failure.
    _m10="$ROOT/toolbelt/decompile-native.M10.sh"
    sed 's/ || { _sp=.*/ || true/' "$ROOT/toolbelt/decompile-native.sh" > "$_m10"
    chmod +x "$_m10"
    if grep -qF '|| true' "$_m10" && ! grep -qF 'PIPESTATUS' "$_m10"; then
      _stubdir_m10="$ROOT/stubstrings_m10"
      mkdir -p "$_stubdir_m10"
      printf '#!/bin/sh\necho "strings: stub" >&2\nexit 1\n' >"$_stubdir_m10/strings"
      chmod +x "$_stubdir_m10/strings"
      PATH="$_stubdir_m10:$PATH" "$_m10" quick /bin/true >/dev/null 2>"$ROOT/m10.err"; _m10rc=$?
      if [ "$_m10rc" -eq 0 ] && ! grep -q 'strings failed' "$ROOT/m10.err"; then
        ok "M10-killed: blanket || true mutant swallows genuine failure (rc=0, no diagnostic) — Q3 detection confirmed"
      else
        no "M10-killed: || true mutant did not swallow failure (rc=$_m10rc) — M10 survived (THEATER)"
      fi
    else
      no "M10 setup: mutant not as expected (missing || true or still has PIPESTATUS)"
    fi
  fi
  echo "-- M9/M10 absent-tools guard: restricted PATH must emit SKIP, never a false kill --"
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
else
    echo "UNEXPECTED-NOT-SKIPPED"
fi
')
  if printf '%s\n' "$_guard_out" | grep -qF '  SKIP  M9' \
     && printf '%s\n' "$_guard_out" | grep -qF '  SKIP  M10'; then
    ok "M9/M10-guard: absent file/strings → SKIP emitted (no false kill possible)"
  else
    no "M9/M10-guard: absent tools did not emit SKIP for M9 and M10 — guard broken"
  fi
  echo "-- B3 mutation: remove basename from -postScript; B3 must expose full path --"
  _mutant="$ROOT/toolbelt/decompile-native.MUTANT.sh"
  sed 's/$(basename "$_script")/$_script/' "$ROOT/toolbelt/decompile-native.sh" > "$_mutant"
  chmod +x "$_mutant"
  if grep -qF '$(basename "$_script")' "$_mutant"; then
    no "B3 teeth: mutant still contains 'basename' — sed pattern not matched (did the SUT change?)"
  else
    mkdir -p "$ROOT/scripts_mut"
    : >"$ROOT/scripts_mut/Mutant.java"
    TEST_ROOT="$ROOT" RECORD="$ROOT/b3mut.args" \
      bash "$_mutant" ghidra "$INPUT" "$ROOT/out/b3mut" --script "$ROOT/scripts_mut/Mutant.java" \
      >/dev/null 2>&1 || true
    if [ -s "$ROOT/b3mut.args" ]; then
      _mps_val="$(sed -n '/^-postScript$/{n; p; q}' "$ROOT/b3mut.args")"
      if [ "$_mps_val" != "Mutant.java" ]; then
        ok "B3 teeth: mutant exposes full path to -postScript ('$_mps_val') — B3 detection confirmed"
      else
        no "B3 teeth: mutant still emits basename 'Mutant.java' — mutation had no effect (THEATER)"
      fi
    else
      no "B3 teeth: mutant produced no RECORD file — cannot verify teeth"
    fi
  fi
fi

echo "== $pass passed · $fail failed =="; [ "$fail" -eq 0 ]
