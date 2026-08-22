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

# TEETH — prove that assertions fail against broken implementations.
if [ "${1:-}" = "--prove-teeth" ]; then
  # Mutant SUTs placed under $TMP compute HERE=$TMP and source $TMP/lib/tool-env.sh.
  # Provide the real tool-env.sh there so B1 mutant (which only patches the flag) runs correctly.
  mkdir -p "$TMP/lib"
  cp "$HERE/../lib/tool-env.sh" "$TMP/lib/"

  echo "-- teeth: mutate -l c to --list-types; expect B1 to now fail --"
  MUTANT_SUT="$TMP/decompile-net.MUTANT.sh"
  sed 's/-l c/--list-types/' "$SUT" > "$MUTANT_SUT"
  if ! grep -q -- '--list-types' "$MUTANT_SUT"; then
    no "teeth: could not build B1 mutant (flag not found — SUT drifted?)"
  else
    RECORD2="$TMP/mutant.args.txt"
    ILSPYCMD="$STUB" RECORD="$RECORD2" bash "$MUTANT_SUT" --list "$DLL" >/dev/null 2>&1
    if [ "$(sed -n '1p' "$RECORD2")" != "-l" ]; then
      ok "teeth B1: mutant uses --list-types (not -l c) → B1 goes RED"
    else
      no "teeth B1: mutant still emits -l c — B1 is THEATER"
    fi
  fi

  echo "-- teeth: mutant reintroduces /home/<user> literal → P1 must go RED --"
  orig_comment='# For Siemens TIA Openness (api-openness, openness-labs/tools) and other managed binaries.'
  mutant_comment='# For Siemens TIA Openness /home/testuser-mutant (portability check).'
  sut_content="$(cat "$SUT")"
  if [[ "$sut_content" != *"$orig_comment"* ]]; then
    no "teeth P1: anchor not found in SUT — drifted?"
  else
    MUTANT_SUT_P1="$TMP/decompile-net.MUTANT-literal.sh"
    printf '%s\n' "${sut_content//"$orig_comment"/"$mutant_comment"}" > "$MUTANT_SUT_P1"
    if grep -q '/home/[a-z]' "$MUTANT_SUT_P1"; then
      ok "teeth P1: literal found in mutant → P1 would go RED (has teeth)"
    else
      no "teeth P1: literal NOT found in mutant — P1 is THEATER"
    fi
  fi

  echo "-- teeth: mutant ignores ILSPYCMD → P3 and P4 must go RED --"
  orig_guard='  if [[ -v ILSPYCMD ]]; then'
  mutant_guard='  if false; then'
  env_content="$(cat "$HERE/../lib/tool-env.sh")"
  if [[ "$env_content" != *"$orig_guard"* ]]; then
    no "teeth P3/P4: ILSPYCMD guard anchor not found in tool-env.sh — drifted?"
  else
    # $TMP/t1/ is a separate context so its lib/ doesn't interfere with the B1 mutant's lib/.
    # Mutant SUT at $TMP/t1/ computes HERE=$TMP/t1 and sources $TMP/t1/lib/tool-env.sh
    # (the mutant resolver where ILSPYCMD is always ignored).
    mkdir -p "$TMP/t1/lib"
    printf '%s\n' "${env_content//"$orig_guard"/"$mutant_guard"}" > "$TMP/t1/lib/tool-env.sh"
    MUTANT_SUT_T1="$TMP/t1/decompile-net.MUTANT.sh"
    cp "$SUT" "$MUTANT_SUT_T1"

    # P3 on mutant: ILSPYCMD=executable — mutant ignores it → PATH stub runs, ILSPY stub idle.
    # DOTNET_ROOT is provided so the mutant gets past the DOTNET_ROOT guard and reaches exec.
    box_t1p3="$TMP/t1p3"; mkdir -p "$box_t1p3/bin" "$box_t1p3/home" "$box_t1p3/override" "$box_t1p3/runtime/shared/Microsoft.NETCore.App"
    ln -s "$DIRNAME_BIN" "$box_t1p3/bin/dirname"
    rec_t1_ilspy="$TMP/t1.ilspy.rec"; rec_t1_path="$TMP/t1.path.rec"
    touch "$rec_t1_ilspy" "$rec_t1_path"
    ilspy_stub_t1="$box_t1p3/override/myilspy"
    printf '#!/bin/sh\nprintf "called\\n" >> "%s"\nexit 0\n' "$rec_t1_ilspy" > "$ilspy_stub_t1"
    chmod +x "$ilspy_stub_t1"
    printf '#!/bin/sh\nprintf "called\\n" >> "%s"\nexit 0\n' "$rec_t1_path" > "$box_t1p3/bin/ilspycmd"
    chmod +x "$box_t1p3/bin/ilspycmd"
    dll_t1="$TMP/t1.dll"; touch "$dll_t1"
    ILSPYCMD="$ilspy_stub_t1" DOTNET_ROOT="$box_t1p3/runtime" PATH="$box_t1p3/bin" HOME="$box_t1p3/home" \
      "$BASH_BIN" "$MUTANT_SUT_T1" --list "$dll_t1" >/dev/null 2>&1; rc_t1p3=$?
    # P3 assertion: ILSPY stub called AND PATH stub NOT called. On mutant this FAILS.
    if ! ( [ "$rc_t1p3" -eq 0 ] && [ -s "$rec_t1_ilspy" ] && ! [ -s "$rec_t1_path" ] ); then
      ok "teeth P3: mutant breaks P3 (ILSPYCMD ignored → P3 goes RED)"
    else
      no "teeth P3: mutant did NOT break P3 — P3 is THEATER"
    fi

    # P4 on mutant: ILSPYCMD=nonexistent — mutant ignores it → PATH stub runs, exit 0 not 3.
    # DOTNET_ROOT is provided so the mutant reaches exec (stub calls → exit 0, not 3).
    box_t1p4="$TMP/t1p4"; mkdir -p "$box_t1p4/bin" "$box_t1p4/home" "$box_t1p4/runtime/shared/Microsoft.NETCore.App"
    ln -s "$DIRNAME_BIN" "$box_t1p4/bin/dirname"
    rec_t1p4="$TMP/t1p4.rec"; touch "$rec_t1p4"
    printf '#!/bin/sh\nprintf "called\\n" >> "%s"\nexit 0\n' "$rec_t1p4" > "$box_t1p4/bin/ilspycmd"
    chmod +x "$box_t1p4/bin/ilspycmd"
    dll_t1p4="$TMP/t1p4.dll"; touch "$dll_t1p4"
    ILSPYCMD="$box_t1p4/nonexistent" DOTNET_ROOT="$box_t1p4/runtime" PATH="$box_t1p4/bin" HOME="$box_t1p4/home" \
      "$BASH_BIN" "$MUTANT_SUT_T1" --list "$dll_t1p4" >/dev/null 2>&1; rc_t1p4=$?
    # P4 assertion: exit 3 AND PATH stub idle. On mutant this FAILS (exit 0, stub called).
    if ! ( [ "$rc_t1p4" -eq 3 ] && ! [ -s "$rec_t1p4" ] ); then
      ok "teeth P4: mutant breaks P4 (ILSPYCMD ignored → P4 goes RED)"
    else
      no "teeth P4: mutant did NOT break P4 — P4 is THEATER"
    fi
  fi

  # D1 TEETH — mutant removes 'export DOTNET_ROOT'; ilspycmd must see DOTNET_ROOT=UNSET.
  echo "-- teeth: mutant removes 'export DOTNET_ROOT'; expect D1 to go RED --"
  MUTANT_D1="$TMP/decompile-net.MUTANT-noexport.sh"
  sed '/^export DOTNET_ROOT$/d' "$SUT" > "$MUTANT_D1"
  if grep -q '^export DOTNET_ROOT$' "$MUTANT_D1"; then
    no "teeth D1: could not build mutant (export DOTNET_ROOT still present)"
  else
    box_td1="$TMP/td1"
    mkdir -p "$box_td1/bin" "$box_td1/home" "$box_td1/fake_root/shared/Microsoft.NETCore.App"
    printf '#!/bin/sh\nexit 0\n' > "$box_td1/fake_root/dotnet"
    chmod +x "$box_td1/fake_root/dotnet"
    ln -s "$DIRNAME_BIN"  "$box_td1/bin/dirname"
    ln -s "$REALPATH_BIN" "$box_td1/bin/realpath"
    ln -s "$box_td1/fake_root/dotnet" "$box_td1/bin/dotnet"
    rec_td1_env="$TMP/td1.ilspy.env"; touch "$rec_td1_env"
    dll_td1="$box_td1/test.dll"; touch "$dll_td1"
    cat > "$box_td1/bin/ilspycmd" <<SH
