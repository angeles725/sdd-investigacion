#!/usr/bin/env bash
# detect-tools.test.sh — contract for detect-tools.sh --require gate.
#
# Covers the three-state discipline (§7):
#   MISSING      — tool genuinely absent → --require fails loud, names tool
#   UNUSABLE     — found but smoke test failed → --require fails loud (distinct message)
#   PROBE_FAILED — probe could not run (timeout/127) → --require fails as "could not determine"
#                  and must NOT be classified as a clean MISSING
#
# Tests: (a) no --require → exit 0 unchanged; (b) --require present → exit 0;
#        (c) --require absent → non-zero + loud stderr naming tool;
#        (d) probe-failed → non-zero + "could not determine" + NOT MISSING in report;
#        (e) unknown tool name → exit 2.
#
# Usage: detect-tools.test.sh [--prove-teeth]
# Exit:  0 = all pass · 1 = regression · 2 = harness error
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DETECT="$HERE/../detect-tools.sh"
[ -f "$DETECT" ] || { echo "FATAL: script under test not found: $DETECT" >&2; exit 2; }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
pass=0; fail=0
ok() { printf '  PASS  %-60s %s\n' "$1" "${2:-}"; pass=$((pass+1)); }
no() { printf '  FAIL  %-60s %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

mkexec() {
  local p="$1" body="$2"
  mkdir -p "$(dirname "$p")"
  printf '#!/usr/bin/env bash\n%s\n' "$body" > "$p"
  chmod +x "$p"
}

echo "== detect-tools.test.sh =="

# Hermetic env: redirect HOME and BREW so no real host tools are discovered.
FAKE_HOME="$ROOT/home"
FAKE_BREW="$ROOT/brew"
mkdir -p "$FAKE_HOME"

# a — no --require: exit 0, cache written (default behavior byte-for-byte unchanged)
CACHE_A="$ROOT/cache-a.txt"
rc_a=0
HOME="$FAKE_HOME" RSDD_BREW_PREFIX="$FAKE_BREW" \
  bash "$DETECT" --cache "$CACHE_A" --quiet >/dev/null 2>&1 || rc_a=$?
if [ "$rc_a" -eq 0 ] && [ -f "$CACHE_A" ]; then
  ok "a no --require: exits 0 and writes cache" "(rc=$rc_a)"
else
  no "a no --require: exits 0 and writes cache" \
     "rc=$rc_a cache=$([ -f "$CACHE_A" ] && echo exists || echo missing)"
fi

# b — --require <present tool>: exit 0 when tool is AVAILABLE
BIN_B="$ROOT/bin-b"; mkdir -p "$BIN_B"
mkexec "$BIN_B/objdump" 'echo objdump-fake-2.39; exit 0'
CACHE_B="$ROOT/cache-b.txt"
rc_b=0
PATH="$BIN_B:$PATH" HOME="$FAKE_HOME" RSDD_BREW_PREFIX="$FAKE_BREW" \
  bash "$DETECT" --cache "$CACHE_B" --quiet --require objdump >/dev/null 2>&1 || rc_b=$?
if [ "$rc_b" -eq 0 ]; then
  ok "b --require present tool: exits 0" "(rc=$rc_b)"
else
  no "b --require present tool: exits 0" \
     "rc=$rc_b $(grep -E 'objdump' "$CACHE_B" 2>/dev/null | head -1 || true)"
fi

# c — --require <absent tool>: non-zero + loud stderr naming the tool.
# Ghidra needs GHIDRA_HOME / analyzeHeadless / /opt/ghidra* — all absent in this env.
CACHE_C="$ROOT/cache-c.txt"
stderr_c="$ROOT/stderr-c.txt"
rc_c=0
env -u ANALYZE_HEADLESS -u GHIDRA_HOME -u GHIDRA_INSTALL_DIR \
  HOME="$FAKE_HOME" RSDD_BREW_PREFIX="$FAKE_BREW" \
  bash "$DETECT" --cache "$CACHE_C" --quiet --require ghidra >/dev/null 2>"$stderr_c" || rc_c=$?
# Assert MISSING explicitly: on a host where ghidra half-resolves (UNUSABLE) or
# fully resolves (AVAILABLE), this fails LOUD instead of silently passing on the
# wrong branch or eroding coverage of the MISSING path this case documents.
if [ "$rc_c" -ne 0 ] && grep -qi 'ghidra' "$stderr_c" && grep -q 'MISSING' "$stderr_c"; then
  ok "c --require absent tool: non-zero + stderr names tool" "(rc=$rc_c)"
else
  no "c --require absent tool: non-zero + stderr names tool" \
     "rc=$rc_c stderr=[$(cat "$stderr_c" 2>/dev/null)]"
fi

# d — probe-failed: non-zero + "could not determine" in stderr + NOT MISSING in report.
# Stub objdump to sleep longer than RSDD_PROBE_TIMEOUT; timeout returns 124 (probe killed).
# The critical three-state check: timed-out probe must NOT read as a clean MISSING.
BIN_D="$ROOT/bin-d"; mkdir -p "$BIN_D"
mkexec "$BIN_D/objdump" 'sleep 5'   # killed by timeout at 0.1 s → exit 124 from timeout
CACHE_D="$ROOT/cache-d.txt"
stderr_d="$ROOT/stderr-d.txt"
rc_d=0
RSDD_PROBE_TIMEOUT=0.1 PATH="$BIN_D:$PATH" HOME="$FAKE_HOME" RSDD_BREW_PREFIX="$FAKE_BREW" \
  bash "$DETECT" --cache "$CACHE_D" --quiet --require objdump >/dev/null 2>"$stderr_d" || rc_d=$?
report_d="$(cat "$CACHE_D" 2>/dev/null || true)"
objdump_line="$(printf '%s\n' "$report_d" | grep -E 'objdump' | head -1 || true)"
if [ "$rc_d" -ne 0 ] \
   && grep -qi 'could not determine' "$stderr_d" \
   && ! printf '%s\n' "$objdump_line" | grep -q 'MISSING'; then
  ok "d probe-failed: non-zero + could-not-determine + not MISSING" "(rc=$rc_d)"
else
  no "d probe-failed: non-zero + could-not-determine + not MISSING" \
     "rc=$rc_d msg=[$(cat "$stderr_d" 2>/dev/null)] line=[$objdump_line]"
fi

# e — unknown tool name → exit 2 (usage error, like existing invalid-arg path)
rc_e=0
HOME="$FAKE_HOME" RSDD_BREW_PREFIX="$FAKE_BREW" \
  bash "$DETECT" --cache "$ROOT/cache-e.txt" --quiet \
  --require nonexistent-xyz-tool 2>/dev/null >/dev/null || rc_e=$?
if [ "$rc_e" -eq 2 ]; then
  ok "e unknown tool name: exit 2" "(rc=$rc_e)"
else
  no "e unknown tool name: exit 2" "rc=$rc_e"
fi

# f — python_row probe-failed: marker_single found but probe times out → PROBE_FAILED + "could not determine"
# RSDD_PYTHON_PROBE_TIMEOUT overrides the python-specific probe timeout (default 20 s).
BIN_F="$ROOT/bin-f"; mkdir -p "$BIN_F"
mkexec "$BIN_F/marker_single" 'sleep 5'   # killed by timeout at 0.1 s → exit 124
CACHE_F="$ROOT/cache-f.txt"
stderr_f="$ROOT/stderr-f.txt"
rc_f=0
RSDD_PROBE_TIMEOUT=0.1 RSDD_PYTHON_PROBE_TIMEOUT=0.1 \
  PATH="$BIN_F:$PATH" HOME="$FAKE_HOME" RSDD_BREW_PREFIX="$FAKE_BREW" \
  bash "$DETECT" --cache "$CACHE_F" --quiet --require marker >/dev/null 2>"$stderr_f" || rc_f=$?
report_f="$(cat "$CACHE_F" 2>/dev/null || true)"
marker_line="$(printf '%s\n' "$report_f" | grep -F '  marker ' | head -1 || true)"
if [ "$rc_f" -ne 0 ] \
   && grep -qi 'could not determine' "$stderr_f" \
   && printf '%s\n' "$marker_line" | grep -q 'PROBE_FAILED'; then
  ok "f python_row probe-failed: non-zero + could-not-determine + PROBE_FAILED" "(rc=$rc_f)"
else
  no "f python_row probe-failed: non-zero + could-not-determine + PROBE_FAILED" \
     "rc=$rc_f msg=[$(cat "$stderr_f" 2>/dev/null)] line=[$marker_line]"
fi

# g — jarrow probe-failed: vineflower jar found, unzip absent → rc 127 → PROBE_FAILED + "could not determine"
# PATH is restricted to $BIN_G (has timeout, grep, head via symlinks; no unzip) so command -v
# unzip returns empty. rsdd_probe_java_jar then returns 127, which jarrow must classify as
# PROBE_FAILED, not UNUSABLE.  Symlinks avoid the #!/usr/bin/env bash lookup when PATH lacks bash.
BIN_G="$ROOT/bin-g"; mkdir -p "$BIN_G"
ln -sf /usr/bin/dirname "$BIN_G/dirname"   # needed so detect-tools.sh can set HERE and source tool-env.sh
ln -sf /usr/bin/timeout "$BIN_G/timeout"   # needed by rsdd_run_probe / rsdd_capture_probe
ln -sf /usr/bin/grep "$BIN_G/grep"         # needed by --require gate (grep -F / -oE)
ln -sf /usr/bin/head "$BIN_G/head"         # needed by --require gate (head -1)
ln -sf /usr/bin/date "$BIN_G/date"         # avoids noisy date-not-found in $stderr_g
ln -sf /usr/bin/mkdir "$BIN_G/mkdir"       # needed by mkdir -p for cache directory creation
printf 'FAKE-JAR-CONTENT\n' > "$ROOT/fake-vineflower.jar"
CACHE_G="$ROOT/cache-g.txt"
stderr_g="$ROOT/stderr-g.txt"
rc_g=0
VINEFLOWER_JAR="$ROOT/fake-vineflower.jar" \
  PATH="$BIN_G" HOME="$FAKE_HOME" RSDD_BREW_PREFIX="$FAKE_BREW" \
  /bin/bash "$DETECT" --cache "$CACHE_G" --quiet --require vineflower >/dev/null 2>"$stderr_g" || rc_g=$?
report_g="$(cat "$CACHE_G" 2>/dev/null || true)"
vineflower_line="$(printf '%s\n' "$report_g" | grep -F 'Vineflower' | head -1 || true)"
if [ "$rc_g" -ne 0 ] \
   && grep -qi 'could not determine' "$stderr_g" \
   && printf '%s\n' "$vineflower_line" | grep -q 'PROBE_FAILED'; then
  ok "g jarrow probe-failed (unzip absent rc 127): non-zero + could-not-determine + PROBE_FAILED" "(rc=$rc_g)"
else
  no "g jarrow probe-failed (unzip absent rc 127): non-zero + could-not-determine + PROBE_FAILED" \
     "rc=$rc_g msg=[$(cat "$stderr_g" 2>/dev/null)] line=[$vineflower_line]"
fi

# h — Java secondary probe: rsdd_resolve_java_home is force-failed via SHIM so detect-tools.sh
# takes the secondary-probe branch.  A fake java in BIN_H sleeps longer than RSDD_PROBE_TIMEOUT
# → rsdd_run_probe returns 124 → Java 21 row must show PROBE_FAILED, not MISSING.
#
# SHIM technique: a fake lib/tool-env.sh sources the real library then redefines
# rsdd_resolve_java_home() { return 1; }.  detect-tools.sh resolves HERE via
# BASH_SOURCE[0] which points to the symlink inside SHIM_H, so it sources the shim lib.
BIN_H="$ROOT/bin-h"; mkdir -p "$BIN_H"
ln -sf /bin/bash          "$BIN_H/bash"     # env bash → resolves via BIN_H for mkexec stubs
ln -sf /usr/bin/dirname   "$BIN_H/dirname"  # detect-tools.sh HERE computation
ln -sf /usr/bin/timeout   "$BIN_H/timeout"  # rsdd_run_probe
ln -sf /usr/bin/grep      "$BIN_H/grep"     # --require gate
ln -sf /usr/bin/head      "$BIN_H/head"     # --require gate
ln -sf /usr/bin/date      "$BIN_H/date"     # report header date
ln -sf /usr/bin/sleep     "$BIN_H/sleep"    # fake java stub body
ln -sf /usr/bin/mkdir     "$BIN_H/mkdir"    # needed by mkdir -p for cache directory creation
mkexec "$BIN_H/java" 'sleep 5'             # killed by timeout at 0.1 s → rc 124

SHIM_H="$ROOT/shim-h"
mkdir -p "$SHIM_H/lib"
# Build shim lib/tool-env.sh: source real library then override rsdd_resolve_java_home.
REAL_TOOL_ENV="$HERE/../lib/tool-env.sh"
printf '. "%s"\nrsdd_resolve_java_home() { return 1; }\n' \
  "$REAL_TOOL_ENV" > "$SHIM_H/lib/tool-env.sh"
# Symlink detect-tools.sh into SHIM_H so BASH_SOURCE[0] → SHIM_H → HERE=SHIM_H.
ln -sf "$DETECT" "$SHIM_H/detect-tools.sh"

CACHE_H="$ROOT/cache-h.txt"
stderr_h="$ROOT/stderr-h.txt"
rc_h=0
RSDD_PROBE_TIMEOUT=0.1 \
  PATH="$BIN_H" HOME="$FAKE_HOME" RSDD_BREW_PREFIX="$FAKE_BREW" \
  /bin/bash "$SHIM_H/detect-tools.sh" \
  --cache "$CACHE_H" --quiet --require java >/dev/null 2>"$stderr_h" || rc_h=$?
report_h="$(cat "$CACHE_H" 2>/dev/null || true)"
java_line_h="$(printf '%s\n' "$report_h" | grep -F 'Java 21' | head -1 || true)"
if [ "$rc_h" -ne 0 ] \
   && grep -qi 'could not determine' "$stderr_h" \
   && printf '%s\n' "$java_line_h" | grep -q 'PROBE_FAILED'; then
  ok "h Java secondary probe: shim+sleeping java → PROBE_FAILED" "(rc=$rc_h)"
else
  no "h Java secondary probe: shim+sleeping java → PROBE_FAILED" \
     "rc=$rc_h msg=[$(cat "$stderr_h" 2>/dev/null)] line=[$java_line_h]"
fi

# ── Cache-location contract (tests i, j, k) ──────────────────────────────────

# i — no cwd pollution: --quiet without --cache must NOT create any file in the cwd.
# Default cache must land in the machine-scoped XDG/HOME path, never ./
TEMP_CWD_I="$ROOT/temp-cwd-i"
mkdir -p "$TEMP_CWD_I"
FAKE_HOME_I="$ROOT/fake-home-i"
mkdir -p "$FAKE_HOME_I"
rc_i=0
(
  cd "$TEMP_CWD_I"
  unset RESEARCH_TOOLS_CACHE XDG_CACHE_HOME
  HOME="$FAKE_HOME_I" RSDD_BREW_PREFIX="$FAKE_BREW" \
    bash "$DETECT" --quiet >/dev/null 2>&1
) || rc_i=$?
machine_cache_i="$FAKE_HOME_I/.cache/research-sdd/tool-capabilities.txt"
if [ ! -e "$TEMP_CWD_I/.research-tools.txt" ] && [ -f "$machine_cache_i" ]; then
  ok "i no cwd pollution: default cache lands in HOME/.cache, not cwd" "(rc=$rc_i)"
else
  no "i no cwd pollution: default cache lands in HOME/.cache, not cwd" \
     "rc=$rc_i cwd=$([ -e "$TEMP_CWD_I/.research-tools.txt" ] && echo polluted || echo clean) mc=$([ -f "$machine_cache_i" ] && echo written || echo absent)"
fi

# j — explicit --cache <abs-path> override still writes to the named file exactly.
CACHE_J="$ROOT/explicit-j.txt"
rc_j=0
HOME="$FAKE_HOME" RSDD_BREW_PREFIX="$FAKE_BREW" \
  bash "$DETECT" --cache "$CACHE_J" --quiet >/dev/null 2>&1 || rc_j=$?
if [ "$rc_j" -eq 0 ] && [ -f "$CACHE_J" ]; then
  ok "j explicit --cache override: writes to named file, exits 0" "(rc=$rc_j)"
else
  no "j explicit --cache override: writes to named file, exits 0" \
     "rc=$rc_j file=$([ -f "$CACHE_J" ] && echo present || echo absent)"
fi

# k — unwritable cache path: non-zero exit + stderr message (defect #2 was || true).
# RESEARCH_TOOLS_CACHE points under a mode-000 dir → write fails → must be loud.
UNWRITE_K="$ROOT/no-write-k"
mkdir -p "$UNWRITE_K"
chmod 000 "$UNWRITE_K"
stderr_k="$ROOT/stderr-k.txt"
rc_k=0
RESEARCH_TOOLS_CACHE="$UNWRITE_K/cache.txt" HOME="$FAKE_HOME" RSDD_BREW_PREFIX="$FAKE_BREW" \
  bash "$DETECT" --quiet >/dev/null 2>"$stderr_k" || rc_k=$?
chmod 755 "$UNWRITE_K"  # restore for trap cleanup
if [ "$rc_k" -ne 0 ] && [ -s "$stderr_k" ]; then
  ok "k unwritable cache: non-zero exit + stderr error message" "(rc=$rc_k)"
else
  no "k unwritable cache: non-zero exit + stderr error message" \
     "rc=$rc_k stderr=[$(head -1 "$stderr_k" 2>/dev/null || true)]"
fi

# l — blind-spot tools are KNOWN names (regression guard).
# bwrap, capa, floss, unblob and the kaitai compiler all have wrappers, evidence
# contracts and test suites in this toolbelt, yet none appeared in this report
# until 2026-08-23. bwrap's absence is the worst: it gates the ENTIRE slow lane,
# so every slow suite emitted `0 passed / 0 failed` with exit 0 while the report
# still read AVAILABLE for 35 of 38 tools.
# Assertion is exit-code-shaped, not availability-shaped: an unknown --require
# name exits 2 (see case e). Any other exit proves the name is mapped. That is
# deterministic on every host, unlike asserting MISSING for a tool the host has.
for _bs_tool in bwrap capa floss unblob kaitai; do
  rc_l=0
  HOME="$FAKE_HOME" RSDD_BREW_PREFIX="$FAKE_BREW" \
    bash "$DETECT" --cache "$ROOT/cache-l-$_bs_tool.txt" --quiet \
    --require "$_bs_tool" 2>/dev/null >/dev/null || rc_l=$?
  if [ "$rc_l" -ne 2 ]; then
    ok "l --require $_bs_tool: name is mapped (not exit 2)" "(rc=$rc_l)"
  else
    no "l --require $_bs_tool: name unknown to require_label" "rc=$rc_l"
  fi
done

# m — the report actually PRINTS a row for each blind-spot tool.
# Case l only proves the name resolves; this proves the operator can SEE it.
CACHE_M="$ROOT/cache-m.txt"
HOME="$FAKE_HOME" RSDD_BREW_PREFIX="$FAKE_BREW" \
  bash "$DETECT" --cache "$CACHE_M" --quiet >/dev/null 2>&1 || true
_m_missing=""
for _bs_label in "bwrap (sandbox)" "capa" "floss" "unblob" "kaitai-struct-compiler"; do
  grep -q "^  ${_bs_label} " "$CACHE_M" || _m_missing="$_m_missing $_bs_label"
done
if [ -z "$_m_missing" ]; then
  ok "m report prints a row for every blind-spot tool" "(5/5)"
else
  no "m report prints a row for every blind-spot tool" "missing:$_m_missing"
fi

# n — new section headers [ hex ] and [ modify / patch ] appear in the report.
CACHE_N="$ROOT/cache-n.txt"
HOME="$FAKE_HOME" RSDD_BREW_PREFIX="$FAKE_BREW" \
  bash "$DETECT" --cache "$CACHE_N" --quiet >/dev/null 2>&1 || true
_n_missing=""
for _sec_hdr in "[ hex ]" "[ modify / patch ]"; do
  grep -qF "$_sec_hdr" "$CACHE_N" || _n_missing="$_n_missing $_sec_hdr"
done
if [ -z "$_n_missing" ]; then
  ok "n report prints [ hex ] and [ modify / patch ] section headers" "(2/2)"
else
  no "n report prints [ hex ] and [ modify / patch ] section headers" "missing:$_n_missing"
fi

# o — new tool rows (krak2, diec, hexedit, bvi) appear in the report.
CACHE_O="$ROOT/cache-o.txt"
HOME="$FAKE_HOME" RSDD_BREW_PREFIX="$FAKE_BREW" \
  bash "$DETECT" --cache "$CACHE_O" --quiet >/dev/null 2>&1 || true
_o_missing=""
for _tool_lbl in "krak2" "diec" "hexedit" "bvi"; do
  grep -q "^  ${_tool_lbl} " "$CACHE_O" || _o_missing="$_o_missing $_tool_lbl"
done
if [ -z "$_o_missing" ]; then
  ok "o report prints a row for each new #296 tool" "(4/4)"
else
  no "o report prints a row for each new #296 tool" "missing:$_o_missing"
fi

# ── Prove-teeth (--prove-teeth) ──────────────────────────────────────────────
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: mutation controls --"

  # teeth-1 (targets test c): mutant forces gate_rc=0 for absent tools.
  # A gate_rc that never goes to 1 has no bite for MISSING/UNUSABLE cases.
  # Verify: mutant exits 0 for absent ghidra → test-c assertion [ rc -ne 0 ] would FAIL.
  MUT1="$ROOT/detect-mut1.sh"
  sed 's/gate_rc=1/gate_rc=0/g' "$DETECT" > "$MUT1"
  chmod +x "$MUT1"
  rc_m1=0
  env -u ANALYZE_HEADLESS -u GHIDRA_HOME -u GHIDRA_INSTALL_DIR \
    HOME="$FAKE_HOME" RSDD_BREW_PREFIX="$FAKE_BREW" \
    bash "$MUT1" --cache "$ROOT/cache-m1.txt" --quiet --require ghidra \
    >/dev/null 2>/dev/null || rc_m1=$?
  if [ "$rc_m1" -eq 0 ]; then
    ok "teeth-1: gate_rc=0 mutant exits 0 for absent tool — test-c bites" "(mutant rc=0)"
  else
    no "teeth-1: mutant must exit 0 for absent tool" "mutant rc=$rc_m1"
  fi

  # teeth-2 (targets test d): mutant replaces PROBE_FAILED with MISSING everywhere.
  # Timed-out objdump → report says MISSING → --require evaluates as MISSING → prints
  # "MISSING — install it" (not "could not determine") → test-d stderr check goes RED.
  MUT2="$ROOT/detect-mut2.sh"
  sed 's/PROBE_FAILED/MISSING/g' "$DETECT" > "$MUT2"
  chmod +x "$MUT2"
  stderr_m2="$ROOT/stderr-m2.txt"
  RSDD_PROBE_TIMEOUT=0.1 PATH="$BIN_D:$PATH" HOME="$FAKE_HOME" RSDD_BREW_PREFIX="$FAKE_BREW" \
    bash "$MUT2" --cache "$ROOT/cache-m2.txt" --quiet --require objdump \
    >/dev/null 2>"$stderr_m2" || true
  if ! grep -qi 'could not determine' "$stderr_m2"; then
    ok "teeth-2: PROBE_FAILED→MISSING mutant lacks 'could not determine' — test-d bites" \
       "(message absent)"
  else
    no "teeth-2: mutant must not have 'could not determine'" \
       "stderr=[$(cat "$stderr_m2" 2>/dev/null)]"
  fi

  # teeth-3 (targets test f): MUT2 (PROBE_FAILED→MISSING globally) run against test-f setup.
  # python_row timeout → mutant prints MISSING, not PROBE_FAILED → test-f assertion bites.
  RSDD_PROBE_TIMEOUT=0.1 RSDD_PYTHON_PROBE_TIMEOUT=0.1 \
    PATH="$BIN_F:$PATH" HOME="$FAKE_HOME" RSDD_BREW_PREFIX="$FAKE_BREW" \
    bash "$MUT2" --cache "$ROOT/cache-m2f.txt" --quiet \
    >/dev/null 2>/dev/null || true
  marker_line_m2f="$(cat "$ROOT/cache-m2f.txt" 2>/dev/null | grep -F '  marker ' | head -1 || true)"
  if ! printf '%s\n' "$marker_line_m2f" | grep -q 'PROBE_FAILED'; then
    ok "teeth-3: PROBE_FAILED→MISSING mutant: marker timeout shows MISSING — test-f bites" \
       "(PROBE_FAILED absent from report)"
  else
    no "teeth-3: mutant must NOT emit PROBE_FAILED for marker timeout" \
       "line=[$marker_line_m2f]"
  fi

  # teeth-4 (targets test g): MUT2 run against test-g setup (vineflower jar, unzip absent).
  # jarrow rc 127 → mutant prints MISSING, not PROBE_FAILED → test-g assertion bites.
  VINEFLOWER_JAR="$ROOT/fake-vineflower.jar" \
    PATH="$BIN_G" HOME="$FAKE_HOME" RSDD_BREW_PREFIX="$FAKE_BREW" \
    /bin/bash "$MUT2" --cache "$ROOT/cache-m2g.txt" --quiet \
    >/dev/null 2>/dev/null || true
  vineflower_line_m2g="$(cat "$ROOT/cache-m2g.txt" 2>/dev/null | grep -F 'Vineflower' | head -1 || true)"
  if ! printf '%s\n' "$vineflower_line_m2g" | grep -q 'PROBE_FAILED'; then
    ok "teeth-4: PROBE_FAILED→MISSING mutant: vineflower 127 shows MISSING — test-g bites" \
       "(PROBE_FAILED absent from report)"
  else
    no "teeth-4: mutant must NOT emit PROBE_FAILED for vineflower 127" \
       "line=[$vineflower_line_m2g]"
  fi

  # teeth-h (targets test h): MUT2 (PROBE_FAILED→MISSING) run via same SHIM + BIN_H.
  # rsdd_resolve_java_home=1 → secondary probe → sleeping java timeout → mutant prints
  # MISSING instead of PROBE_FAILED → Java 21 line has no PROBE_FAILED → test-h bites.
  SHIM_H_MUT="$ROOT/shim-h-mut"
  mkdir -p "$SHIM_H_MUT/lib"
  printf '. "%s"\nrsdd_resolve_java_home() { return 1; }\n' \
    "$REAL_TOOL_ENV" > "$SHIM_H_MUT/lib/tool-env.sh"
  ln -sf "$MUT2" "$SHIM_H_MUT/detect-tools.sh"

  RSDD_PROBE_TIMEOUT=0.1 \
    PATH="$BIN_H" HOME="$FAKE_HOME" RSDD_BREW_PREFIX="$FAKE_BREW" \
    /bin/bash "$SHIM_H_MUT/detect-tools.sh" \
    --cache "$ROOT/cache-mh.txt" --quiet \
    >/dev/null 2>/dev/null || true
  java_line_mh="$(cat "$ROOT/cache-mh.txt" 2>/dev/null | grep -F 'Java 21' | head -1 || true)"
  if ! printf '%s\n' "$java_line_mh" | grep -q 'PROBE_FAILED'; then
    ok "teeth-h: PROBE_FAILED→MISSING mutant: Java secondary probe shows MISSING — test-h bites" \
       "(PROBE_FAILED absent from report)"
  else
    no "teeth-h: mutant must NOT emit PROBE_FAILED for Java secondary probe timeout" \
       "line=[$java_line_mh]"
  fi

  # teeth-i (targets test i): mutant reverts CACHE default to cwd-relative ./.research-tools.txt
  # → file appears in cwd → test-i [ ! -e cwd/.research-tools.txt ] goes RED.
  MUT_I="$ROOT/detect-mut-i.sh"
  sed 's|^CACHE=.*|CACHE="./.research-tools.txt"|' "$DETECT" > "$MUT_I"
  chmod +x "$MUT_I"
  TEMP_CWD_MUT_I="$ROOT/temp-cwd-mut-i"
  mkdir -p "$TEMP_CWD_MUT_I"
  FAKE_HOME_MUT_I="$ROOT/fake-home-mut-i"
  mkdir -p "$FAKE_HOME_MUT_I"
  (
    cd "$TEMP_CWD_MUT_I"
    unset RESEARCH_TOOLS_CACHE XDG_CACHE_HOME
    HOME="$FAKE_HOME_MUT_I" RSDD_BREW_PREFIX="$FAKE_BREW" \
      bash "$MUT_I" --quiet >/dev/null 2>&1
  ) || true
  if [ -e "$TEMP_CWD_MUT_I/.research-tools.txt" ]; then
    ok "teeth-i: cwd-relative mutant deposits file in cwd — test-i bites" "(file found in cwd)"
  else
    no "teeth-i: mutant must create .research-tools.txt in cwd" "(file absent)"
  fi

  # teeth-k (targets test k): mutant restores silent write (|| true) → exits 0 on failure
  # → test-k [ rc -ne 0 ] goes RED.
  UNWRITE_MK="$ROOT/no-write-mk"
  mkdir -p "$UNWRITE_MK"
  chmod 000 "$UNWRITE_MK"
  MUT_K="$ROOT/detect-mut-k.sh"
  sed 's#|| { printf.*cannot write cache file.*exit 1; }#|| true#' "$DETECT" > "$MUT_K"
  chmod +x "$MUT_K"
  rc_mk=0
  RESEARCH_TOOLS_CACHE="$UNWRITE_MK/cache.txt" HOME="$FAKE_HOME" RSDD_BREW_PREFIX="$FAKE_BREW" \
    bash "$MUT_K" --quiet >/dev/null 2>/dev/null || rc_mk=$?
  chmod 755 "$UNWRITE_MK"  # restore for cleanup
  if [ "$rc_mk" -eq 0 ]; then
    ok "teeth-k: write-swallow mutant exits 0 for unwritable cache — test-k bites" \
       "(mutant rc=0)"
  else
    no "teeth-k: mutant must exit 0 (write error swallowed)" "mutant rc=$rc_mk"
  fi
fi

# il — ilspycmd AVAILABLE when binary found and DOTNET_ROOT resolvable via RSDD_DOTNET_ROOT.
# Asserts that detect-tools.sh resolves DOTNET_ROOT before the smoke test, so a working
# ilspycmd is reported AVAILABLE instead of UNUSABLE. This is the gap documented in
# DEPENDENCIES.md: the old row() smoke test ran without DOTNET_ROOT.
#
# The stub exits 0 ONLY when DOTNET_ROOT is non-empty in its environment — so the old
# bare row() (which does NOT set DOTNET_ROOT) would see exit 1 → UNUSABLE (the bug),
# while the fixed code (which resolves and exports DOTNET_ROOT first) sees exit 0 → AVAILABLE.
RUNTIME_IL="$ROOT/runtime-il"
mkdir -p "$RUNTIME_IL/shared/Microsoft.NETCore.App"
BIN_IL="$ROOT/bin-il"; mkdir -p "$BIN_IL"
mkexec "$BIN_IL/ilspycmd" '[ -n "${DOTNET_ROOT:-}" ] && exit 0; exit 1'
CACHE_IL="$ROOT/cache-il.txt"
rc_il=0
# RSDD_DOTNET_ROOT pins the runtime; DOTNET_ROOT is explicitly unset so the stub's
# exit code is determined entirely by whether detect-tools.sh sets it.
env -u DOTNET_ROOT \
  RSDD_DOTNET_ROOT="$RUNTIME_IL" PATH="$BIN_IL:$PATH" HOME="$FAKE_HOME" RSDD_BREW_PREFIX="$FAKE_BREW" \
  bash "$DETECT" --cache "$CACHE_IL" --quiet >/dev/null 2>&1 || rc_il=$?
ilspy_line_il="$(grep -F '  ilspycmd ' "$CACHE_IL" 2>/dev/null | head -1 || true)"
if [ "$rc_il" -eq 0 ] && printf '%s\n' "$ilspy_line_il" | grep -q 'AVAILABLE'; then
  ok "il ilspycmd: binary + resolvable DOTNET_ROOT → AVAILABLE" "(rc=$rc_il)"
else
  no "il ilspycmd: binary + resolvable DOTNET_ROOT → AVAILABLE" \
     "rc=$rc_il line=[$ilspy_line_il]"
fi

# il2 — ilspycmd UNUSABLE when binary found but DOTNET_ROOT cannot be resolved.
# RSDD_DOTNET_ROOT points to a dir with shared/ but ilspycmd --version always fails
# (simulates wrong runtime version). Must report UNUSABLE, NOT AVAILABLE or MISSING.
RUNTIME_IL2="$ROOT/runtime-il2"
mkdir -p "$RUNTIME_IL2/shared/Microsoft.NETCore.App"
BIN_IL2="$ROOT/bin-il2"; mkdir -p "$BIN_IL2"
# Stub: always exits 1 for --version (runtime probe always fails).
mkexec "$BIN_IL2/ilspycmd" '[ "$1" = "--version" ] && exit 1; exit 0'
CACHE_IL2="$ROOT/cache-il2.txt"
rc_il2=0
env -u DOTNET_ROOT \
  RSDD_DOTNET_ROOT="$RUNTIME_IL2" PATH="$BIN_IL2:$PATH" HOME="$FAKE_HOME" RSDD_BREW_PREFIX="$FAKE_BREW" \
  bash "$DETECT" --cache "$CACHE_IL2" --quiet >/dev/null 2>&1 || rc_il2=$?
ilspy_line_il2="$(grep -F '  ilspycmd ' "$CACHE_IL2" 2>/dev/null | head -1 || true)"
if [ "$rc_il2" -eq 0 ] && printf '%s\n' "$ilspy_line_il2" | grep -q 'UNUSABLE'; then
  ok "il2 ilspycmd: binary found but DOTNET_ROOT probe fails → UNUSABLE" "(rc=$rc_il2)"
else
  no "il2 ilspycmd: binary found but DOTNET_ROOT probe fails → UNUSABLE" \
     "rc=$rc_il2 line=[$ilspy_line_il2]"
fi

# ── Teeth for il/il2 tests ───────────────────────────────────────────────────
if [ "${1:-}" = "--prove-teeth" ]; then
  # teeth-il: uses a shim lib where rsdd_resolve_dotnet_root always returns 1.
  # This simulates the old behavior (no DOTNET_ROOT set before probe).
  # The DOTNET_ROOT-sensitive stub will see no DOTNET_ROOT → exits 1 → UNUSABLE.
  # Test-il expects AVAILABLE → goes RED. Confirms test-il has teeth.
  SHIM_IL="$ROOT/shim-il"
  mkdir -p "$SHIM_IL/lib"
  REAL_TOOL_ENV_IL="$HERE/../lib/tool-env.sh"
  printf '. "%s"\nrsdd_resolve_dotnet_root() { return 1; }\n' \
    "$REAL_TOOL_ENV_IL" > "$SHIM_IL/lib/tool-env.sh"
  ln -sf "$DETECT" "$SHIM_IL/detect-tools.sh"
  CACHE_MIL="$ROOT/cache-mil.txt"
  env -u DOTNET_ROOT \
    RSDD_DOTNET_ROOT="$RUNTIME_IL" PATH="$BIN_IL:$PATH" HOME="$FAKE_HOME" RSDD_BREW_PREFIX="$FAKE_BREW" \
    bash "$SHIM_IL/detect-tools.sh" --cache "$CACHE_MIL" --quiet >/dev/null 2>&1 || true
  ilspy_line_mil="$(grep -F '  ilspycmd ' "$CACHE_MIL" 2>/dev/null | head -1 || true)"
  # rsdd_resolve_dotnet_root always fails → UNUSABLE (or MISSING). Test-il expects AVAILABLE → bites.
  if ! printf '%s\n' "$ilspy_line_mil" | grep -q 'AVAILABLE'; then
    ok "teeth-il: rsdd_resolve_dotnet_root=fail shim → not AVAILABLE → test-il bites" \
       "(line=[$ilspy_line_mil])"
  else
    no "teeth-il: shim still shows AVAILABLE — test-il has no teeth" \
       "(line=[$ilspy_line_mil])"
  fi
fi

if [ "${1:-}" = "--prove-teeth" ]; then
  # teeth-l (targets test l): mutant drops bwrap from require_label.
  # Mutation is applied to a COPY under $ROOT — never to $DETECT itself.
  MUTL="$ROOT/detect-mutl.sh"
  sed '/^    bwrap)  *printf/d' "$DETECT" > "$MUTL"
  chmod +x "$MUTL"
  rc_ml=0
  HOME="$FAKE_HOME" RSDD_BREW_PREFIX="$FAKE_BREW" \
    bash "$MUTL" --cache "$ROOT/cache-ml.txt" --quiet --require bwrap \
    >/dev/null 2>/dev/null || rc_ml=$?
  if [ "$rc_ml" -eq 2 ]; then
    ok "teeth-l: unmapped-bwrap mutant exits 2 — test-l bites" "(mutant rc=2)"
  else
    no "teeth-l: mutant must exit 2 for unmapped bwrap" "mutant rc=$rc_ml"
  fi

  # teeth-m (targets test m): mutant deletes the bwrap report row.
  MUTM="$ROOT/detect-mutm.sh"
  sed '/row "bwrap (sandbox)"/d' "$DETECT" > "$MUTM"
  chmod +x "$MUTM"
  CACHE_MM="$ROOT/cache-mm.txt"
  HOME="$FAKE_HOME" RSDD_BREW_PREFIX="$FAKE_BREW" \
    bash "$MUTM" --cache "$CACHE_MM" --quiet >/dev/null 2>&1 || true
  if ! grep -q '^  bwrap (sandbox) ' "$CACHE_MM"; then
    ok "teeth-m: row-deleted mutant drops bwrap from report — test-m bites" "(row absent)"
  else
    no "teeth-m: mutant still prints bwrap row — test-m has no teeth" \
       "(line=[$(grep '^  bwrap' "$CACHE_MM" | head -1)])"
  fi

  # teeth-n (targets test n): mutant removes the [ hex ] section header.
  # Asserts that test-n detects a missing section header.
  MUTN="$ROOT/detect-mutn.sh"
  sed '/echo "\[ hex \]"/d' "$DETECT" > "$MUTN"
  chmod +x "$MUTN"
  CACHE_MN="$ROOT/cache-mn.txt"
  HOME="$FAKE_HOME" RSDD_BREW_PREFIX="$FAKE_BREW" \
    bash "$MUTN" --cache "$CACHE_MN" --quiet >/dev/null 2>&1 || true
  if ! grep -qF "[ hex ]" "$CACHE_MN"; then
    ok "teeth-n: section-deleted mutant drops [ hex ] from report — test-n bites" "(header absent)"
  else
    no "teeth-n: mutant still has [ hex ] header — test-n has no teeth" \
       "(line=[$(grep '\[ hex \]' "$CACHE_MN" | head -1)])"
  fi

  # teeth-o (targets test o): mutant removes the krak2 row.
  # Asserts that test-o detects a missing tool label.
  MUTO="$ROOT/detect-muto.sh"
  sed '/row "krak2"/d' "$DETECT" > "$MUTO"
  chmod +x "$MUTO"
  CACHE_MO="$ROOT/cache-mo.txt"
  HOME="$FAKE_HOME" RSDD_BREW_PREFIX="$FAKE_BREW" \
    bash "$MUTO" --cache "$CACHE_MO" --quiet >/dev/null 2>&1 || true
  if ! grep -q "^  krak2 " "$CACHE_MO"; then
    ok "teeth-o: row-deleted mutant drops krak2 from report — test-o bites" "(row absent)"
  else
    no "teeth-o: mutant still prints krak2 row — test-o has no teeth" \
       "(line=[$(grep '^  krak2 ' "$CACHE_MO" | head -1)])"
  fi
fi

printf '== %d passed · %d failed ==\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
