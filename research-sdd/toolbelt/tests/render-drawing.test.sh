#!/usr/bin/env bash
# render-drawing.test.sh — harness for render-drawing.sh, the DXF/DWG visual-oracle wrapper.
#
# Design: the SUT delegates rendering to an embedded Python script written to a
# temp file. This suite stubs python3 on PATH, intercepting the ezdxf dependency
# check (`-c 'import ezdxf'`) and the rendering script invocation. The stub avoids
# any real ezdxf installation requirement, so the full suite runs on any machine
# with bash + python3 (needed only for the stub invocation machinery — the real
# ezdxf import is intercepted before it ever reaches the interpreter).
#
# Restricted PATH trick (test 8): dwg2dxf is in linuxbrew, not in /usr/bin or
# /bin. PATH="$STUB:/usr/bin:/bin" reliably excludes it without touching the
# system or any state outside the tmpdir.
#
# Usage: render-drawing.test.sh                (run the suite)
#        render-drawing.test.sh --prove-teeth  (run suite + mutation teeth proof)
# Exit:  0 = every assertion held · 1 = a regression · 2 = harness error.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../render-drawing.sh"
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
BASH_BIN="$(type -P bash)"; [ -n "$BASH_BIN" ] || { echo "FATAL: bash not on PATH" >&2; exit 2; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok() { printf '  PASS  %-68s %s\n' "$1" "${2:-}"; pass=$((pass+1)); }
no() { printf '  FAIL  %-68s %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

# ---------------------------------------------------------------------------
# Fake python3 stub.
# Intercepts two categories of calls made by the SUT:
#
#   1. Dependency checks: python3 -c 'import ezdxf'  / 'import matplotlib'
#      FAKE_EZDXF_RC=0 (default) → pretend ezdxf installed; =1 → not installed.
#
#   2. Render script: python3 <script.py> <dxf-path> [args...]
#      The stub inspects the args and simulates the embedded Python renderer:
#        - --list-layers → print a minimal layer table, exit 0
#        - no out path   → stderr + exit 2  (maps to shell exit 2)
#        - FAKE_RENDER_FAIL=1 → stderr + exit 1  (maps to shell exit 4)
#        - else          → write "PNGDATA" to out path, exit 0
# ---------------------------------------------------------------------------
STUB="$TMP/stub"; mkdir -p "$STUB"
cat > "$STUB/python3" << 'PYSTUB'
#!/usr/bin/env bash
# Fake python3 for render-drawing tests — see suite header for protocol.
if [ "${1:-}" = "-c" ]; then
  case "${2:-}" in
    *"import ezdxf"*)      exit "${FAKE_EZDXF_RC:-0}" ;;
    *"import matplotlib"*) exit 0 ;;
    *)                     exit 0 ;;
  esac
fi
# Script invocation: $1=<render.py> $2=<dxf-path> [remaining args]
shift            # drop the script path (we don't need to read it)
shift || true    # drop dxf_path (already validated by the shell wrapper)
list_layers=0; out=""; skip_next=0
for arg in "$@"; do
  if [ "$skip_next" = 1 ]; then skip_next=0; continue; fi
  case "$arg" in
    --list-layers)                              list_layers=1 ;;
    --style|--dpi|--region|--size|--margin)    skip_next=1 ;;
    --only|--hide)                              ;;   # multi-value; absorbed by the loop
    *.png|*.svg|*.PNG|*.SVG)                   out="$arg" ;;
    *)                                          ;;
  esac
done
if [ "$list_layers" = 1 ]; then
  printf '  entities  layer                             state\n'
  printf '         0  0                                 \n'
  exit 0
fi
if [ -z "$out" ]; then
  printf 'render-drawing: output path required (or pass --list-layers)\n' >&2
  exit 2
fi
if [ "${FAKE_RENDER_FAIL:-0}" = 1 ]; then
  printf 'render-drawing: render failed: simulated error\n' >&2
  exit 1
fi
printf 'PNGDATA' > "$out"
printf 'rendered → %s\n' "$out"
exit 0
PYSTUB
chmod +x "$STUB/python3"