#!/bin/sh
[ "\$1" = "--version" ] && exit 0
printf '%s\n' "\${DOTNET_ROOT:-UNSET}" >> "$rec_td1_env"
exit 0
SH
    chmod +x "$box_td1/bin/ilspycmd"
    env -u ILSPYCMD -u DOTNET_ROOT -u RSDD_DOTNET_ROOT \
      PATH="$box_td1/bin" HOME="$box_td1/home" \
      "$BASH_BIN" "$MUTANT_D1" --list "$dll_td1" >/dev/null 2>&1; rc_td1=$?
    dotnet_root_td1="$(cat "$rec_td1_env" 2>/dev/null || echo UNSET)"
    # D1 assertion requires rc=0 AND DOTNET_ROOT=fake_root. Mutant: DOTNET_ROOT=UNSET → D1 fails.
    if ! ( [ "$rc_td1" -eq 0 ] && [ "$dotnet_root_td1" = "$box_td1/fake_root" ] ); then
      ok "teeth D1: mutant breaks D1 (no export → DOTNET_ROOT unseen → D1 goes RED)"
    else
      no "teeth D1: mutant did NOT break D1 — D1 is THEATER"
    fi
  fi

  # D2 TEETH — mutant changes error exit 3 to exit 0; D2 must go RED.
  echo "-- teeth: mutant changes DOTNET_ROOT error exit 3 to exit 0; expect D2 to go RED --"
  MUTANT_D2="$TMP/decompile-net.MUTANT-exit0.sh"
  sed 's/exit 3 # DOTNET_ROOT_UNRESOLVED/exit 0 # DOTNET_ROOT_UNRESOLVED/' "$SUT" > "$MUTANT_D2"
  if ! grep -q 'exit 0 # DOTNET_ROOT_UNRESOLVED' "$MUTANT_D2"; then
    no "teeth D2: could not build mutant (marker not found — SUT drifted?)"
  else
    box_td2="$TMP/td2"
    mkdir -p "$box_td2/bin" "$box_td2/home"
    ln -s "$DIRNAME_BIN" "$box_td2/bin/dirname"
    printf '#!/bin/sh\nexit 0\n' > "$box_td2/bin/ilspycmd"
    chmod +x "$box_td2/bin/ilspycmd"
    dll_td2="$box_td2/test.dll"; touch "$dll_td2"
    err_td2="$TMP/td2.err"
    env -u ILSPYCMD -u DOTNET_ROOT -u RSDD_DOTNET_ROOT \
      PATH="$box_td2/bin" HOME="$box_td2/home" \
      "$BASH_BIN" "$MUTANT_D2" --list "$dll_td2" 2>"$err_td2" >/dev/null; rc_td2=$?
    # D2 assertion: rc=3 AND DOTNET_ROOT in stderr. Mutant exits 0 → D2 fails.
    if ! ( [ "$rc_td2" -eq 3 ] && grep -qi 'DOTNET_ROOT' "$err_td2" 2>/dev/null ); then
      ok "teeth D2: mutant breaks D2 (exit 0 instead of 3 → D2 goes RED)"
    else
      no "teeth D2: mutant did NOT break D2 — D2 is THEATER"
    fi
  fi

  # D1-empty TEETH — _rsdd_dotnet_probe is now in lib/tool-env.sh; mutate the lib.
  # Replacing the probe body with a bare -d check makes the mutant accept an empty/unusable
  # runtime → D1-empty must go RED.
  echo "-- teeth: mutant replaces _rsdd_dotnet_probe in lib/tool-env.sh with bare -d check; D1-empty must go RED --"
  MUTANT_D1E_DIR="$TMP/td1e_mut"
  mkdir -p "$MUTANT_D1E_DIR/lib"
  python3 - "$HERE/../lib/tool-env.sh" "$MUTANT_D1E_DIR/lib/tool-env.sh" <<'PYEOF'
