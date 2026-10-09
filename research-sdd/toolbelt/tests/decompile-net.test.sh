#!/usr/bin/env bash
# decompile-net.test.sh — RED-FIRST harness for decompile-net.sh.
#
# B1 REGRESSION: `--list` mode used `--list-types` (rejected by ilspycmd 8.2.0).
# The correct flag is `-l c`. This suite stubs ilspycmd to record its arguments
# and asserts the stub receives `-l c`, not `--list-types`.
#
# Usage: decompile-net.test.sh [--prove-teeth]   Exit: 0 all held · 1 regression.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../decompile-net.sh"
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

# Resolve bash + required coreutils once, in the unrestricted env, for hermetic sandboxes.
# dirname is needed by the SUT's HERE= computation; pwd is a bash built-in (no symlink needed).
BASH_BIN="$(type -P bash)"; [ -n "$BASH_BIN" ] || { echo "FATAL: bash not found on PATH" >&2; exit 2; }
DIRNAME_BIN="$(type -P dirname)"; [ -n "$DIRNAME_BIN" ] || { echo "FATAL: dirname not found on PATH" >&2; exit 2; }

echo "== decompile-net.test.sh (SUT: $(basename "$SUT")) =="

REALPATH_BIN="$(type -P realpath)"; [ -n "$REALPATH_BIN" ] || { echo "FATAL: realpath not found on PATH" >&2; exit 2; }

# Stub ilspycmd: records all arguments one per line, then exits 0.
STUB="$TMP/ilspycmd"; RECORD="$TMP/args.txt"; DLL="$TMP/test.dll"
cat > "$STUB" <<'SH'
#!/bin/sh
printf '%s\n' "$@" > "$RECORD"
SH
chmod +x "$STUB"
: > "$DLL"   # dummy DLL file so the -x guard passes

# B1 CORE — --list mode must pass -l c, NOT --list-types.
ILSPYCMD="$STUB" RECORD="$RECORD" bash "$SUT" --list "$DLL" >/dev/null 2>&1
if [ "$(sed -n '1p' "$RECORD")" = "-l" ] && [ "$(sed -n '2p' "$RECORD")" = "c" ]; then
  ok "B1: --list passes -l c to ilspycmd (not --list-types)"
else
  no "B1: --list flag wrong — got '$(head -2 "$RECORD" | tr '\n' ' ')' (want '-l c')"
fi

# Negative control — verify the stub itself works (--list-types would land on line 1 as one token)
ILSPYCMD="$STUB" RECORD="$TMP/negctrl.txt" bash "$SUT" --list "$DLL" >/dev/null 2>&1
if ! grep -qxF -- '--list-types' "$TMP/negctrl.txt" 2>/dev/null; then
  ok "B1 neg-ctrl: --list-types absent from recorded args"
else
  no "B1 neg-ctrl: --list-types still present — fix not applied"
fi

# ilspycmd missing → exit 3 (guard check).
ILSPYCMD="$TMP/nonexistent" bash "$SUT" --list "$DLL" >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 3 ]; then ok "missing ilspycmd → exit 3"
else no "missing ilspycmd: got exit $rc (want 3)"; fi

# --il mode is unrelated (passes --il) — sanity test.
ILSPYCMD="$STUB" RECORD="$TMP/il.txt" bash "$SUT" --il "$DLL" "$TMP/out-il" >/dev/null 2>&1
if grep -qxF -- '--il' "$TMP/il.txt" 2>/dev/null; then
  ok "--il mode still passes --il (unrelated to B1)"
else
  no "--il mode flag check failed"
fi

# ---------------------------------------------------------------------------
# P1 — Portability: no /home/<user> literal in the SUT source.
if ! grep -q '/home/[a-z]' "$SUT"; then
  ok "P1: no /home/<user> literal in decompile-net.sh"
else
  no "P1: /home/<user> literal found — portability regression"
fi

# P2 — ILSPYCMD unset; ilspycmd present on a controlled PATH → resolver uses PATH.
# Hermetic: box/bin has only our ilspycmd stub + dirname coreutil (needed by SUT's HERE=);
# HOME has no .dotnet/tools/ilspycmd so the $HOME fallback cannot fire.
box_p2="$TMP/p2"; mkdir -p "$box_p2/bin" "$box_p2/home" "$box_p2/runtime/shared/Microsoft.NETCore.App"
ln -s "$DIRNAME_BIN" "$box_p2/bin/dirname"
rec_p2="$box_p2/p2.rec"; touch "$rec_p2"
printf '#!/bin/sh\nprintf "called\\n" >> "%s"\nexit 0\n' "$rec_p2" > "$box_p2/bin/ilspycmd"
chmod +x "$box_p2/bin/ilspycmd"
dll_p2="$box_p2/test.dll"; touch "$dll_p2"
env -u ILSPYCMD DOTNET_ROOT="$box_p2/runtime" PATH="$box_p2/bin" HOME="$box_p2/home" \
  "$BASH_BIN" "$SUT" --list "$dll_p2" >/dev/null 2>&1; rc_p2=$?
if [ "$rc_p2" -eq 0 ] && [ -s "$rec_p2" ]; then
  ok "P2: PATH resolution: ilspycmd found via PATH when ILSPYCMD unset"
else
  no "P2: PATH resolution: exit=$rc_p2 rec=$(cat "$rec_p2" 2>/dev/null || echo empty)"
fi

