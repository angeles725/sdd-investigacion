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
box_p2="$TMP/p2"; mkdir -p "$box_p2/bin" "$box_p2/home"
ln -s "$DIRNAME_BIN" "$box_p2/bin/dirname"
rec_p2="$box_p2/p2.rec"; touch "$rec_p2"
printf '#!/bin/sh\nprintf "called\\n" >> "%s"\nexit 0\n' "$rec_p2" > "$box_p2/bin/ilspycmd"
chmod +x "$box_p2/bin/ilspycmd"
dll_p2="$box_p2/test.dll"; touch "$dll_p2"
env -u ILSPYCMD PATH="$box_p2/bin" HOME="$box_p2/home" \
  "$BASH_BIN" "$SUT" --list "$dll_p2" >/dev/null 2>&1; rc_p2=$?
if [ "$rc_p2" -eq 0 ] && [ -s "$rec_p2" ]; then
  ok "P2: PATH resolution: ilspycmd found via PATH when ILSPYCMD unset"
else
  no "P2: PATH resolution: exit=$rc_p2 rec=$(cat "$rec_p2" 2>/dev/null || echo empty)"
fi

# P3 — ILSPYCMD=executable is authoritative (overrides a different stub on PATH).
box_p3="$TMP/p3"; mkdir -p "$box_p3/bin" "$box_p3/home" "$box_p3/override"
ln -s "$DIRNAME_BIN" "$box_p3/bin/dirname"
rec_p3_ilspy="$box_p3/ilspy.rec"; rec_p3_path="$box_p3/path.rec"
touch "$rec_p3_ilspy" "$rec_p3_path"
printf '#!/bin/sh\nprintf "called\\n" >> "%s"\nexit 0\n' "$rec_p3_path" > "$box_p3/bin/ilspycmd"
chmod +x "$box_p3/bin/ilspycmd"
ilspy_stub_p3="$box_p3/override/myilspy"
printf '#!/bin/sh\nprintf "called\\n" >> "%s"\nexit 0\n' "$rec_p3_ilspy" > "$ilspy_stub_p3"
chmod +x "$ilspy_stub_p3"
dll_p3="$box_p3/test.dll"; touch "$dll_p3"
ILSPYCMD="$ilspy_stub_p3" PATH="$box_p3/bin" HOME="$box_p3/home" \
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
    box_t1p3="$TMP/t1p3"; mkdir -p "$box_t1p3/bin" "$box_t1p3/home" "$box_t1p3/override"
    ln -s "$DIRNAME_BIN" "$box_t1p3/bin/dirname"
    rec_t1_ilspy="$TMP/t1.ilspy.rec"; rec_t1_path="$TMP/t1.path.rec"
    touch "$rec_t1_ilspy" "$rec_t1_path"
    ilspy_stub_t1="$box_t1p3/override/myilspy"
    printf '#!/bin/sh\nprintf "called\\n" >> "%s"\nexit 0\n' "$rec_t1_ilspy" > "$ilspy_stub_t1"
    chmod +x "$ilspy_stub_t1"
    printf '#!/bin/sh\nprintf "called\\n" >> "%s"\nexit 0\n' "$rec_t1_path" > "$box_t1p3/bin/ilspycmd"
    chmod +x "$box_t1p3/bin/ilspycmd"
    dll_t1="$TMP/t1.dll"; touch "$dll_t1"
    ILSPYCMD="$ilspy_stub_t1" PATH="$box_t1p3/bin" HOME="$box_t1p3/home" \
      "$BASH_BIN" "$MUTANT_SUT_T1" --list "$dll_t1" >/dev/null 2>&1; rc_t1p3=$?
    # P3 assertion: ILSPY stub called AND PATH stub NOT called. On mutant this FAILS.
    if ! ( [ "$rc_t1p3" -eq 0 ] && [ -s "$rec_t1_ilspy" ] && ! [ -s "$rec_t1_path" ] ); then
      ok "teeth P3: mutant breaks P3 (ILSPYCMD ignored → P3 goes RED)"
    else
      no "teeth P3: mutant did NOT break P3 — P3 is THEATER"
    fi

    # P4 on mutant: ILSPYCMD=nonexistent — mutant ignores it → PATH stub runs, exit 0 not 3.
    box_t1p4="$TMP/t1p4"; mkdir -p "$box_t1p4/bin" "$box_t1p4/home"
    ln -s "$DIRNAME_BIN" "$box_t1p4/bin/dirname"
    rec_t1p4="$TMP/t1p4.rec"; touch "$rec_t1p4"
    printf '#!/bin/sh\nprintf "called\\n" >> "%s"\nexit 0\n' "$rec_t1p4" > "$box_t1p4/bin/ilspycmd"
    chmod +x "$box_t1p4/bin/ilspycmd"
    dll_t1p4="$TMP/t1p4.dll"; touch "$dll_t1p4"
    ILSPYCMD="$box_t1p4/nonexistent" PATH="$box_t1p4/bin" HOME="$box_t1p4/home" \
      "$BASH_BIN" "$MUTANT_SUT_T1" --list "$dll_t1p4" >/dev/null 2>&1; rc_t1p4=$?
    # P4 assertion: exit 3 AND PATH stub idle. On mutant this FAILS.
    if ! ( [ "$rc_t1p4" -eq 3 ] && ! [ -s "$rec_t1p4" ] ); then
      ok "teeth P4: mutant breaks P4 (ILSPYCMD ignored → P4 goes RED)"
    else
      no "teeth P4: mutant did NOT break P4 — P4 is THEATER"
    fi
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