import sys, re
text = open(sys.argv[1]).read()
# Replace the _rsdd_dotnet_probe function body with a bare directory test only (no ilspy run)
result = re.sub(
    r'_rsdd_dotnet_probe\(\) \{.*?^}',
    '_rsdd_dotnet_probe() {\n  [ -d "$1/shared/Microsoft.NETCore.App" ]\n}',
    text, flags=re.MULTILINE | re.DOTALL)
open(sys.argv[2], 'w').write(result)
PYEOF
  # Copy real SUT into mutant dir so HERE=$MUTANT_D1E_DIR → sources the mutant lib.
  cp "$SUT" "$MUTANT_D1E_DIR/decompile-net.sh"
  if grep -qF '"$ilspy" --version' "$MUTANT_D1E_DIR/lib/tool-env.sh"; then
    no "teeth D1-empty: mutant lib still contains ilspy --version probe — substitution failed"
  else
    box_td1e="$TMP/td1e"
    mkdir -p "$box_td1e/bin" "$box_td1e/home" "$box_td1e/bad_root/shared/Microsoft.NETCore.App"
    ln -s "$DIRNAME_BIN" "$box_td1e/bin/dirname"
    cat > "$box_td1e/bin/ilspycmd" <<'SH'
#!/bin/sh
[ "$1" = "--version" ] && exit 1
exit 0
SH
    chmod +x "$box_td1e/bin/ilspycmd"
    dll_td1e="$box_td1e/test.dll"; touch "$dll_td1e"
    env -u ILSPYCMD -u RSDD_DOTNET_ROOT \
      DOTNET_ROOT="$box_td1e/bad_root" \
      PATH="$box_td1e/bin" HOME="$box_td1e/home" \
      "$BASH_BIN" "$MUTANT_D1E_DIR/decompile-net.sh" --list "$dll_td1e" >/dev/null 2>&1; rc_td1e=$?
    # D1-empty asserts exit 3. Mutant accepts the empty root (bare -d only) → exits 0 → D1-empty RED.
    if ! [ "$rc_td1e" -eq 3 ]; then
      ok "teeth D1-empty: mutant lib (bare -d) accepts unusable root → D1-empty goes RED"
    else
      no "teeth D1-empty: mutant still exits 3 — D1-empty has no teeth"
    fi
  fi

  # D2-rsdd-bad TEETH — RSDD_DOTNET_ROOT block is now in lib/tool-env.sh; mutate the lib.
  # Removing the fail-closed block lets the function fall through to DOTNET_ROOT → D2-rsdd-bad must go RED.
  echo "-- teeth: mutant removes RSDD_DOTNET_ROOT fail-closed block from lib/tool-env.sh; D2-rsdd-bad must go RED --"
  MUTANT_D2R_DIR="$TMP/td2r_mut"
  mkdir -p "$MUTANT_D2R_DIR/lib"
  python3 - "$HERE/../lib/tool-env.sh" "$MUTANT_D2R_DIR/lib/tool-env.sh" <<'PYEOF'