# P3 — ILSPYCMD=executable is authoritative (overrides a different stub on PATH).
box_p3="$TMP/p3"; mkdir -p "$box_p3/bin" "$box_p3/home" "$box_p3/override" "$box_p3/runtime/shared/Microsoft.NETCore.App"
ln -s "$DIRNAME_BIN" "$box_p3/bin/dirname"
rec_p3_ilspy="$box_p3/ilspy.rec"; rec_p3_path="$box_p3/path.rec"
touch "$rec_p3_ilspy" "$rec_p3_path"
printf '#!/bin/sh\nprintf "called\\n" >> "%s"\nexit 0\n' "$rec_p3_path" > "$box_p3/bin/ilspycmd"
chmod +x "$box_p3/bin/ilspycmd"
ilspy_stub_p3="$box_p3/override/myilspy"
printf '#!/bin/sh\nprintf "called\\n" >> "%s"\nexit 0\n' "$rec_p3_ilspy" > "$ilspy_stub_p3"
chmod +x "$ilspy_stub_p3"
dll_p3="$box_p3/test.dll"; touch "$dll_p3"
ILSPYCMD="$ilspy_stub_p3" DOTNET_ROOT="$box_p3/runtime" PATH="$box_p3/bin" HOME="$box_p3/home" \
  "$BASH_BIN" "$SUT" --list "$dll_p3" >/dev/null 2>&1; rc_p3=$?
if [ "$rc_p3" -eq 0 ] && [ -s "$rec_p3_ilspy" ] && ! [ -s "$rec_p3_path" ]; then
  ok "P3: ILSPYCMD=executable is authoritative (overrides PATH)"
else
  no "P3: ILSPYCMD auth: exit=$rc_p3 ilspy=$(cat "$rec_p3_ilspy") path=$(cat "$rec_p3_path")"
fi

# P4 — ILSPYCMD set to non-existent path → exit 3, no fallthrough to PATH.
box_p4="$TMP/p4"; mkdir -p "$box_p4/bin" "$box_p4/home"
ln -s "$DIRNAME_BIN" "$box_p4/bin/dirname"
rec_p4="$box_p4/p4.rec"; touch "$rec_p4"
printf '#!/bin/sh\nprintf "called\\n" >> "%s"\nexit 0\n' "$rec_p4" > "$box_p4/bin/ilspycmd"
chmod +x "$box_p4/bin/ilspycmd"
dll_p4="$box_p4/test.dll"; touch "$dll_p4"
ILSPYCMD="$box_p4/nonexistent" PATH="$box_p4/bin" HOME="$box_p4/home" \
  "$BASH_BIN" "$SUT" --list "$dll_p4" >/dev/null 2>&1; rc_p4=$?
if [ "$rc_p4" -eq 3 ] && ! [ -s "$rec_p4" ]; then
  ok "P4: ILSPYCMD=nonexistent → exit 3 (no fallthrough to PATH)"
else
  no "P4: no-fallthrough: exit=$rc_p4 rec=$(cat "$rec_p4" 2>/dev/null)"
fi

# ---------------------------------------------------------------------------
# D1 — DOTNET_ROOT derived from dotnet binary (stock layout) and exported.
# Hermetic: box has dirname, realpath, a fake dotnet binary in its own root dir
# (which also holds shared/Microsoft.NETCore.App/), and an ilspycmd stub that
# records the DOTNET_ROOT it received in its environment.
box_d1="$TMP/d1"
mkdir -p "$box_d1/bin" "$box_d1/home" "$box_d1/fake_root/shared/Microsoft.NETCore.App"
printf '#!/bin/sh\nexit 0\n' > "$box_d1/fake_root/dotnet"
chmod +x "$box_d1/fake_root/dotnet"
ln -s "$DIRNAME_BIN"  "$box_d1/bin/dirname"
ln -s "$REALPATH_BIN" "$box_d1/bin/realpath"
# symlink in PATH → realpath resolves it to the real binary inside fake_root
ln -s "$box_d1/fake_root/dotnet" "$box_d1/bin/dotnet"
rec_d1_env="$box_d1/ilspy.env"; touch "$rec_d1_env"
dll_d1="$box_d1/test.dll"; touch "$dll_d1"
cat > "$box_d1/bin/ilspycmd" <<SH
#!/bin/sh
[ "\$1" = "--version" ] && exit 0
printf '%s\n' "\${DOTNET_ROOT:-UNSET}" >> "$rec_d1_env"
exit 0
SH
chmod +x "$box_d1/bin/ilspycmd"
env -u ILSPYCMD -u DOTNET_ROOT -u RSDD_DOTNET_ROOT \
  PATH="$box_d1/bin" HOME="$box_d1/home" \
  "$BASH_BIN" "$SUT" --list "$dll_d1" >/dev/null 2>&1; rc_d1=$?
dotnet_root_d1="$(cat "$rec_d1_env" 2>/dev/null || echo UNSET)"
if [ "$rc_d1" -eq 0 ] && [ "$dotnet_root_d1" = "$box_d1/fake_root" ]; then
  ok "D1: DOTNET_ROOT derived from dotnet binary and exported to ilspycmd"
else
  no "D1: exit=$rc_d1 DOTNET_ROOT seen='$dotnet_root_d1' (want '$box_d1/fake_root')"
fi

# D2 — No DOTNET_ROOT resolves → exit 3, message names DOTNET_ROOT.
# ilspycmd IS present so exit 3 can only come from the DOTNET_ROOT guard, not ilspy.
box_d2="$TMP/d2"
mkdir -p "$box_d2/bin" "$box_d2/home"
ln -s "$DIRNAME_BIN" "$box_d2/bin/dirname"
printf '#!/bin/sh\nexit 0\n' > "$box_d2/bin/ilspycmd"
chmod +x "$box_d2/bin/ilspycmd"
dll_d2="$box_d2/test.dll"; touch "$dll_d2"
err_d2="$TMP/d2.err"
env -u ILSPYCMD -u DOTNET_ROOT -u RSDD_DOTNET_ROOT \
  PATH="$box_d2/bin" HOME="$box_d2/home" \
  "$BASH_BIN" "$SUT" --list "$dll_d2" 2>"$err_d2" >/dev/null; rc_d2=$?