# ---------------------------------------------------------------------------
# Minimal DXF fixture (R2000 format: header + one layer + one LINE entity).
# This is text so ezdxf can parse it; the stub never actually reads it.
# ---------------------------------------------------------------------------
cat > "$TMP/valid.dxf" << 'DXFEOF'
  0
SECTION
  2
HEADER
  9
$ACADVER
  1
AC1015
  0
ENDSEC
  0
SECTION
  2
TABLES
  0
TABLE
  2
LAYER
 70
     1
  0
LAYER
  2
0
 70
     0
 62
     7
  6
Continuous
  0
ENDTAB
  0
ENDSEC
  0
SECTION
  2
ENTITIES
  0
LINE
  8
0
 10
0.0
 20
0.0
 30
0.0
 11
100.0
 21
100.0
 31
0.0
  0
ENDSEC
  0
EOF
DXFEOF

echo "== render-drawing.test.sh (SUT: $(basename "$SUT")) =="

# 1 — no args → exit 2 (usage).
rc1=0; PATH="$STUB:/usr/bin:/bin" "$BASH_BIN" "$SUT" >/dev/null 2>&1 || rc1=$?
[ "$rc1" = 2 ] \
  && ok "1  no args → exit 2" \
  || no "1  no args → exit 2" "rc=$rc1"

# 2 — non-existent input → exit 2.
rc2=0; PATH="$STUB:/usr/bin:/bin" "$BASH_BIN" "$SUT" "$TMP/no-such.dxf" "$TMP/out2.png" \
  >/dev/null 2>&1 || rc2=$?
[ "$rc2" = 2 ] \
  && ok "2  non-existent input file → exit 2" \
  || no "2  non-existent input file → exit 2" "rc=$rc2"

# 3 — ezdxf not installed → exit 3.
# Stub is configured to fail the ezdxf import (FAKE_EZDXF_RC=1).
rc3=0
FAKE_EZDXF_RC=1 PATH="$STUB:/usr/bin:/bin" "$BASH_BIN" "$SUT" \
  "$TMP/valid.dxf" "$TMP/out3.png" >/dev/null 2>&1 || rc3=$?
[ "$rc3" = 3 ] \
  && ok "3  ezdxf missing → exit 3" \
  || no "3  ezdxf missing → exit 3" "rc=$rc3"

# 4 — missing output arg → exit 2 (Python layer: no out path → exits 2 → shell exits 2).
rc4=0; PATH="$STUB:/usr/bin:/bin" "$BASH_BIN" "$SUT" "$TMP/valid.dxf" \
  >/dev/null 2>&1 || rc4=$?
[ "$rc4" = 2 ] \
  && ok "4  missing output arg → exit 2" \
  || no "4  missing output arg → exit 2" "rc=$rc4"

# 5 — render success → exit 0 + output file created.
out5="$TMP/out5.png"
rc5=0; PATH="$STUB:/usr/bin:/bin" "$BASH_BIN" "$SUT" "$TMP/valid.dxf" "$out5" \
  >/dev/null 2>&1 || rc5=$?
if [ "$rc5" = 0 ] && [ -f "$out5" ]; then
  ok "5  render success → exit 0 + output file created"
else
  no "5  render success → exit 0 + output created" \
     "rc=$rc5 file=$([ -f "$out5" ] && echo yes || echo no)"
fi

# 6 — --list-layers → exit 0 + layer table printed.
layers_out=""
rc6=0
layers_out="$(PATH="$STUB:/usr/bin:/bin" "$BASH_BIN" "$SUT" "$TMP/valid.dxf" --list-layers 2>&1)" \
  || rc6=$?
if [ "$rc6" = 0 ] && grep -q 'layer' <<<"$layers_out"; then
  ok "6  --list-layers → exit 0 + layer table" "($(wc -l <<<"$layers_out") lines)"
else
  no "6  --list-layers → exit 0 + layer table" "rc=$rc6 out=[$layers_out]"
fi