import sys, re
text = open(sys.argv[1]).read()
# Remove the RSDD_DOTNET_ROOT special-case block from rsdd_resolve_dotnet_root so it falls through
result = re.sub(
    r'  # RSDD_DOTNET_ROOT:.*?^  fi\n\n',
    '',
    text, flags=re.MULTILINE | re.DOTALL)
open(sys.argv[2], 'w').write(result)
PYEOF
  cp "$SUT" "$MUTANT_D2R_DIR/decompile-net.sh"
  if grep -q 'Fix or unset RSDD_DOTNET_ROOT' "$MUTANT_D2R_DIR/lib/tool-env.sh" 2>/dev/null; then
    no "teeth D2-rsdd-bad: mutant lib still has fail-closed message — substitution failed"
  else
    box_td2r="$TMP/td2r"
    mkdir -p "$box_td2r/bin" "$box_td2r/home" \
             "$box_td2r/bad_root/shared/Microsoft.NETCore.App" \
             "$box_td2r/good_root/shared/Microsoft.NETCore.App"
    ln -s "$DIRNAME_BIN" "$box_td2r/bin/dirname"
    rec_td2r="$box_td2r/ilspy.rec"; touch "$rec_td2r"
    cat > "$box_td2r/bin/ilspycmd" <<SH
#!/bin/sh
if [ "\$1" = "--version" ]; then
  [ "\${DOTNET_ROOT:-}" = "$box_td2r/good_root" ] && exit 0
  exit 1