if [ "$rc_d2" -eq 3 ] && grep -qi 'DOTNET_ROOT' "$err_d2" 2>/dev/null; then
  ok "D2: no DOTNET_ROOT resolves → exit 3 with DOTNET_ROOT named in error"
else
  no "D2: exit=$rc_d2 err=$(cat "$err_d2" 2>/dev/null || echo empty)"
fi

# D3 — RSDD_DOTNET_ROOT override is honored (no dotnet binary needed).
box_d3="$TMP/d3"
mkdir -p "$box_d3/bin" "$box_d3/home" "$box_d3/override_root/shared/Microsoft.NETCore.App"
ln -s "$DIRNAME_BIN" "$box_d3/bin/dirname"
rec_d3_env="$box_d3/ilspy.env"; touch "$rec_d3_env"
dll_d3="$box_d3/test.dll"; touch "$dll_d3"
cat > "$box_d3/bin/ilspycmd" <<SH
#!/bin/sh
[ "\$1" = "--version" ] && exit 0
printf '%s\n' "\${DOTNET_ROOT:-UNSET}" >> "$rec_d3_env"
exit 0
SH
chmod +x "$box_d3/bin/ilspycmd"
env -u ILSPYCMD -u DOTNET_ROOT \
  RSDD_DOTNET_ROOT="$box_d3/override_root" \
  PATH="$box_d3/bin" HOME="$box_d3/home" \
  "$BASH_BIN" "$SUT" --list "$dll_d3" >/dev/null 2>&1; rc_d3=$?
dotnet_root_d3="$(cat "$rec_d3_env" 2>/dev/null || echo UNSET)"
if [ "$rc_d3" -eq 0 ] && [ "$dotnet_root_d3" = "$box_d3/override_root" ]; then
  ok "D3: RSDD_DOTNET_ROOT override honored and exported as DOTNET_ROOT"
else
  no "D3: exit=$rc_d3 DOTNET_ROOT seen='$dotnet_root_d3' (want '$box_d3/override_root')"
fi

# D1-empty — DOTNET_ROOT candidate has shared/Microsoft.NETCore.App but is empty/unusable.
# ilspycmd --version fails (simulates a runtime that exists on disk but can't load the tool).
# Expects exit 3: existence-only check is not sufficient — usability must be probed.
box_d1e="$TMP/d1e"
mkdir -p "$box_d1e/bin" "$box_d1e/home" "$box_d1e/bad_root/shared/Microsoft.NETCore.App"
ln -s "$DIRNAME_BIN" "$box_d1e/bin/dirname"
cat > "$box_d1e/bin/ilspycmd" <<'SH'
#!/bin/sh
[ "$1" = "--version" ] && exit 1
exit 0
SH
chmod +x "$box_d1e/bin/ilspycmd"
dll_d1e="$box_d1e/test.dll"; touch "$dll_d1e"
err_d1e="$TMP/d1e.err"
env -u ILSPYCMD -u RSDD_DOTNET_ROOT \
  DOTNET_ROOT="$box_d1e/bad_root" \
  PATH="$box_d1e/bin" HOME="$box_d1e/home" \
  "$BASH_BIN" "$SUT" --list "$dll_d1e" 2>"$err_d1e" >/dev/null; rc_d1e=$?
if [ "$rc_d1e" -eq 3 ]; then
  ok "D1-empty: DOTNET_ROOT with empty/unusable runtime → probe fails → exit 3"
else
  no "D1-empty: exit=$rc_d1e (want 3; existence-only check accepted unusable runtime)"
fi

# D2-rsdd-bad — RSDD_DOTNET_ROOT set but ilspycmd --version fails.
# Must exit 3 loudly; must NOT fall through to use the valid ambient DOTNET_ROOT.
box_d2r="$TMP/d2r"
mkdir -p "$box_d2r/bin" "$box_d2r/home" \
         "$box_d2r/bad_root/shared/Microsoft.NETCore.App" \
         "$box_d2r/good_root/shared/Microsoft.NETCore.App"
ln -s "$DIRNAME_BIN" "$box_d2r/bin/dirname"
rec_d2r="$box_d2r/ilspy.rec"; touch "$rec_d2r"
# Stub: --version exits 0 only for good_root; all other calls record DOTNET_ROOT.
cat > "$box_d2r/bin/ilspycmd" <<SH
#!/bin/sh
if [ "\$1" = "--version" ]; then
  [ "\${DOTNET_ROOT:-}" = "$box_d2r/good_root" ] && exit 0
  exit 1
fi
printf '%s\n' "\${DOTNET_ROOT:-UNSET}" >> "$rec_d2r"
exit 0
SH
chmod +x "$box_d2r/bin/ilspycmd"
dll_d2r="$box_d2r/test.dll"; touch "$dll_d2r"
err_d2r="$TMP/d2r.err"
env -u ILSPYCMD \
  RSDD_DOTNET_ROOT="$box_d2r/bad_root" \
  DOTNET_ROOT="$box_d2r/good_root" \
  PATH="$box_d2r/bin" HOME="$box_d2r/home" \
  "$BASH_BIN" "$SUT" --list "$dll_d2r" 2>"$err_d2r" >/dev/null; rc_d2r=$?
dotnet_seen_d2r="$(cat "$rec_d2r" 2>/dev/null || echo UNSET)"
if [ "$rc_d2r" -eq 3 ] && [ -z "$dotnet_seen_d2r" ]; then
  ok "D2-rsdd-bad: RSDD_DOTNET_ROOT unusable → exit 3, did NOT fall through to DOTNET_ROOT"
else
  no "D2-rsdd-bad: exit=$rc_d2r seen='$dotnet_seen_d2r' (want exit 3 + no DOTNET_ROOT used)"