# 7 — render failure → exit 4 (Python exits 1; shell maps to 4).
out7="$TMP/out7.png"
rc7=0
FAKE_RENDER_FAIL=1 PATH="$STUB:/usr/bin:/bin" "$BASH_BIN" "$SUT" \
  "$TMP/valid.dxf" "$out7" >/dev/null 2>&1 || rc7=$?
[ "$rc7" = 4 ] \
  && ok "7  render failure → exit 4" \
  || no "7  render failure → exit 4" "rc=$rc7"

# 8 — .dwg without dwg2dxf → exit 3.
# Restricted PATH (stub + /usr/bin + /bin) keeps dwg2dxf (linuxbrew) out of reach.
printf 'fake DWG content' > "$TMP/test.dwg"
rc8=0
PATH="$STUB:/usr/bin:/bin" "$BASH_BIN" "$SUT" "$TMP/test.dwg" "$TMP/out8.png" \
  >/dev/null 2>&1 || rc8=$?
[ "$rc8" = 3 ] \
  && ok "8  .dwg without dwg2dxf → exit 3" \
  || no "8  .dwg without dwg2dxf → exit 3" "rc=$rc8"

# ---------------------------------------------------------------------------
# TEETH (negative control).
# ---------------------------------------------------------------------------
if [ "${1:-}" = "--prove-teeth" ]; then

  # teeth-rd-ezdxf-dep: neuter RD-EZDXF-DEP-CHECK; missing ezdxf must NOT
  # produce exit 3, proving test 3 depends on the real guard.
  echo "-- teeth-rd-ezdxf-dep: neuter RD-EZDXF-DEP-CHECK; missing ezdxf must NOT give exit 3 --"
  rdmut1="$TMP/render-drawing.M1.sh"
  if grep -q '# RD-EZDXF-DEP-CHECK' "$SUT"; then
    sed '/# RD-EZDXF-DEP-CHECK/ s/.*/: # RD-EZDXF-DEP-CHECK [NEUTERED]/' "$SUT" > "$rdmut1"
    chmod +x "$rdmut1"
    mrc1=0
    FAKE_EZDXF_RC=1 PATH="$STUB:/usr/bin:/bin" "$BASH_BIN" "$rdmut1" \
      "$TMP/valid.dxf" "$TMP/out_m1.png" >/dev/null 2>&1 || mrc1=$?
    if [ "$mrc1" != 3 ]; then
      ok "teeth-rd-ezdxf-dep: neutered guard → missing ezdxf no longer gives exit 3 (test 3 has teeth)"
    else
      no "teeth-rd-ezdxf-dep: neutered guard STILL gives exit 3 → test 3 is THEATER" "mrc=$mrc1"
    fi
  else
    no "teeth-rd-ezdxf-dep: RD-EZDXF-DEP-CHECK sentinel not found in SUT"
  fi

  # teeth-rd-file-check: neuter RD-FILE-CHECK; a non-existent input file must
  # NOT produce exit 2, proving test 2 depends on the real existence check.
  echo "-- teeth-rd-file-check: neuter RD-FILE-CHECK; missing file must NOT give exit 2 --"
  rdmut2="$TMP/render-drawing.M2.sh"
  if grep -q '# RD-FILE-CHECK' "$SUT"; then
    sed '/# RD-FILE-CHECK/ s/.*/: # RD-FILE-CHECK [NEUTERED]/' "$SUT" > "$rdmut2"
    chmod +x "$rdmut2"
    mrc2=0
    PATH="$STUB:/usr/bin:/bin" "$BASH_BIN" "$rdmut2" "$TMP/no-such.dxf" "$TMP/out_m2.png" \
      >/dev/null 2>&1 || mrc2=$?
    if [ "$mrc2" != 2 ]; then
      ok "teeth-rd-file-check: neutered guard → missing file no longer gives exit 2 (test 2 has teeth)"
    else
      no "teeth-rd-file-check: neutered guard STILL gives exit 2 → test 2 is THEATER" "mrc=$mrc2"
    fi
  else
    no "teeth-rd-file-check: RD-FILE-CHECK sentinel not found in SUT"
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