fi
printf '%s\n' "\${DOTNET_ROOT:-UNSET}" >> "$rec_td2r"
exit 0
SH
    chmod +x "$box_td2r/bin/ilspycmd"
    dll_td2r="$box_td2r/test.dll"; touch "$dll_td2r"
    env -u ILSPYCMD \
      RSDD_DOTNET_ROOT="$box_td2r/bad_root" \
      DOTNET_ROOT="$box_td2r/good_root" \
      PATH="$box_td2r/bin" HOME="$box_td2r/home" \
      "$BASH_BIN" "$MUTANT_D2R_DIR/decompile-net.sh" --list "$dll_td2r" >/dev/null 2>&1; rc_td2r=$?
    dotnet_seen_td2r="$(cat "$rec_td2r" 2>/dev/null || echo UNSET)"
    # D2-rsdd-bad: exit 3 AND no DOTNET_ROOT used.
    # Mutant falls through to DOTNET_ROOT (good_root) → exits 0 + DOTNET_ROOT seen → RED.
    if ! ( [ "$rc_td2r" -eq 3 ] && [ -z "$dotnet_seen_td2r" ] ); then
      ok "teeth D2-rsdd-bad: mutant lib (fall-through) reaches DOTNET_ROOT → D2-rsdd-bad goes RED"
    else
      no "teeth D2-rsdd-bad: mutant still exits 3 + no DOTNET_ROOT — D2-rsdd-bad has no teeth"
    fi
  fi

  # D3 TEETH — RSDD_DOTNET_ROOT check is now in lib/tool-env.sh; mutate the lib.
  # Renaming RSDD_DOTNET_ROOT makes the resolver ignore the override → D3 must go RED.
  echo "-- teeth: mutant renames RSDD_DOTNET_ROOT in lib/tool-env.sh; expect D3 to go RED --"
  MUTANT_D3_DIR="$TMP/td3_mut"
  mkdir -p "$MUTANT_D3_DIR/lib"
  sed 's/RSDD_DOTNET_ROOT/RSDD_DOTNET_ROOT_DISABLED/g' "$HERE/../lib/tool-env.sh" \
    > "$MUTANT_D3_DIR/lib/tool-env.sh"
  cp "$SUT" "$MUTANT_D3_DIR/decompile-net.sh"
  if ! grep -q 'RSDD_DOTNET_ROOT_DISABLED' "$MUTANT_D3_DIR/lib/tool-env.sh"; then
    no "teeth D3: could not build mutant (RSDD_DOTNET_ROOT not found in lib — drifted?)"
  else
    box_td3="$TMP/td3"
    mkdir -p "$box_td3/bin" "$box_td3/home" "$box_td3/override_root/shared/Microsoft.NETCore.App"
    ln -s "$DIRNAME_BIN" "$box_td3/bin/dirname"
    rec_td3_env="$TMP/td3.ilspy.env"; touch "$rec_td3_env"
    dll_td3="$box_td3/test.dll"; touch "$dll_td3"
    cat > "$box_td3/bin/ilspycmd" <<SH
#!/bin/sh
[ "\$1" = "--version" ] && exit 0
printf '%s\n' "\${DOTNET_ROOT:-UNSET}" >> "$rec_td3_env"
exit 0
SH
    chmod +x "$box_td3/bin/ilspycmd"
    env -u ILSPYCMD -u DOTNET_ROOT \
      RSDD_DOTNET_ROOT="$box_td3/override_root" \
      PATH="$box_td3/bin" HOME="$box_td3/home" \
      "$BASH_BIN" "$MUTANT_D3_DIR/decompile-net.sh" --list "$dll_td3" >/dev/null 2>&1; rc_td3=$?
    dotnet_root_td3="$(cat "$rec_td3_env" 2>/dev/null || echo UNSET)"
    # D3 assertion: rc=0 AND DOTNET_ROOT=override_root. Mutant ignores RSDD_DOTNET_ROOT → exit 3.
    if ! ( [ "$rc_td3" -eq 0 ] && [ "$dotnet_root_td3" = "$box_td3/override_root" ] ); then
      ok "teeth D3: mutant lib (RSDD_DOTNET_ROOT renamed) breaks D3 → D3 goes RED"
    else
      no "teeth D3: mutant did NOT break D3 — D3 is THEATER"
    fi
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