fi

# ---------------------------------------------------------------------------
# NE1 — ilspycmd exits 0 but produces no .cs files → wrapper must exit non-zero, no OK.
# Uses a minimal hermetic box: an ilspycmd stub that exits 0 for all calls (incl. --version)
# but never writes any .cs files; RSDD_DOTNET_ROOT pointing at a valid-looking runtime dir.
_ne1_dir="$TMP/ne1"
mkdir -p "$_ne1_dir/runtime/shared/Microsoft.NETCore.App" "$_ne1_dir/out"
cat > "$_ne1_dir/ilspycmd" <<'SH'
#!/bin/sh
exit 0
SH
chmod +x "$_ne1_dir/ilspycmd"
_ne1_dll="$_ne1_dir/test.dll"; touch "$_ne1_dll"
ILSPYCMD="$_ne1_dir/ilspycmd" RSDD_DOTNET_ROOT="$_ne1_dir/runtime" \
  bash "$SUT" "$_ne1_dll" "$_ne1_dir/out" >"$_ne1_dir/stdout" 2>"$_ne1_dir/stderr"; _ne1rc=$?
if [ "$_ne1rc" -ne 0 ] && ! grep -q '^OK' "$_ne1_dir/stdout"; then
  ok "NE1: ilspycmd exits 0 but no .cs files → wrapper exits non-zero, no OK"
else
  no "NE1: ilspycmd exits 0 but no .cs files → must exit non-zero (got rc=$_ne1rc)"
fi

# NE0 — success baseline: ilspycmd exits 0 and writes a .cs file → wrapper exits 0, prints OK.
# The stub parses -o <out> from its argv and creates a sentinel .cs file there.
_ne0_dir="$TMP/ne0"
mkdir -p "$_ne0_dir/runtime/shared/Microsoft.NETCore.App" "$_ne0_dir/out"
cat > "$_ne0_dir/ilspycmd" <<'SH'
#!/bin/sh
_out=""
_prev=""
for _a in "$@"; do
  [ "$_prev" = "-o" ] && _out="$_a"
  _prev="$_a"
done
[ -z "$_out" ] || { mkdir -p "$_out"; touch "$_out/Decompiled.cs"; }
exit 0
SH
chmod +x "$_ne0_dir/ilspycmd"
_ne0_dll="$_ne0_dir/test.dll"; touch "$_ne0_dll"
ILSPYCMD="$_ne0_dir/ilspycmd" RSDD_DOTNET_ROOT="$_ne0_dir/runtime" \
  bash "$SUT" "$_ne0_dll" "$_ne0_dir/out" >"$_ne0_dir/stdout" 2>"$_ne0_dir/stderr"; _ne0rc=$?
if [ "$_ne0rc" -eq 0 ] && grep -q '^OK' "$_ne0_dir/stdout"; then
  ok "NE0: ilspycmd creates .cs file → wrapper exits 0, prints OK"
else
  no "NE0: ilspycmd creates .cs file → must exit 0 and print OK (got rc=$_ne0rc)"
fi

# TEETH — prove that assertions fail against broken implementations.
# Every control builds its mutant with lib/mutant.sh (refuses a no-op, empty, byte-identical, syntax-broken
# or live-tree mutant) and observes original and mutant through mutant_tooth with EXACT exit codes.
# Each _nt_* driver is a shell function that mirrors one base scenario above in a FRESH box under $TMP
# and prints anchored KEY=value fact lines read from the SAME artifacts the base test asserts on (record
# files / stderr). A driver returns the wrapper's own exit code, so the GOOD_RC / BAD_RC positional codes
# of mutant_tooth below are the wrapper's exit codes on the original / on the mutant.
if [ "${1:-}" = "--prove-teeth" ]; then
  # lib/mutant.sh is sourced only on this path; every helper the controls call is probed.
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  mutant_bootstrap mutant_chain mutant_built mutant_tooth mutant_or_count mutant_chain_or_count mutant_built_or_count || exit 2
  MUT="$TMP/mut"; mkdir -p "$MUT"
  # A refused build counts ONE failure here and its tooth is never run.
  mk(){ mutant_chain_or_count fail "$@" || return 1; }
  mkb(){ mutant_built_or_count fail "$@" || return 1; }
  tt(){ if mutant_tooth "$@"; then pass=$((pass+1)); else fail=$((fail+1)); fi; }
  # Crash signatures: a mutant that dies this way must never read as a bite.
  CRASH_RE='integer expression expected|syntax error|unbound variable|Traceback|ImportError|command not found'

  # _nt_stage DIR — stage the kit's lib/tool-env.sh beside a mutant SUT (it resolves lib/ via $0) and
  # verify the staging. Failure is returned to the caller, which counts it once.
  _nt_stage() {
    mkdir -p "$1/lib" && cp "$HERE/../lib/tool-env.sh" "$1/lib/tool-env.sh" && cmp -s "$HERE/../lib/tool-env.sh" "$1/lib/tool-env.sh"
  }
  # _nt_stage_sut DIR — stage an unmodified SUT copy plus an (empty) lib/ dir for a mutated lib/tool-env.sh.
  _nt_stage_sut() {
    mkdir -p "$1/lib" && cp "$SUT" "$1/decompile-net.sh" && cmp -s "$SUT" "$1/decompile-net.sh"
  }
  # _nt_pysub OUT REGEX REPL — write OUT = lib/tool-env.sh with exactly ONE regex substitution
  # (DOTALL|MULTILINE); exits 2 when the pattern does not match exactly once. mutant_built then verifies OUT.
  _nt_pysub() {
    python3 - "$HERE/../lib/tool-env.sh" "$1" "$2" "$3" <<'PYEOF'
import sys, re
text = open(sys.argv[1]).read()
flags = re.MULTILINE | re.DOTALL
# Dry run first: refuse unless the pattern matches EXACTLY once (count=1 alone could never see a 2nd match).
if len(re.findall(sys.argv[3], text, flags)) != 1:
    sys.exit(2)
result = re.sub(sys.argv[3], lambda m: sys.argv[4], text, count=1, flags=flags)
open(sys.argv[2], 'w').write(result)
PYEOF
  }
  # mks LABEL ORIG DIR EXPR... — stage, then build DIR/decompile-net.sh from ORIG with sed stages.
  mks(){
    local l="$1" o="$2" d="$3"; shift 3
    if ! _nt_stage "$d"; then fail=$((fail+1)); printf '  FAIL  %s: could not stage lib/ beside %s\n' "$l" "$d"; return 1; fi
    mk "$l" "$o" "$d/decompile-net.sh" "$@"
  }
  # _nt_box PREFIX — fresh box dir under $TMP.
  _nt_box() { mktemp -d "$TMP/$1.XXXXXX"; }
  # _nt_rec STUB RECFILE — ilspycmd stub that appends one line to RECFILE per call.
  _nt_rec() { printf '#!/bin/sh\nprintf "called\\n" >> "%s"\nexit 0\n' "$2" > "$1"; chmod +x "$1"; }
  # _nt_called RECFILE — 1 when the stub ran at least once, else 0 (same -s test as the base checks).
  _nt_called() { if [ -s "$1" ]; then echo 1; else echo 0; fi; }
  # _nt_seen RECFILE — DOTNET_ROOT value(s) the ilspycmd stub recorded; empty when it never ran.
  _nt_seen() { if [ -f "$1" ]; then cat "$1"; fi; }

  # B1: --list must pass `-l c` (stub RECORD = args one per line).
  _nt_b1() {
    local d rc; d="$(_nt_box b1)"
    mkdir -p "$d/runtime/shared/Microsoft.NETCore.App"; : > "$d/test.dll"
    ILSPYCMD="$STUB" RECORD="$d/args" RSDD_DOTNET_ROOT="$d/runtime" \
      bash "$1" --list "$d/test.dll" >/dev/null 2>"$d/err"; rc=$?
    cat "$d/err"
    local a1 h=0; a1="$(sed -n '1p' "$d/args" 2>/dev/null)"
    if [ "$a1" = "-l" ] && [ "$(sed -n '2p' "$d/args" 2>/dev/null)" = "c" ]; then h=1; fi
    echo "B1_FACT=holds:$h arg1:$a1"
    return "$rc"
  }
  # P1: no /home/<user> literal in the SUT source.
  _nt_p1() {
    grep -q '/home/[a-z]' "$1"
    case $? in 0) echo "P1_FACT=holds:0" ;; 1) echo "P1_FACT=holds:1" ;; *) echo "P1_FACT=holds:error" ;; esac
    return 0
  }
  # P3: ILSPYCMD=executable overrides a different ilspycmd stub on PATH.
  _nt_p3() {
    local d rc; d="$(_nt_box p3)"
    mkdir -p "$d/bin" "$d/home" "$d/override" "$d/runtime/shared/Microsoft.NETCore.App"
    ln -s "$DIRNAME_BIN" "$d/bin/dirname"
    _nt_rec "$d/override/myilspy" "$d/ilspy.rec"; _nt_rec "$d/bin/ilspycmd" "$d/path.rec"
    touch "$d/ilspy.rec" "$d/path.rec" "$d/test.dll"
    ILSPYCMD="$d/override/myilspy" DOTNET_ROOT="$d/runtime" PATH="$d/bin" HOME="$d/home" \
      "$BASH_BIN" "$1" --list "$d/test.dll" >/dev/null 2>"$d/err"; rc=$?
    cat "$d/err"
    local h=0; if [ "$rc" -eq 0 ] && [ -s "$d/ilspy.rec" ] && ! [ -s "$d/path.rec" ]; then h=1; fi
    echo "P3_FACT=holds:$h ilspy:$(_nt_called "$d/ilspy.rec") path:$(_nt_called "$d/path.rec")"
    return "$rc"
  }
  # P4: ILSPYCMD=nonexistent -> exit 3, no fallthrough to PATH. DOTNET_ROOT is provided (as the original
  # teeth did) so a mutant that ignores ILSPYCMD gets past the DOTNET_ROOT guard and reaches exec.
  _nt_p4() {
    local d rc; d="$(_nt_box p4)"
    mkdir -p "$d/bin" "$d/home" "$d/runtime/shared/Microsoft.NETCore.App"
    ln -s "$DIRNAME_BIN" "$d/bin/dirname"
    _nt_rec "$d/bin/ilspycmd" "$d/p4.rec"; touch "$d/p4.rec" "$d/test.dll"
    ILSPYCMD="$d/nonexistent" DOTNET_ROOT="$d/runtime" PATH="$d/bin" HOME="$d/home" \
      "$BASH_BIN" "$1" --list "$d/test.dll" >/dev/null 2>"$d/err"; rc=$?
    cat "$d/err"
    local h=0; if [ "$rc" -eq 3 ] && ! [ -s "$d/p4.rec" ]; then h=1; fi
    echo "P4_FACT=holds:$h path:$(_nt_called "$d/p4.rec")"
    return "$rc"
  }
  # D1: DOTNET_ROOT derived from the dotnet binary and exported to ilspycmd.
  _nt_d1() {
    local d rc seen; d="$(_nt_box d1)"
    mkdir -p "$d/bin" "$d/home" "$d/fake_root/shared/Microsoft.NETCore.App"
    printf '#!/bin/sh\nexit 0\n' > "$d/fake_root/dotnet"; chmod +x "$d/fake_root/dotnet"
    ln -s "$DIRNAME_BIN" "$d/bin/dirname"; ln -s "$REALPATH_BIN" "$d/bin/realpath"
    ln -s "$d/fake_root/dotnet" "$d/bin/dotnet"
    touch "$d/ilspy.env" "$d/test.dll"
    cat > "$d/bin/ilspycmd" <<SH
#!/bin/sh
[ "\$1" = "--version" ] && exit 0
printf '%s\n' "\${DOTNET_ROOT:-UNSET}" >> "$d/ilspy.env"
exit 0
SH
    chmod +x "$d/bin/ilspycmd"
    env -u ILSPYCMD -u DOTNET_ROOT -u RSDD_DOTNET_ROOT PATH="$d/bin" HOME="$d/home" \
      "$BASH_BIN" "$1" --list "$d/test.dll" >/dev/null 2>"$d/err"; rc=$?
    cat "$d/err"
    seen="$(_nt_seen "$d/ilspy.env")"
    local h=0 s=OTHER
    if [ "$rc" -eq 0 ] && [ "$seen" = "$d/fake_root" ]; then h=1; fi
    if [ -z "$seen" ]; then s=NONE; elif [ "$seen" = UNSET ]; then s=UNSET; elif [ "$seen" = "$d/fake_root" ]; then s=ROOT; fi
    echo "D1_FACT=holds:$h seen:$s"
    return "$rc"
  }
  # D2: nothing resolves DOTNET_ROOT -> exit 3 with DOTNET_ROOT named on stderr.
  _nt_d2() {
    local d rc; d="$(_nt_box d2)"
    mkdir -p "$d/bin" "$d/home"; ln -s "$DIRNAME_BIN" "$d/bin/dirname"
    printf '#!/bin/sh\nexit 0\n' > "$d/bin/ilspycmd"; chmod +x "$d/bin/ilspycmd"; touch "$d/test.dll"
    env -u ILSPYCMD -u DOTNET_ROOT -u RSDD_DOTNET_ROOT PATH="$d/bin" HOME="$d/home" \
      "$BASH_BIN" "$1" --list "$d/test.dll" 2>"$d/err" >/dev/null; rc=$?
    cat "$d/err"
    local n=0 h=0
    if grep -qi 'DOTNET_ROOT' "$d/err"; then n=1; fi
    if [ "$rc" -eq 3 ] && [ "$n" -eq 1 ]; then h=1; fi
    echo "D2_FACT=holds:$h names:$n"
    return "$rc"
  }
  # D1-empty: DOTNET_ROOT has shared/Microsoft.NETCore.App but `ilspycmd --version` fails with it -> exit 3.
  _nt_d1e() {
    local d rc; d="$(_nt_box d1e)"
    mkdir -p "$d/bin" "$d/home" "$d/bad_root/shared/Microsoft.NETCore.App"; ln -s "$DIRNAME_BIN" "$d/bin/dirname"
    printf '#!/bin/sh\n[ "$1" = "--version" ] && exit 1\nexit 0\n' > "$d/bin/ilspycmd"; chmod +x "$d/bin/ilspycmd"
    touch "$d/test.dll"
    env -u ILSPYCMD -u RSDD_DOTNET_ROOT DOTNET_ROOT="$d/bad_root" PATH="$d/bin" HOME="$d/home" \
      "$BASH_BIN" "$1" --list "$d/test.dll" >/dev/null 2>"$d/err"; rc=$?
    cat "$d/err"
    if [ "$rc" -eq 3 ]; then echo "D1E_FACT=holds:1"; else echo "D1E_FACT=holds:0"; fi
    return "$rc"
  }
  # D2-rsdd-bad: unusable RSDD_DOTNET_ROOT must exit 3 and NOT fall through to the valid ambient DOTNET_ROOT.
  _nt_d2r() {
    local d rc seen; d="$(_nt_box d2r)"
    mkdir -p "$d/bin" "$d/home" "$d/bad_root/shared/Microsoft.NETCore.App" "$d/good_root/shared/Microsoft.NETCore.App"
    ln -s "$DIRNAME_BIN" "$d/bin/dirname"; touch "$d/ilspy.rec" "$d/test.dll"
    cat > "$d/bin/ilspycmd" <<SH
#!/bin/sh
if [ "\$1" = "--version" ]; then
  [ "\${DOTNET_ROOT:-}" = "$d/good_root" ] && exit 0
  exit 1
fi
printf '%s\n' "\${DOTNET_ROOT:-UNSET}" >> "$d/ilspy.rec"
exit 0
SH
    chmod +x "$d/bin/ilspycmd"
    env -u ILSPYCMD RSDD_DOTNET_ROOT="$d/bad_root" DOTNET_ROOT="$d/good_root" PATH="$d/bin" HOME="$d/home" \
      "$BASH_BIN" "$1" --list "$d/test.dll" >/dev/null 2>"$d/err"; rc=$?
    cat "$d/err"
    seen="$(_nt_seen "$d/ilspy.rec")"
    local h=0 s=OTHER
    if [ "$rc" -eq 3 ] && [ -z "$seen" ]; then h=1; fi
    if [ -z "$seen" ]; then s=NONE; elif [ "$seen" = "$d/good_root" ]; then s=GOOD; fi
    echo "D2R_FACT=holds:$h seen:$s"
    return "$rc"
  }
  # D3: RSDD_DOTNET_ROOT override honoured and exported as DOTNET_ROOT.
  _nt_d3() {
    local d rc seen; d="$(_nt_box d3)"
    mkdir -p "$d/bin" "$d/home" "$d/override_root/shared/Microsoft.NETCore.App"; ln -s "$DIRNAME_BIN" "$d/bin/dirname"
    touch "$d/ilspy.env" "$d/test.dll"
    cat > "$d/bin/ilspycmd" <<SH
#!/bin/sh
[ "\$1" = "--version" ] && exit 0
printf '%s\n' "\${DOTNET_ROOT:-UNSET}" >> "$d/ilspy.env"
exit 0
SH
    chmod +x "$d/bin/ilspycmd"
    env -u ILSPYCMD -u DOTNET_ROOT RSDD_DOTNET_ROOT="$d/override_root" PATH="$d/bin" HOME="$d/home" \
      "$BASH_BIN" "$1" --list "$d/test.dll" >/dev/null 2>"$d/err"; rc=$?
    cat "$d/err"
    seen="$(_nt_seen "$d/ilspy.env")"
    local h=0 s=OTHER u=0
    if [ "$rc" -eq 0 ] && [ "$seen" = "$d/override_root" ]; then h=1; fi
    if [ -z "$seen" ]; then s=NONE; elif [ "$seen" = UNSET ]; then s=UNSET; elif [ "$seen" = "$d/override_root" ]; then s=OVERRIDE; fi
    if grep -q 'DOTNET_ROOT could not be resolved' "$d/err"; then u=1; fi
    echo "D3_FACT=holds:$h seen:$s unresolved:$u"
    return "$rc"
  }
  # NE1: ilspycmd exits 0 but writes no .cs -> wrapper exits non-zero and prints no OK line.
  _nt_ne1() {
    local d rc; d="$(_nt_box ne1)"
    mkdir -p "$d/runtime/shared/Microsoft.NETCore.App" "$d/out"
    printf '#!/bin/sh\nexit 0\n' > "$d/ilspycmd"; chmod +x "$d/ilspycmd"; touch "$d/test.dll"
    ILSPYCMD="$d/ilspycmd" RSDD_DOTNET_ROOT="$d/runtime" \
      bash "$1" "$d/test.dll" "$d/out" >"$d/stdout" 2>"$d/stderr"; rc=$?
    cat "$d/stderr"
    local o=0 h=0
    if grep -q '^OK' "$d/stdout"; then o=1; fi
    if [ "$rc" -ne 0 ] && [ "$o" -eq 0 ]; then h=1; fi
    echo "NE1_FACT=holds:$h ok:$o"
    return "$rc"
  }

  echo "-- teeth: mutate -l c to --list-types; expect B1 to now fail --"
  if mks "teeth B1: build" "$SUT" "$MUT/b1" 's/-l c/--list-types/'; then
    tt "teeth B1: --list-types mutant breaks B1" 0 0 "$MUT/b1/decompile-net.sh" --orig "$SUT" \
      --good-has '^B1_FACT=holds:1 arg1:-l$' --bad-has '^B1_FACT=holds:0 arg1:--list-types$' --bad-lacks "$CRASH_RE" -- _nt_b1 @SUT@
  fi

  echo "-- teeth: mutant reintroduces /home/<user> literal → P1 must go RED --"
  if mks "teeth P1: build" "$SUT" "$MUT/p1" \
      's|# For Siemens TIA Openness (api-openness, openness-labs/tools) and other managed binaries\.|# For Siemens TIA Openness /home/testuser-mutant (portability check).|'; then
    tt "teeth P1: /home/<user> literal mutant breaks P1" 0 0 "$MUT/p1/decompile-net.sh" --orig "$SUT" \
      --good-has '^P1_FACT=holds:1$' --bad-has '^P1_FACT=holds:0$' -- _nt_p1 @SUT@
  fi

  echo "-- teeth: mutant ignores ILSPYCMD → P3 and P4 must go RED --"
  # The mutant is lib/tool-env.sh with the ILSPYCMD guard disabled; the SUT copy staged beside it
  # (HERE=$MUT/t1) sources that lib. The staged SUT is byte-identical to the original by design.
  if ! _nt_stage_sut "$MUT/t1"; then
    fail=$((fail+1)); printf '  FAIL  teeth P3/P4: could not stage SUT copy under %s\n' "$MUT/t1"
  elif mk "teeth P3/P4: build" "$HERE/../lib/tool-env.sh" "$MUT/t1/lib/tool-env.sh" \
          's/if \[\[ -v ILSPYCMD \]\]; then/if false; then/'; then
    # P3: ILSPYCMD ignored → the PATH stub runs and the ILSPYCMD stub stays idle.
    tt "teeth P3: ILSPYCMD-ignored mutant breaks P3" 0 0 "$MUT/t1/decompile-net.sh" --orig "$SUT" \
      --good-has '^P3_FACT=holds:1 ilspy:1 path:0$' --bad-has '^P3_FACT=holds:0 ilspy:0 path:1$' --bad-lacks "$CRASH_RE" -- _nt_p3 @SUT@
    # P4: ILSPYCMD=nonexistent ignored → PATH stub runs, exit 0 instead of 3.
    tt "teeth P4: ILSPYCMD-ignored mutant breaks P4" 3 0 "$MUT/t1/decompile-net.sh" --orig "$SUT" \
      --good-has '^P4_FACT=holds:1 path:0$' --bad-has '^P4_FACT=holds:0 path:1$' --bad-lacks "$CRASH_RE" -- _nt_p4 @SUT@
  fi

  # D1 TEETH — mutant removes 'export DOTNET_ROOT'; ilspycmd must see DOTNET_ROOT=UNSET.
  echo "-- teeth: mutant removes 'export DOTNET_ROOT'; expect D1 to go RED --"
  if mks "teeth D1: build" "$SUT" "$MUT/d1" '/^export DOTNET_ROOT$/d'; then
    tt "teeth D1: no-export mutant breaks D1" 0 0 "$MUT/d1/decompile-net.sh" --orig "$SUT" \
      --good-has '^D1_FACT=holds:1 seen:ROOT$' --bad-has '^D1_FACT=holds:0 seen:UNSET$' \
      --bad-lacks "$CRASH_RE" -- _nt_d1 @SUT@
  fi

  # D2 TEETH — mutant changes error exit 3 to exit 0; D2 must go RED.
  echo "-- teeth: mutant changes DOTNET_ROOT error exit 3 to exit 0; expect D2 to go RED --"
  if mks "teeth D2: build" "$SUT" "$MUT/d2" 's/exit 3 # DOTNET_ROOT_UNRESOLVED/exit 0 # DOTNET_ROOT_UNRESOLVED/'; then
    tt "teeth D2: exit-0 mutant breaks D2" 3 0 "$MUT/d2/decompile-net.sh" --orig "$SUT" \
      --good-has '^D2_FACT=holds:1 names:1$' --bad-has '^D2_FACT=holds:0 names:1$' --bad-lacks "$CRASH_RE" -- _nt_d2 @SUT@
  fi

  # Library mutants (the probe / RSDD_DOTNET_ROOT logic lives in lib/tool-env.sh): the mutant SUT dir
  # holds an unmodified SUT copy plus the mutated lib/tool-env.sh it resolves relative to $0.
  # D1-empty TEETH — replacing the probe body with a bare -d check accepts an empty/unusable runtime.
  echo "-- teeth: mutant replaces _rsdd_dotnet_probe in lib/tool-env.sh with bare -d check; D1-empty must go RED --"
  if ! _nt_stage_sut "$MUT/d1e"; then
    fail=$((fail+1)); printf '  FAIL  teeth D1-empty: could not stage SUT copy under %s\n' "$MUT/d1e"
  elif ! _nt_pysub "$MUT/d1e/lib/tool-env.sh" '_rsdd_dotnet_probe\(\) \{.*?^}' \
         $'_rsdd_dotnet_probe() {\n  [ -d "$1/shared/Microsoft.NETCore.App" ]\n}'; then
    fail=$((fail+1)); printf '  FAIL  teeth D1-empty: build: python substitution did not apply exactly once\n'
  elif mkb "teeth D1-empty: build" "$HERE/../lib/tool-env.sh" "$MUT/d1e/lib/tool-env.sh"; then
    tt "teeth D1-empty: bare -d probe mutant breaks D1-empty" 3 0 "$MUT/d1e/decompile-net.sh" --orig "$SUT" \
      --good-has '^D1E_FACT=holds:1$' --bad-has '^D1E_FACT=holds:0$' --bad-lacks "$CRASH_RE" -- _nt_d1e @SUT@
  fi

  # D2-rsdd-bad TEETH — removing the RSDD_DOTNET_ROOT fail-closed block lets the resolver fall through
  # to the ambient DOTNET_ROOT.
  echo "-- teeth: mutant removes RSDD_DOTNET_ROOT fail-closed block from lib/tool-env.sh; D2-rsdd-bad must go RED --"
  if ! _nt_stage_sut "$MUT/d2r"; then
    fail=$((fail+1)); printf '  FAIL  teeth D2-rsdd-bad: could not stage SUT copy under %s\n' "$MUT/d2r"
  elif ! _nt_pysub "$MUT/d2r/lib/tool-env.sh" '  # RSDD_DOTNET_ROOT:.*?^  fi\n\n' ''; then
    fail=$((fail+1)); printf '  FAIL  teeth D2-rsdd-bad: build: python substitution did not apply exactly once\n'
  elif mkb "teeth D2-rsdd-bad: build" "$HERE/../lib/tool-env.sh" "$MUT/d2r/lib/tool-env.sh"; then
    tt "teeth D2-rsdd-bad: fall-through mutant breaks D2-rsdd-bad" 3 0 "$MUT/d2r/decompile-net.sh" --orig "$SUT" \
      --good-has '^D2R_FACT=holds:1 seen:NONE$' --bad-has '^D2R_FACT=holds:0 seen:GOOD$' --bad-lacks "$CRASH_RE" -- _nt_d2r @SUT@
  fi

  # D3 TEETH — renaming RSDD_DOTNET_ROOT in the lib makes the resolver ignore the override.
  echo "-- teeth: mutant renames RSDD_DOTNET_ROOT in lib/tool-env.sh; expect D3 to go RED --"
  if ! _nt_stage_sut "$MUT/d3"; then
    fail=$((fail+1)); printf '  FAIL  teeth D3: could not stage SUT copy under %s\n' "$MUT/d3"
  elif mk "teeth D3: build" "$HERE/../lib/tool-env.sh" "$MUT/d3/lib/tool-env.sh" 's/RSDD_DOTNET_ROOT/RSDD_DOTNET_ROOT_DISABLED/g'; then
    tt "teeth D3: renamed-override mutant breaks D3" 0 3 "$MUT/d3/decompile-net.sh" --orig "$SUT" \
      --good-has '^D3_FACT=holds:1 seen:OVERRIDE unresolved:0$' \
      --bad-has '^D3_FACT=holds:0 seen:NONE unresolved:1$' --bad-lacks "$CRASH_RE" -- _nt_d3 @SUT@
  fi

  # MNE1 TEETH — remove the .cs non-empty guard from the SUT; NE1 must go RED (the mutant prints OK).
  echo "-- MNE1 mutation: remove .cs non-empty guard; NE1 must go RED --"
  if mks "MNE1: build" "$SUT" "$MUT/mne1" '/^\[ -n "\$(find "\$OUT" .*\.cs.*exit 1; }$/d'; then
    tt "MNE1-killed: guard-removed mutant exits 0+OK on no .cs → NE1 bites" 1 0 "$MUT/mne1/decompile-net.sh" --orig "$SUT" \
      --good-has '^NE1_FACT=holds:1 ok:0$' --bad-has '^NE1_FACT=holds:0 ok:1$' --bad-lacks "$CRASH_RE" -- _nt_ne1 @SUT@
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
