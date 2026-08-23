#!/usr/bin/env bash
# regen-lane-fixtures.sh — regenerate lane fixture files for test suites.
#
# Each test suite that uses the fast/slow lane pattern captures real-tool output
# under tests/fixtures/lane/<suite>/<name>.json when run in RSDD_TEST_LANE=slow.
# This script is the ONLY place where the real tool must be present.  In fast
# lane, suites load these fixtures instead of spawning the tool.
#
# Usage:
#   bash regen-lane-fixtures.sh [--suite <suite-name>] [--lane <slow|all>] [--dry-run]
#
#   --suite <name>    Regenerate fixtures only for the named suite.
#                     If omitted, regenerates for ALL registered suites.
#   --lane <slow|all> Lane to run during regeneration (default: slow).
#                     Use "all" to also run fast-path assertions as a sanity check.
#   --dry-run         Print the commands that WOULD be executed; do not write files.
#
# Layout:
#   tests/fixtures/lane/<suite>/<name>.json
#
# Adding a new suite:
#   1. Add a regen_<suite>() function below that invokes the real tool and writes
#      its output via write_fixture().
#   2. Add the suite name to the KNOWN_SUITES list.
#   3. Run this script to generate the initial fixtures.
#
# Containment guards (bwrap / qemu / docker flags) are ALWAYS asserted even during
# slow-lane runs — only the tool spawn itself moves from fixture to real execution.
#
# Anti-#128 rule: fast-lane suites must NEVER emit SKIP: lines; they must always
# produce a normal "== N passed · N failed ==" summary.  Fixtures provide the data;
# containment contract is still verified in fast lane.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURE_BASE="$SCRIPT_DIR/fixtures/lane"

# --- Parse arguments ----------------------------------------------------------
SUITE_FILTER=""
REGEN_LANE="slow"
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --suite)
      SUITE_FILTER="${2:-}"
      shift 2
      ;;
    --lane)
      REGEN_LANE="${2:-slow}"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    *)
      echo "unknown flag: $1" >&2
      echo "Usage: regen-lane-fixtures.sh [--suite <name>] [--lane <slow|all>] [--dry-run]" >&2
      exit 2
      ;;
  esac
done

case "$REGEN_LANE" in
  slow|all) ;;
  *)
    echo "regen-lane-fixtures: --lane must be slow or all (got: $REGEN_LANE)" >&2
    exit 2
    ;;
esac

# --- Registered suites --------------------------------------------------------
# Add new suite names here when adding a regen_<suite>() function below.
KNOWN_SUITES=(
  capa
  corroborate-firmware
  corroborate-ghidra
  corroborate-native-r2
  floss
  ghidra-c-exporter
  ghidra-exporter
  jvm-callgraph
  kaitai
  unblob
)

# --- Helpers ------------------------------------------------------------------

write_fixture() {
  local suite="$1" name="$2" content="$3"
  local dest="${FIXTURE_BASE}/${suite}/${name}.json"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[dry-run] would write: $dest"
    return 0
  fi
  mkdir -p "$(dirname "$dest")"
  printf '%s\n' "$content" > "$dest"
  echo "wrote: $dest"
}

# --- Per-suite regen functions ------------------------------------------------
# Each function receives no arguments.  It must invoke the real tool in slow lane
# and call write_fixture() for every fixture it produces.
#
# Normalization: machine-specific paths (input file path, bwrap launcher path)
# are replaced with placeholder strings so committed fixtures are deterministic
# and pass on any machine.  Schema structure and SUT-logic values are preserved.

# regen_capa — captures capa evidence output on /bin/true.
# Fixtures produced:
#   capa/happy.json    — standard happy-path run; total_count ≥ 1.
#   capa/capped.json   — run with --max-capabilities 1; truncated=True.
#
# Requires: capa, bwrap, python3, RSDD_CAPA_RULES rules directory.
regen_capa() {
  local toolbelt="$SCRIPT_DIR/.."
  local rules_dir="${RSDD_CAPA_RULES:-$HOME/.local/share/capa-rules}"

  if ! command -v capa >/dev/null 2>&1 || ! command -v bwrap >/dev/null 2>&1; then
    echo "regen_capa: capa or bwrap not found; skipping" >&2
    return 0
  fi
  if ! [ -d "$rules_dir" ]; then
    echo "regen_capa: rules dir absent: $rules_dir; skipping" >&2
    return 0
  fi

  local tmp; tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" RETURN

  cp /bin/true "$tmp/happy.elf"

  _capa_run_and_write() {
    local name="$1"; shift
    local out_dir="$tmp/out_${name}"
    if ! bash "$toolbelt/corroborate-capa.sh" \
        --input "$tmp/happy.elf" --output "$out_dir" --timeout 300 "$@" 2>/dev/null; then
      echo "regen_capa: capa run failed for fixture '$name'" >&2
      return 1
    fi
    local raw_file="$tmp/raw_capa_${name}.json"
    cp "$out_dir/capa-evidence.v1.json" "$raw_file"
    # Normalize machine-specific paths to stable placeholders.
    # python3 reads its script from stdin (heredoc); raw_file is sys.argv[1].
    local normalized
    normalized="$(python3 - "$raw_file" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
# input.source.path — host path to the input binary before staging.
if isinstance(d.get("input"), dict):
    src = d["input"].get("source", {})
    if "path" in src:
        src["path"] = "__INPUT_PATH__"
# isolation.launcher.path — bwrap binary on the host.
if isinstance(d.get("isolation"), dict):
    lnch = d["isolation"].get("launcher", {})
    if "path" in lnch:
        lnch["path"] = "__BWRAP_PATH__"
# capabilities.tool.path + capabilities.argv[] — capa binary and argv absolute paths.
if isinstance(d.get("capabilities"), dict):
    cap = d["capabilities"]
    tool = cap.get("tool", {})
    if "path" in tool:
        tool["path"] = "__TOOL_PATH__"
    argv = cap.get("argv", [])
    for i, arg in enumerate(argv):
        if isinstance(arg, str) and arg.startswith("/"):
            argv[i] = "__TOOL_PATH__" if i == 0 else f"__ABS_PATH_{i}__"
print(json.dumps(d, indent=2, sort_keys=True))
PY
)"
    write_fixture "capa" "$name" "$normalized"
  }

  _capa_run_and_write "happy"
  _capa_run_and_write "capped" --max-capabilities 1
}

# regen_floss — captures floss evidence output on a generated tiny PE32.
# Fixtures produced:
#   floss/happy.json      — standard happy-path run; total_count ≥ 1.
#   floss/capped.json     — run with --max-strings 2; truncated=True.
#   floss/len_capped.json — run with --max-string-len 5; values ≤ 5 chars.
#
# Requires: floss, bwrap, python3.
regen_floss() {
  local toolbelt="$SCRIPT_DIR/.."

  if ! command -v floss >/dev/null 2>&1 || ! command -v bwrap >/dev/null 2>&1; then
    echo "regen_floss: floss or bwrap not found; skipping" >&2
    return 0
  fi

  local tmp; tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" RETURN

  # Generate tiny PE32 with known static strings.
  python3 - "$tmp/tiny_pe.exe" <<'PY'
import struct, sys

def pe32_with_strings(strings_list):
    dos = bytearray(64)
    dos[0:2] = b'MZ'
    struct.pack_into('<I', dos, 0x3C, 64)
    coff = struct.pack('=HHIIIHH', 0x014c, 1, 0, 0, 0, 0xe0, 0x0102)
    part1 = b'\x0b\x01\x01\x00' + struct.pack('=IIIIII', 0, 0x200, 0, 0x1000, 0x1000, 0x2000)
    part2 = struct.pack('=III', 0x400000, 0x1000, 0x200)
    part3 = struct.pack('=HHHHHH', 4, 0, 0, 0, 4, 0)
    part4 = struct.pack('=IIIIHH', 0, 0x3000, 0x200, 0, 3, 0)
    part5 = struct.pack('=IIIIII', 0x100000, 0x1000, 0x100000, 0x1000, 0, 16)
    opt = part1 + part2 + part3 + part4 + part5 + bytes(128)
    sec = struct.pack('=8sIIIIIIHHI', b'.rdata\x00\x00',
                      0x200, 0x1000, 0x200, 0x200, 0, 0, 0, 0, 0x40000040)
    hdr_raw = bytes(dos) + b'PE\x00\x00' + coff + opt + sec
    hdr = hdr_raw + bytes(0x200 - len(hdr_raw))
    sd = b''.join(s.encode() + b'\x00' for s in strings_list)
    pad = 0x200 - (len(sd) % 0x200)
    if pad < 0x200:
        sd += bytes(pad)
    return hdr + sd

strings = ['StaticAlphaString', 'StaticBetaString', 'StaticGammaString',
           'ObfuscatedTokenXYZ', 'SecretKeyValue123']
with open(sys.argv[1], 'wb') as f:
    f.write(pe32_with_strings(strings))
PY

  _floss_run_and_write() {
    local name="$1"; shift
    local out_dir="$tmp/out_${name}"
    if ! bash "$toolbelt/corroborate-floss.sh" \
        --input "$tmp/tiny_pe.exe" --output "$out_dir" "$@" 2>/dev/null; then
      echo "regen_floss: floss run failed for fixture '$name'" >&2
      return 1
    fi
    local raw_file="$tmp/raw_floss_${name}.json"
    cp "$out_dir/floss-evidence.v1.json" "$raw_file"
    # python3 reads its script from stdin (heredoc); raw_file is sys.argv[1].
    local normalized
    normalized="$(python3 - "$raw_file" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
# input.source.path — host path to the input binary before staging.
if isinstance(d.get("input"), dict):
    src = d["input"].get("source", {})
    if "path" in src:
        src["path"] = "__INPUT_PATH__"
# isolation.launcher.path — bwrap binary on the host.
if isinstance(d.get("isolation"), dict):
    lnch = d["isolation"].get("launcher", {})
    if "path" in lnch:
        lnch["path"] = "__BWRAP_PATH__"
# strings.tool.path + strings.argv[] — floss binary and argv absolute paths.
if isinstance(d.get("strings"), dict):
    strings = d["strings"]
    tool = strings.get("tool", {})
    if "path" in tool:
        tool["path"] = "__TOOL_PATH__"
    argv = strings.get("argv", [])
    for i, arg in enumerate(argv):
        if isinstance(arg, str) and arg.startswith("/"):
            argv[i] = "__TOOL_PATH__" if i == 0 else f"__ABS_PATH_{i}__"
print(json.dumps(d, indent=2, sort_keys=True))
PY
)"
    write_fixture "floss" "$name" "$normalized"
  }

  _floss_run_and_write "happy"
  _floss_run_and_write "capped"     --max-strings 2
  _floss_run_and_write "len_capped" --max-string-len 5
}

# regen_ghidra_c_exporter — runs Ghidra 1x on a tiny synthetic ELF and writes happy.json.
# Fixtures produced:
#   ghidra-c-exporter/happy.json — real decompiled C output from ExportDecompiledC.java;
#                                   c_output has function bodies with ';'; summary_line
#                                   has a non-zero exported count.
#
# broken.json is a static, hand-crafted fixture (banners present, all functions FAILED,
# 0 exported).  It is NOT regenerated here — it must survive regen unchanged.
#
# Normalization:
#   summary_line: absolute output path → __OUT_PATH__
#   c_output banners: entry addresses (hex) → __ENTRY__
#   C bodies: not scrubbed (iVar1/FUN_/ordering are stable across fast-lane predicates
#             that only check for ';' and '/* ---- ')
#
# Requires: Ghidra, gcc, java21, timeout.
# shellcheck disable=SC2317  # regen function called via name; not reachable by static flow
regen_ghidra_c_exporter() {
  local toolbelt="$SCRIPT_DIR/.."

  # shellcheck source=../lib/tool-env.sh
  source "$toolbelt/lib/tool-env.sh"

  local ghidra_home java21
  ghidra_home="$(rsdd_resolve_ghidra_home 2>/dev/null || true)"
  java21="$(rsdd_resolve_java_home 2>/dev/null || true)"

  if [ -z "$ghidra_home" ] || [ -z "$java21" ] || ! rsdd_probe_ghidra "$ghidra_home"; then
    echo "regen_ghidra_c_exporter: usable Ghidra unavailable; skipping" >&2
    return 0
  fi

  for _regen_tool in gcc timeout; do
    command -v "$_regen_tool" >/dev/null 2>&1 || {
      echo "regen_ghidra_c_exporter: '$_regen_tool' not found; skipping" >&2
      return 0
    }
  done

  local exporter="$toolbelt/ghidra/ExportDecompiledC.java"
  if [ ! -f "$exporter" ]; then
    echo "regen_ghidra_c_exporter: SUT not found: $exporter; skipping" >&2
    return 0
  fi

  local tmp; tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" RETURN

  # Tiny synthetic ELF — same source as the slow-lane integration test so the
  # predicate set (ck_fn_body, ck_nonzero_exports, etc.) is compatible.
  cat >"$tmp/fix.c" <<'CSRC'
#include <stdio.h>
static int helper(int n) { return n * 2; }
int main(void) { printf("%d\n", helper(21)); return 0; }
CSRC
  gcc -O0 -fno-pie -no-pie -o "$tmp/fix.elf" "$tmp/fix.c"

  local run_dir="$tmp/run_happy"
  local out_dir="$tmp/out_happy"
  mkdir -p "$run_dir/project" "$run_dir/home" \
           "$run_dir/xdg-cache" "$run_dir/xdg-config" "$out_dir"

  ( HOME="$run_dir/home" XDG_CACHE_HOME="$run_dir/xdg-cache" \
    XDG_CONFIG_HOME="$run_dir/xdg-config" \
    JAVA_HOME="$java21" JAVA_TOOL_OPTIONS="-Duser.home=$run_dir/home" \
    RSDD_OUT="$out_dir" \
    timeout 240 "$ghidra_home/support/analyzeHeadless" \
      "$run_dir/project" cexport \
      -import "$tmp/fix.elf" -analysisTimeoutPerFile 120 \
      -scriptPath "$toolbelt/ghidra" \
      -postScript ExportDecompiledC.java \
      -deleteProject \
      >"$tmp/headless.log" 2>&1 )
  local rc=$?

  if [ "$rc" -ne 0 ] || [ ! -f "$out_dir/fix.elf.c" ]; then
    echo "regen_ghidra_c_exporter: Ghidra run failed (rc=$rc)" >&2
    cat "$tmp/headless.log" >&2
    return 1
  fi

  # Extract only the RSDD-EXPORT summary line from headless.log.
  # headless.log is large (Ghidra startup/analysis noise); never commit it.
  local summary_line
  summary_line="$(grep 'RSDD-EXPORT:' "$tmp/headless.log" | grep ' exported,' | tail -1 | tr -d '\r')"
  if [ -z "$summary_line" ]; then
    echo "regen_ghidra_c_exporter: RSDD-EXPORT summary line not found in headless.log" >&2
    return 1
  fi

  # Normalize: abs output path → __OUT_PATH__.
  summary_line="$(printf '%s' "$summary_line" | sed 's| -> .*/fix\.elf\.c$| -> __OUT_PATH__/fix.elf.c|')"

  # Read C output, then normalize entry addresses in banners.
  # C bodies are NOT scrubbed (iVar1/FUN_/ordering tolerated by fast-lane predicates).
  local c_output
  c_output="$(cat "$out_dir/fix.elf.c" | sed 's|@ [0-9a-fA-F]\+|@ __ENTRY__|g')"

  # Write to temp files for Python JSON assembly.
  printf '%s' "$c_output" > "$tmp/c_output.txt"
  printf '%s' "$summary_line" > "$tmp/summary_line.txt"

  # Leak check: normalized output must contain no host paths.
  if printf '%s\n%s\n' "$c_output" "$summary_line" \
       | grep -qE '/home/|/tmp/|cristian|linuxbrew|\.dotnet'; then
    echo "regen_ghidra_c_exporter: host path leaked after normalization — aborting" >&2
    printf '%s\n%s\n' "$c_output" "$summary_line" \
      | grep -E '/home/|/tmp/|cristian|linuxbrew|\.dotnet' >&2
    return 1
  fi

  local normalized
  normalized="$(python3 - "$tmp/c_output.txt" "$tmp/summary_line.txt" <<'PY'
import json, pathlib, sys
c_output = pathlib.Path(sys.argv[1]).read_text()
summary_line = pathlib.Path(sys.argv[2]).read_text()
d = {"c_output": c_output, "summary_line": summary_line}
print(json.dumps(d, indent=2, ensure_ascii=False))
PY
  )"

  write_fixture "ghidra-c-exporter" "happy" "$normalized"
  echo "regen_ghidra_c_exporter: broken.json is static — not regenerated" >&2
}

# regen_ghidra_exporter — runs Ghidra 3x on a synthetic gcc ELF and writes fixtures.
# Fixtures produced:
#   ghidra-exporter/full.json    — generous caps (4096 4096 4096 4096 4096 4096 256);
#                                  status complete, all counts exact.
#   ghidra-exporter/capped.json — tight caps (1 1 1 1 1 1 16); status partial,
#                                  all kinds emitted<observed, string values ≤16 chars.
#   ghidra-exporter/long.json   — string_chars=32 (4096 4096 4096 4096 4096 4096 32);
#                                  status partial, CURATED_LONG_STRING capped at 32.
#
# NOTE: Fixtures are NOT byte-reproducible cross-machine — md5 and addresses depend
# on the host-compiled ELF. Fixtures are version-scoped to Ghidra 12.1.2.  Any
# change to the C source or gcc flags invalidates existing fixtures; re-run this
# script to regenerate them.
#
# Requires: Ghidra 12.1.2, gcc, java21, python3, timeout.
# shellcheck disable=SC2317  # regen function called via name; not reachable by static flow
regen_ghidra_exporter() {
  local toolbelt="$SCRIPT_DIR/.."

  # Source tool-env for Ghidra/Java resolution helpers.
  # shellcheck source=../lib/tool-env.sh
  source "$toolbelt/lib/tool-env.sh"

  local ghidra_home java21
  ghidra_home="$(rsdd_resolve_ghidra_home 2>/dev/null || true)"
  java21="$(rsdd_resolve_java_home 2>/dev/null || true)"

  if [ -z "$ghidra_home" ] || [ -z "$java21" ] || ! rsdd_probe_ghidra "$ghidra_home"; then
    echo "regen_ghidra_exporter: usable Ghidra unavailable; skipping" >&2
    return 0
  fi

  local version
  version="$(awk -F= '$1=="application.version"{print $2}' \
    "$ghidra_home/Ghidra/application.properties")"
  if [ "$version" != "12.1.2" ]; then
    echo "regen_ghidra_exporter: expected Ghidra 12.1.2, found $version; skipping" >&2
    return 0
  fi

  for _tool in gcc python3 timeout; do
    command -v "$_tool" >/dev/null 2>&1 || {
      echo "regen_ghidra_exporter: '$_tool' not found; skipping" >&2
      return 0
    }
  done

  local exporter="$toolbelt/ghidra/CuratedEvidenceExporter.java"
  if [ ! -f "$exporter" ]; then
    echo "regen_ghidra_exporter: exporter not found: $exporter; skipping" >&2
    return 0
  fi

  local tmp; tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" RETURN

  # Synthetic C source — same as the slow-lane test to ensure assertion compatibility.
  cat >"$tmp/fixture.c" <<'EOF'
#include <stdio.h>
int fixture_global=17;
__attribute__((constructor)) static void forbidden(void){FILE*f=fopen("TARGET_EXECUTED","w");if(f){fputs("executed",f);fclose(f);}}
__attribute__((visibility("default"))) int exported_add(int n){return n+fixture_global;}
static int named_helper(int n){return exported_add(n)+1;}
const char *long_evidence="CURATED_LONG_STRING_ABCDEFGHIJKLMNOPQRSTUVWXYZ_abcdefghijklmnopqrstuvwxyz_0123456789_repeat_repeat_repeat";
int main(void){puts(long_evidence);return named_helper(1)==19?0:1;}
EOF
  gcc -O0 -rdynamic -fno-pie -no-pie -o "$tmp/fixture.elf" "$tmp/fixture.c"

  _ghidra_run_and_write() {
    local name="$1"; shift
    local run_dir="$tmp/run_$name"
    mkdir -p "$run_dir/project" "$run_dir/home" "$run_dir/xdg-cache" "$run_dir/xdg-config"
    local out_json="$tmp/out_$name.json"
    (cd "$tmp" && \
      HOME="$run_dir/home" XDG_CACHE_HOME="$run_dir/xdg-cache" \
      XDG_CONFIG_HOME="$run_dir/xdg-config" \
      JAVA_HOME="$java21" JAVA_TOOL_OPTIONS="-Duser.home=$run_dir/home" \
      timeout 180 "$ghidra_home/support/analyzeHeadless" \
        "$run_dir/project" curated \
        -import "$tmp/fixture.elf" -analysisTimeoutPerFile 120 \
        -scriptPath "$toolbelt/ghidra" \
        -postScript CuratedEvidenceExporter.java "$out_json" "$@" \
        -deleteProject \
        >"$run_dir/headless.log" 2>&1)
    local rc=$?
    if [ "$rc" -ne 0 ] || [ ! -f "$out_json" ]; then
      echo "regen_ghidra_exporter: Ghidra run failed for fixture '$name' (rc=$rc)" >&2
      cat "$run_dir/headless.log" >&2
      return 1
    fi
    # Schema v1 is host-path-free by design — verify and write as-is (no normalization).
    # The exporter emits compact sorted JSON + trailing LF: that IS the canonical encoding.
    local raw; raw="$(cat "$out_json")"
    python3 - "$out_json" <<'PY' || { echo "regen_ghidra_exporter: $name normalization check failed" >&2; return 1; }
import json, pathlib, sys
raw = pathlib.Path(sys.argv[1]).read_bytes()
d = json.loads(raw)
# Verify canonical encoding (compact sorted JSON + LF).
canonical = (json.dumps(d, ensure_ascii=False, sort_keys=True, separators=(',',':')) + '\n').encode()
assert raw == canonical, "output is not canonical compact JSON+LF"
# Verify no host paths leaked into schema v1 output.
for token in raw.decode('utf-8').split('"'):
    assert '/home/' not in token and '/tmp/' not in token, f"host path leaked: {token!r}"
PY
    write_fixture "ghidra-exporter" "$name" "$raw"
  }

  _ghidra_run_and_write "full"   4096 4096 4096 4096 4096 4096 256
  _ghidra_run_and_write "capped"    1    1    1    1    1    1  16
  _ghidra_run_and_write "long"   4096 4096 4096 4096 4096 4096  32
}

# regen_kaitai — captures kaitai evidence output on a deterministic demo schema+binary.
# Fixtures produced:
#   kaitai/happy.json   — standard happy-path run; structure.truncated=false.
#   kaitai/capped.json  — run with --max-fields 2; structure.truncated=true.
#
# Requires: kaitai-struct-compiler, bwrap, python3, kaitai venv python.
regen_kaitai() {
  local toolbelt="$SCRIPT_DIR/.."
  local kaitai_py="${RSDD_KAITAI_PY:-$HOME/.local/share/rsdd-kaitai/bin/python}"

  if ! command -v kaitai-struct-compiler >/dev/null 2>&1 || ! command -v bwrap >/dev/null 2>&1; then
    echo "regen_kaitai: kaitai-struct-compiler or bwrap not found; skipping" >&2
    return 0
  fi
  if ! [ -x "$kaitai_py" ]; then
    echo "regen_kaitai: kaitai venv python not found: $kaitai_py; skipping" >&2
    return 0
  fi

  local tmp; tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" RETURN

  # demo.ksy: magic(2B LE), count(u2 LE), value(u4 LE) — deterministic schema.
  cat > "$tmp/demo.ksy" << 'EOKSY'
meta:
  id: demo
  endian: le
seq:
  - id: magic
    contents: [0x4b, 0x53]
  - id: count
    type: u2
  - id: value
    type: u4
EOKSY

  # sample.bin: KS + count=3 (u2 LE) + value=0xdeadbeef (u4 LE) = 8 bytes.
  python3 -c "open('$tmp/sample.bin', 'wb').write(b'KS\x03\x00\xef\xbe\xad\xde')"

  _kaitai_run_and_write() {
    local name="$1"; shift
    local out_dir="$tmp/out_${name}"
    if ! bash "$toolbelt/corroborate-kaitai.sh" \
        --input "$tmp/sample.bin" --ksy "$tmp/demo.ksy" \
        --output "$out_dir" --timeout 120 "$@" 2>/dev/null; then
      echo "regen_kaitai: run failed for fixture '$name'" >&2
      return 1
    fi
    local raw_file="$tmp/raw_kaitai_${name}.json"
    cp "$out_dir/kaitai-evidence.v1.json" "$raw_file"
    # Normalize machine-specific paths; preserve sha256 and other fields.
    local normalized
    normalized="$(python3 - "$raw_file" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
if isinstance(d.get("input"), dict):
    src = d["input"].get("source", {})
    if "path" in src:
        src["path"] = "__INPUT_PATH__"
if isinstance(d.get("ksy_identity"), dict):
    if "path" in d["ksy_identity"]:
        d["ksy_identity"]["path"] = "__KSY_PATH__"
if isinstance(d.get("isolation"), dict):
    lnch = d["isolation"].get("launcher", {})
    if "path" in lnch:
        lnch["path"] = "__BWRAP_PATH__"
print(json.dumps(d, indent=2, sort_keys=True))
PY
)"
    write_fixture "kaitai" "$name" "$normalized"
  }

  _kaitai_run_and_write "happy"
  _kaitai_run_and_write "capped" --max-fields 2
}

# regen_unblob — captures unblob evidence output on a deterministic tar.gz.
# Fixtures produced:
#   unblob/happy.json        — standard happy-path run; extraction.truncated=false.
#   unblob/depth_capped.json — run with --max-depth 2; extraction.truncated=true,
#                              depth-cap limitation present.
#
# Requires: unblob, bwrap, python3.
# Archive is deterministic: --sort=name --mtime='2024-01-01 00:00:00'.
regen_unblob() {
  local toolbelt="$SCRIPT_DIR/.."

  if ! command -v unblob >/dev/null 2>&1 || ! command -v bwrap >/dev/null 2>&1; then
    echo "regen_unblob: unblob or bwrap not found; skipping" >&2
    return 0
  fi

  local tmp; tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" RETURN

  # good.tgz: deterministic tar.gz with 3 known-content files.
  # --sort=name + fixed --mtime produces byte-identical archives across runs.
  mkdir -p "$tmp/tree"
  printf 'alpha' > "$tmp/tree/a.txt"
  printf 'beta'  > "$tmp/tree/b.txt"
  printf 'gamma' > "$tmp/tree/c.txt"
  tar -C "$tmp" --sort=name --mtime='2024-01-01 00:00:00' -czf "$tmp/good.tgz" tree

  _unblob_run_and_write() {
    local name="$1"; shift
    local out_dir="$tmp/out_${name}"
    if ! bash "$toolbelt/corroborate-unblob.sh" \
        --input "$tmp/good.tgz" --output "$out_dir" "$@" 2>/dev/null; then
      echo "regen_unblob: run failed for fixture '$name'" >&2
      return 1
    fi
    local raw_file="$tmp/raw_unblob_${name}.json"
    cp "$out_dir/unblob-evidence.v1.json" "$raw_file"
    # Normalize all machine-specific and absolute paths; preserve sha256 and other fields.
    # argv may contain /tmp/rsdd/... paths (adapter work dirs) — normalize those too.
    local normalized
    normalized="$(python3 - "$raw_file" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
if isinstance(d.get("input"), dict):
    src = d["input"].get("source", {})
    if "path" in src:
        src["path"] = "__INPUT_PATH__"
    stg = d["input"].get("staged", {})
    if "path" in stg:
        stg["path"] = "__STAGED_PATH__"
if isinstance(d.get("isolation"), dict):
    lnch = d["isolation"].get("launcher", {})
    if "path" in lnch:
        lnch["path"] = "__BWRAP_PATH__"
if isinstance(d.get("extraction"), dict):
    tool = d["extraction"].get("tool", {})
    if "path" in tool:
        tool["path"] = "__UNBLOB_PATH__"
    # Normalize every element of argv that is an absolute path.
    argv = d["extraction"].get("argv", [])
    for i, arg in enumerate(argv):
        if isinstance(arg, str) and arg.startswith("/"):
            argv[i] = "__UNBLOB_PATH__" if i == 0 else f"__ABS_PATH_{i}__"
print(json.dumps(d, indent=2, sort_keys=True))
PY
)"
    write_fixture "unblob" "$name" "$normalized"
  }

  _unblob_run_and_write "happy"
  _unblob_run_and_write "depth_capped" --max-depth 2
}

# regen_corroborate_firmware — runs corroborate-firmware on a tiny synthetic binary
# using a DETERMINISTIC FAKE binwalk (ARCHETYPE B: real bwrap + fake tool).
#
# The fake binwalk is lifted verbatim from the existing test suite (lines 77-81):
#   --help → 'Binwalk vfake'; else → 3 fixed findings (0/1/2).
# Building from the fake is cleaner than real binwalk: fixed version string, no
# /usr/bin/binwalk absolute paths that would leak into the fixture.
#
# Fixtures produced:
#   corroborate-firmware/happy.json  — full fake-of-3, status=complete, emitted=3.
#   corroborate-firmware/capped.json — --max-findings 2; status=partial, emitted=2, total=3.
#
# Normalization (all machine-specific fields replaced with stable placeholders):
#   input.source.path → __INPUT_PATH__; input size fields → __SIZE__
#   input sha256 pair (source == staged) → <SHA_INPUT>
#   isolation.launcher path/size/sha256 → __BWRAP_PATH__/__SIZE__/<BWRAP_SHA>
#   engine.version → __BINWALK_VERSION__; engine.manifest_identity → __MANIFEST_IDENTITY__
#   engine.launcher.source path/size → __BINWALK_PATH__/__SIZE__
#   engine.launcher sha256 pair (source == staged) → <SHA_BINWALK>
#   engine.launcher.staged.size → __SIZE__
#   Relative logical paths (input/firmware.bin, engine/binwalk) kept as-is.
#   engine.argv kept as-is (all entries relative, safe to commit).
#
# CONTENT-ADDRESSED MANIFEST NOTE: the on-disk engine/analysis-manifest.v1.json is
#   NEVER normalized — verify recomputes identity from raw bytes and a normalized
#   manifest would fail.  Only the engine.manifest_identity scalar in the report
#   JSON is replaced with __MANIFEST_IDENTITY__.
#
# Requires: /usr/bin/bwrap (root-owned), python3.  Graceful skip if bwrap absent.
# shellcheck disable=SC2317  # regen function called via name; not reachable by static flow
regen_corroborate_firmware() {
  local toolbelt="$SCRIPT_DIR/.."
  local sut_py="$toolbelt/corroborate_firmware.py"
  local man="$toolbelt/analysis_manifest.py"

  if [ ! -f "$sut_py" ]; then
    echo "regen_corroborate_firmware: SUT not found: $sut_py; skipping" >&2
    return 0
  fi
  if [ ! -f "$man" ]; then
    echo "regen_corroborate_firmware: analysis_manifest.py not found: $man; skipping" >&2
    return 0
  fi

  # Real bwrap is required for the isolation report.
  if ! [ -x /usr/bin/bwrap ]; then
    echo "regen_corroborate_firmware: /usr/bin/bwrap not found or not executable; skipping" >&2
    return 0
  fi

  command -v python3 >/dev/null 2>&1 || {
    echo "regen_corroborate_firmware: python3 not found; skipping" >&2
    return 0
  }

  local tmp; tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" RETURN

  # Fake binwalk: lifted verbatim from the existing test (original lines 77-81).
  # --help → 'Binwalk vfake'; else → 3 deterministic findings at offsets 0,1,2.
  mkdir -p "$tmp/fake-bwalk"
  cat >"$tmp/fake-bwalk/binwalk" <<'SH'
#!/bin/sh
[ "$1" = --help ] && { echo 'Binwalk vfake'; exit; }
printf '0 0x0 first\n1 0x1 second\n2 0x2 third\n'
SH
  chmod +x "$tmp/fake-bwalk/binwalk"

  # Tiny input binary — just needs to be a regular, non-symlink file.
  printf '\x7fELF' >"$tmp/firmware.bin"

  # _normalize_fw <raw-json-file>
  #   Verifies sha256 equality pairs before replacing with distinct placeholders.
  #   <SHA_INPUT>:  input.source.sha256 == input.staged.sha256 (same content)
  #   <SHA_BINWALK>: engine.launcher.source.sha256 == engine.launcher.staged.sha256
  #   Distinct placeholders keep an input↔binwalk swap detectable.
  _normalize_fw() {
    python3 - "$1" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))

# Verify equality pairs before normalizing (SUT correctness gate).
inp = d["input"]
assert inp["source"]["sha256"] == inp["staged"]["sha256"], (
    f"input sha256 mismatch: {inp['source']['sha256']!r} != {inp['staged']['sha256']!r}")
lnch = d["engine"]["launcher"]
assert lnch["source"]["sha256"] == lnch["staged"]["sha256"], (
    f"binwalk sha256 mismatch: {lnch['source']['sha256']!r} != {lnch['staged']['sha256']!r}")

# input — absolute source path + machine-specific sizes and sha256
d["input"]["source"]["path"] = "__INPUT_PATH__"
d["input"]["source"]["size"] = "__SIZE__"
d["input"]["source"]["sha256"] = "<SHA_INPUT>"
d["input"]["staged"]["size"] = "__SIZE__"
d["input"]["staged"]["sha256"] = "<SHA_INPUT>"
# input.staged.path == "input/firmware.bin" — relative logical path, kept as-is

# isolation.launcher (bwrap binary) — absolute path, machine-specific
d["isolation"]["launcher"]["path"] = "__BWRAP_PATH__"
d["isolation"]["launcher"]["size"] = "__SIZE__"
d["isolation"]["launcher"]["sha256"] = "<BWRAP_SHA>"
# isolation.profile is a constant struct; no paths to normalize

# engine
d["engine"]["version"] = "__BINWALK_VERSION__"
d["engine"]["manifest_identity"] = "__MANIFEST_IDENTITY__"
d["engine"]["launcher"]["source"]["path"] = "__BINWALK_PATH__"
d["engine"]["launcher"]["source"]["size"] = "__SIZE__"
d["engine"]["launcher"]["source"]["sha256"] = "<SHA_BINWALK>"
d["engine"]["launcher"]["staged"]["size"] = "__SIZE__"
d["engine"]["launcher"]["staged"]["sha256"] = "<SHA_BINWALK>"
# engine.launcher.staged.path == "engine/binwalk" — relative, kept as-is
# engine.argv == ["engine/binwalk","-B","-E","-N","input/firmware.bin"] — all relative

print(json.dumps(d, indent=2, sort_keys=True))
PY
  }

  # --- Happy run (complete, no cap, fake binwalk) ---
  local out_happy="$tmp/out_happy"
  RSDD_BINWALK_TEST_ONLY="$tmp/fake-bwalk/binwalk" \
    PATH="$tmp/fake-bwalk:/usr/bin:/bin" \
    python3 "$sut_py" \
      --input "$tmp/firmware.bin" --output "$out_happy" \
      --manifest-cli "$man" 2>/dev/null \
  || {
    echo "regen_corroborate_firmware: happy run failed" >&2; return 1
  }

  local normalized_happy
  normalized_happy="$(_normalize_fw "$out_happy/firmware-static.v1.json")" || {
    echo "regen_corroborate_firmware: normalization failed for happy" >&2; return 1
  }
  if [[ -z "$normalized_happy" ]]; then
    echo "regen_corroborate_firmware: normalization produced empty output (happy)" >&2; return 1
  fi
  # Mandatory in-regen leak check (model: regen_corroborate_native_r2 :1010-1016).
  if printf '%s\n' "$normalized_happy" \
       | grep -qE '/home/|/tmp/|cristian|linuxbrew|\.dotnet'; then
    echo "regen_corroborate_firmware: host path leaked after normalization (happy) — aborting" >&2
    printf '%s\n' "$normalized_happy" \
      | grep -E '/home/|/tmp/|cristian|linuxbrew|\.dotnet' >&2
    return 1
  fi
  write_fixture "corroborate-firmware" "happy" "$normalized_happy"

  # --- Capped run (--max-findings 2; status=partial; exits 1) ---
  local out_capped="$tmp/out_capped"
  RSDD_BINWALK_TEST_ONLY="$tmp/fake-bwalk/binwalk" \
    PATH="$tmp/fake-bwalk:/usr/bin:/bin" \
    python3 "$sut_py" \
      --input "$tmp/firmware.bin" --output "$out_capped" \
      --max-findings 2 \
      --manifest-cli "$man" 2>/dev/null
  local capped_rc=$?
  # SUT exits 1 for partial (truncated=true) — this is expected, not an error.
  if [[ "$capped_rc" -ne 1 ]]; then
    echo "regen_corroborate_firmware: capped run should exit 1 (partial), got $capped_rc" >&2
    return 1
  fi

  local normalized_capped
  normalized_capped="$(_normalize_fw "$out_capped/firmware-static.v1.json")" || {
    echo "regen_corroborate_firmware: normalization failed for capped" >&2; return 1
  }
  if [[ -z "$normalized_capped" ]]; then
    echo "regen_corroborate_firmware: normalization produced empty output (capped)" >&2; return 1
  fi
  if printf '%s\n' "$normalized_capped" \
       | grep -qE '/home/|/tmp/|cristian|linuxbrew|\.dotnet'; then
    echo "regen_corroborate_firmware: host path leaked after normalization (capped) — aborting" >&2
    printf '%s\n' "$normalized_capped" \
      | grep -E '/home/|/tmp/|cristian|linuxbrew|\.dotnet' >&2
    return 1
  fi
  write_fixture "corroborate-firmware" "capped" "$normalized_capped"
}

# regen_corroborate_ghidra — writes curated input fixtures from Python (no real Ghidra),
# then regenerates report.json by running the SUT with real bwrap + fake stubs.
#
# Fixtures produced:
#   corroborate-ghidra/curated_happy.json    — valid complete curated evidence.
#   corroborate-ghidra/curated_dishonest.json — status=complete but truncation lie (partial).
#   corroborate-ghidra/curated_sentinel.json  — raw RSDD-SENTINEL bytes (no JSON).
#   corroborate-ghidra/report.json           — normalized corroboration report (real bwrap).
#
# Normalization of report.json (§7 — all host-specific fields):
#   input.source.path, provenance[*].source.path, isolation.launcher.path → __*_PATH__
#   all sha256 values → __SHA256__; all size values → __SIZE__
#   ghidra.version → __GHIDRA_VERSION__; runtime.python → __PYTHON__; runtime.kernel → __KERNEL__
#   ghidra.argv omitted (contains absolute paths + timestamps — not stable across machines).
#
# Curated fixture regen is always cheap (pure Python, no real tool).
# report.json regen requires: bwrap (/usr/bin/bwrap), gcc, python3.
# shellcheck disable=SC2317  # regen function called via name; not reachable by static flow
regen_corroborate_ghidra() {
  local toolbelt="$SCRIPT_DIR/.."
  local suite="corroborate-ghidra"
  local fix_dir="$FIXTURE_BASE/$suite"
  mkdir -p "$fix_dir"

  # --- Curated input fixtures (pure Python, no real Ghidra/bwrap needed) ---
  python3 - "$fix_dir" <<'PY'
import json, pathlib, sys
fix_dir = pathlib.Path(sys.argv[1])

caps = {"exports": 2, "functions": 2, "imports": 2, "references": 2,
        "string_chars": 32, "strings": 2, "symbols": 2}
program = {"compiler": "x", "format": "ELF", "image_base": "0",
           "language": "x", "md5": "0", "name": "target.bin"}
base_counts = {k: {"emitted": 0, "exact": True, "observed": 0}
               for k in ("exports","functions","imports","references","strings","symbols")}
base_trunc  = {k: False for k in base_counts}

# curated_happy.json — valid complete curated evidence
happy = {
    "analysis": {"timed_out": False}, "caps": caps, "counts": base_counts,
    "errors": [], "exports": [], "functions": [], "imports": [], "limitations": ["static"],
    "program": program, "references": [], "schema": "ghidra-curated-evidence.v1",
    "status": "complete", "string_values_truncated": 0, "strings": [], "symbols": [],
    "truncation": base_trunc, "warnings": [],
}
(fix_dir / "curated_happy.json").write_text(
    json.dumps(happy, indent=2, sort_keys=True) + "\n")

# curated_dishonest.json — status=complete but truncation["functions"]=True (lie)
import copy
dishonest = copy.deepcopy(happy)
dishonest["truncation"]["functions"] = True
dishonest["counts"]["functions"]     = {"emitted": 0, "exact": False, "observed": 1}
(fix_dir / "curated_dishonest.json").write_text(
    json.dumps(dishonest, indent=2, sort_keys=True) + "\n")

# curated_sentinel.json — raw RSDD-SENTINEL bytes (no JSON, no trailing newline)
(fix_dir / "curated_sentinel.json").write_bytes(b"RSDD-SENTINEL")

print(f"wrote curated_happy.json, curated_dishonest.json, curated_sentinel.json")
PY
  local py_rc=$?
  if [[ "$py_rc" -ne 0 ]]; then
    echo "regen_corroborate_ghidra: curated fixture generation failed (rc=$py_rc)" >&2
    return 1
  fi

  # --- report.json (real bwrap + fake stubs; skip if bwrap unavailable) ---
  if ! [[ -x /usr/bin/bwrap ]]; then
    echo "regen_corroborate_ghidra: /usr/bin/bwrap not found; skipping report.json regen" >&2
    return 0
  fi
  for _regen_tool in gcc python3; do
    command -v "$_regen_tool" >/dev/null 2>&1 || {
      echo "regen_corroborate_ghidra: '$_regen_tool' not found; skipping report.json regen" >&2
      return 0
    }
  done

  local tmp; tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" RETURN

  # Compile tiny ELF target (constructor marker for TARGET_EXECUTED check).
  cat >"$tmp/target.c" <<'CSRC'
#include <stdio.h>
__attribute__((constructor)) static void marker(void){FILE*f=fopen("TARGET_EXECUTED","w");if(f)fclose(f);}
int main(void){return 0;}
CSRC
  gcc -o "$tmp/target.bin" "$tmp/target.c" || {
    echo "regen_corroborate_ghidra: gcc failed; skipping report.json regen" >&2; return 0
  }

  # Set up fake Ghidra stubs (no real Ghidra needed).
  mkdir -p "$tmp/gh/support" "$tmp/gh/Ghidra/Framework/Utility/lib" "$tmp/jdk/bin"
  printf 'application.name=Ghidra\napplication.version=12.1-regen\n' \
    >"$tmp/gh/Ghidra/application.properties"
  for f in support/launch.sh support/launch.properties support/LaunchSupport.jar \
            Ghidra/Framework/Utility/lib/Utility.jar; do
    printf '%s\n' "$f" >"$tmp/gh/$f"
  done
  cat >"$tmp/jdk/bin/java" <<'SH'; chmod 755 "$tmp/jdk/bin/java"
#!/bin/sh
[ "${1:-}" = -version ] && { echo 'openjdk version "21.0.1"' >&2; exit 0; }; exit 0
SH
  cp "$tmp/jdk/bin/java" "$tmp/jdk/bin/javap"
  # Fake analyzeHeadless (good mode — outputs valid curated JSON).
  cat >"$tmp/gh/support/analyzeHeadless" <<'SH'; chmod 755 "$tmp/gh/support/analyzeHeadless"
#!/bin/sh
[ "${1:-}" = -help ] && { echo 'Headless Analyzer Usage'; exit 0; }
java --adapter-probe || exit 8
out=''; log=''; scriptlog=''; prev=''
for x in "$@"; do
  [ "$prev" = CuratedEvidenceExporter.java ] && out="$x"
  [ "$prev" = -log ] && log="$x"; [ "$prev" = -scriptlog ] && scriptlog="$x"
  prev="$x"
done
printf 'stdout\n'; printf 'log\n' >"$log"; printf 'scriptlog\n' >"$scriptlog"
python3 - "$out" <<'PY'
import json, sys
caps = {"functions":2,"symbols":2,"imports":2,"exports":2,"strings":2,"references":2,"string_chars":32}
names = list(caps)[:6]
d = {"schema":"ghidra-curated-evidence.v1","status":"complete",
     "program":{"name":"target.bin","format":"ELF","language":"x","compiler":"x","image_base":"0","md5":"0"},
     "analysis":{"timed_out":False},"caps":caps,
     "truncation":{n:False for n in names},
     "counts":{n:{"emitted":0,"observed":0,"exact":True} for n in names},
     "string_values_truncated":0,"warnings":[],"errors":[],"limitations":["static"]}
for n in names: d[n] = []
open(sys.argv[1],"w").write(json.dumps(d,separators=(",",":"))+"\n")
PY
SH

  local out_dir="$tmp/out"
  local man="$toolbelt/analysis_manifest.py"
  ANALYZE_HEADLESS="$tmp/gh/support/analyzeHeadless" \
  JAVA_HOME="$tmp/jdk" \
  RSDD_BWRAP="/usr/bin/bwrap" \
  RSDD_MANIFEST_CLI="$man" \
  RSDD_TEST_ONLY_UNTRUSTED_BWRAP=0 \
    bash "$toolbelt/corroborate-ghidra.sh" \
      --input "$tmp/target.bin" --output "$out_dir" \
      --timeout-seconds 30 --max-diagnostic-bytes 2000 \
      --max-functions 2 --max-strings 2 --max-references 2 --max-string-chars 32 \
    2>/dev/null
  local sut_rc=$?
  if [[ "$sut_rc" -ne 0 ]] || [[ ! -f "$out_dir/report.json" ]]; then
    echo "regen_corroborate_ghidra: SUT run failed (rc=$sut_rc); skipping report.json regen" >&2
    return 0
  fi

  # Normalize: replace all host paths / sha256 / size / version fields.
  local normalized
  normalized="$(python3 - "$out_dir/report.json" <<'PY'
import json, sys
from pathlib import Path

def normalize(obj, depth=0):
    if isinstance(obj, dict):
        out = {}
        for k, v in obj.items():
            if k == "path" and isinstance(v, str) and v.startswith("/"):
                out[k] = f"__PATH_{k.upper()}__"
            elif k in ("sha256",) and isinstance(v, str):
                out[k] = "__SHA256__"
            elif k in ("size",) and isinstance(v, int):
                out[k] = "__SIZE__"
            elif k == "version" and depth == 1 and isinstance(v, str):
                out[k] = "__GHIDRA_VERSION__"
            elif k == "python" and isinstance(v, str):
                out[k] = "__PYTHON__"
            elif k == "kernel" and isinstance(v, str):
                out[k] = "__KERNEL__"
            elif k == "argv":
                out[k] = ["__ARGV__"]  # omit volatile argv
            else:
                out[k] = normalize(v, depth + 1)
        return out
    elif isinstance(obj, list):
        return [normalize(i, depth + 1) for i in obj]
    return obj

raw = json.loads(Path(sys.argv[1]).read_text())
normalized = normalize(raw)
# Flatten path placeholders per provenance entry for readability.
for i, entry in enumerate(normalized.get("provenance", [])):
    for side in ("source", "staged"):
        if isinstance(entry.get(side), dict) and entry[side].get("path") == "__PATH_PATH__":
            entry[side]["path"] = f"__PROVENANCE_{i}_SOURCE_PATH__" if side == "source" else entry[side]["path"]
# Fix input.source.path placeholder
if isinstance(normalized.get("input"), dict):
    src = normalized["input"].get("source", {})
    if src.get("path") == "__PATH_PATH__":
        src["path"] = "__INPUT_PATH__"
# Fix isolation.launcher.path placeholder
if isinstance(normalized.get("isolation"), dict):
    lnch = normalized["isolation"].get("launcher", {})
    if lnch.get("path") == "__PATH_PATH__":
        lnch["path"] = "__BWRAP_PATH__"
print(json.dumps(normalized, indent=2, sort_keys=True))
PY
  )"
  if [[ -z "$normalized" ]]; then
    echo "regen_corroborate_ghidra: normalization produced empty output" >&2; return 1
  fi

  # Leak check: normalized output must not contain host paths.
  if printf '%s\n' "$normalized" \
       | grep -qE '/home/|/tmp/|cristian|linuxbrew|\.dotnet'; then
    echo "regen_corroborate_ghidra: host path leaked after normalization — aborting" >&2
    printf '%s\n' "$normalized" \
      | grep -E '/home/|/tmp/|cristian|linuxbrew|\.dotnet' >&2
    return 1
  fi

  write_fixture "$suite" "report" "$normalized"
}

# regen_jvm_callgraph — runs the jvm-callgraph SUT on a synthetic App→Router→Transform→Sink
# fixture jar and normalizes the JSON report to a host-path-free committed fixture.
#
# Fixtures produced:
#   jvm-callgraph/happy.json  — full run with Sink-specific filter; entries/paths/xrefs intact.
#   jvm-callgraph/capped.json — tight caps (max-nodes=1 etc); truncated.nodes/edges/xrefs/paths=true.
#
# Normalization (all machine-specific fields replaced with stable placeholders):
#   runtime.java_home              → __JAVA_HOME__
#   runtime.launcher.path          → __JAVA_LAUNCHER_PATH__
#   runtime.launcher.{sha256,size} → __SHA256__ / __SIZE__
#   runtime.version                → __JAVA_VERSION__
#   runtime.vendor                 → __JAVA_VENDOR__
#   runtime.major                  kept as integer (fast-lane asserts >= 21, not exact value)
#   analyzer.path                  → __ANALYZER_PATH__
#   analyzer.{sha256,size}         → __SHA256__ / __SIZE__  (build-nondeterministic: jar timestamps)
#   inputs.primary.path            → __INPUT_PATH__
#   inputs.primary.{sha256,size}   → __SHA256__ / __SIZE__
#   inputs.dependencies[i].{path,sha256,size} → normalized (empty for our fixture)
#
# CRITICAL: java is under /home/linuxbrew on this machine, so runtime.java_home and
# runtime.launcher.path contain the 'linuxbrew' token.  The normalizer MUST replace both
# before the mandatory in-regen leak-check or regen aborts.
#
# Requires: java 21+, mvn, python3.
# shellcheck disable=SC2317  # regen function called via name; not reachable by static flow
regen_jvm_callgraph() {
  local toolbelt="$SCRIPT_DIR/.."
  local wrapper="$toolbelt/jvm-callgraph.sh"
  local jar="$toolbelt/jvm-callgraph/target/jvm-callgraph.jar"

  # Source tool-env for Java resolution helpers.
  # shellcheck source=../lib/tool-env.sh
  source "$toolbelt/lib/tool-env.sh"

  local java_home
  java_home="$(rsdd_resolve_java_home 2>/dev/null || true)"
  if [ -z "$java_home" ] || [ ! -x "$java_home/bin/javac" ]; then
    echo "regen_jvm_callgraph: usable Java not found; skipping" >&2
    return 0
  fi
  local javac_major
  javac_major="$("$java_home/bin/javac" -version 2>&1 | grep -oE '[0-9]+' | head -1)"
  if [ "${javac_major:-0}" -lt 21 ]; then
    echo "regen_jvm_callgraph: javac major=${javac_major} < 21; skipping" >&2
    return 0
  fi
  if ! command -v mvn >/dev/null 2>&1; then
    echo "regen_jvm_callgraph: mvn not found; skipping" >&2
    return 0
  fi

  # Build analyzer jar if missing; reuse target/jvm-callgraph.jar when already present.
  if [ ! -f "$jar" ]; then
    echo "regen_jvm_callgraph: jar missing; building with mvn -o -B -ntp package" >&2
    (cd "$toolbelt/jvm-callgraph" && mvn -o -B -ntp package -q) || {
      echo "regen_jvm_callgraph: mvn build failed; aborting" >&2; return 1
    }
  fi

  local tmp; tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" RETURN

  # Compile App→Router→Transform→Sink fixture jar.
  # No MARKER side-effect here; the fixture is for call-graph analysis only.
  mkdir -p "$tmp/src/fixture" "$tmp/classes"
  cat > "$tmp/src/fixture/App.java" <<'JAVA'
package fixture;
public final class App {
  public static void main(String[] args) { Router.route(args.length); }
}
JAVA
  cat > "$tmp/src/fixture/Router.java" <<'JAVA'
package fixture; final class Router { static void route(int value) { Transform.normalize(value); } }
JAVA
  cat > "$tmp/src/fixture/Transform.java" <<'JAVA'
package fixture; final class Transform { static void normalize(int value) { Sink.write(Integer.toString(value)); } }
JAVA
  cat > "$tmp/src/fixture/Sink.java" <<'JAVA'
package fixture; final class Sink { static void write(String value) { System.out.println(value); } }
JAVA
  "$java_home/bin/javac" --release 21 -d "$tmp/classes" "$tmp"/src/fixture/*.java || {
    echo "regen_jvm_callgraph: javac failed; aborting" >&2; return 1
  }
  "$java_home/bin/jar" --create --file "$tmp/fixture.jar" -C "$tmp/classes" . || {
    echo "regen_jvm_callgraph: jar creation failed; aborting" >&2; return 1
  }

  # Inline normalizer: replaces all host-specific fields with stable placeholders.
  # runtime.major is kept as an integer (assertion is >= 21, not exact value).
  _normalize_jvm() {
    python3 - "$1" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))

# runtime — all host-specific: java_home, launcher path/sha256/size, version, vendor.
# runtime.major is kept as the actual integer — the fast-lane test asserts >= 21.
d["runtime"]["java_home"] = "__JAVA_HOME__"
d["runtime"]["launcher"]["path"] = "__JAVA_LAUNCHER_PATH__"
d["runtime"]["launcher"]["sha256"] = "__SHA256__"
d["runtime"]["launcher"]["size"] = "__SIZE__"
d["runtime"]["version"] = "__JAVA_VERSION__"
d["runtime"]["vendor"] = "__JAVA_VENDOR__"

# analyzer — build-nondeterministic: Maven/jar embed zip timestamps → hash changes
# every mvn package invocation even with identical source.
d["analyzer"]["path"] = "__ANALYZER_PATH__"
d["analyzer"]["sha256"] = "__SHA256__"
d["analyzer"]["size"] = "__SIZE__"

# inputs.primary — fixture jar path and hash.
d["inputs"]["primary"]["path"] = "__INPUT_PATH__"
d["inputs"]["primary"]["sha256"] = "__SHA256__"
d["inputs"]["primary"]["size"] = "__SIZE__"

# inputs.dependencies — normalize if present (empty for our fixture; future-proof).
for i, dep in enumerate(d["inputs"].get("dependencies", [])):
    dep["path"] = f"__DEP_{i}_PATH__"
    dep["sha256"] = "__SHA256__"
    dep["size"] = "__SIZE__"

print(json.dumps(d, indent=2, sort_keys=True))
PY
  }

  # --- Happy run ---
  local out_happy="$tmp/happy.json"
  bash "$wrapper" analyze \
    --input "$tmp/fixture.jar" \
    --sink-contains "fixture.Sink: void write" \
    --max-depth 8 --max-paths 10 --max-nodes 100 --max-edges 100 --max-xrefs 100 \
    --output "$out_happy" 2>/dev/null || {
    echo "regen_jvm_callgraph: happy run failed; aborting" >&2; return 1
  }

  local normalized_happy
  normalized_happy="$(_normalize_jvm "$out_happy")" || {
    echo "regen_jvm_callgraph: normalization failed for happy" >&2; return 1
  }
  if [[ -z "$normalized_happy" ]]; then
    echo "regen_jvm_callgraph: normalization produced empty output (happy)" >&2; return 1
  fi
  # Mandatory in-regen leak-check (model: regen_corroborate_native_r2).
  # java lives under /home/linuxbrew — 'linuxbrew' token MUST be caught if missed.
  if printf '%s\n' "$normalized_happy" \
       | grep -qE '/home/|/tmp/|cristian|linuxbrew|\.dotnet'; then
    echo "regen_jvm_callgraph: host path leaked after normalization (happy) — aborting" >&2
    printf '%s\n' "$normalized_happy" \
      | grep -E '/home/|/tmp/|cristian|linuxbrew|\.dotnet' >&2
    return 1
  fi
  write_fixture "jvm-callgraph" "happy" "$normalized_happy"

  # --- Capped run (tight caps; truncated.nodes/edges/xrefs/paths expected True) ---
  # Uses --sink-contains fixture (broader than happy) to produce more xrefs across all
  # fixture-package sinks, ensuring xrefsCut fires even with max-xrefs=1.
  local out_capped="$tmp/capped.json"
  bash "$wrapper" analyze \
    --input "$tmp/fixture.jar" \
    --sink-contains fixture \
    --max-depth 1 --max-paths 1 --max-nodes 1 --max-edges 1 --max-xrefs 1 \
    --output "$out_capped" 2>/dev/null || {
    echo "regen_jvm_callgraph: capped run failed; aborting" >&2; return 1
  }

  local normalized_capped
  normalized_capped="$(_normalize_jvm "$out_capped")" || {
    echo "regen_jvm_callgraph: normalization failed for capped" >&2; return 1
  }
  if [[ -z "$normalized_capped" ]]; then
    echo "regen_jvm_callgraph: normalization produced empty output (capped)" >&2; return 1
  fi
  if printf '%s\n' "$normalized_capped" \
       | grep -qE '/home/|/tmp/|cristian|linuxbrew|\.dotnet'; then
    echo "regen_jvm_callgraph: host path leaked after normalization (capped) — aborting" >&2
    printf '%s\n' "$normalized_capped" \
      | grep -E '/home/|/tmp/|cristian|linuxbrew|\.dotnet' >&2
    return 1
  fi
  write_fixture "jvm-callgraph" "capped" "$normalized_capped"
}

# regen_corroborate_native_r2 — runs corroborate-native on a gcc-compiled ELF
# and normalizes the report to a host-path-free committed fixture.
#
# Fixtures produced:
#   corroborate-native-r2/happy.json  — full run, status=complete, functions_emitted>=1.
#   corroborate-native-r2/capped.json — --max-functions 1, status=partial, emitted=1.
#
# Normalization (all machine-specific fields replaced with stable placeholders):
#   input.source.path → <INPUT_PATH>; input size fields → <SIZE>
#   input sha256 pair (source == staged) → <SHA_INPUT>
#   isolation.launcher path/size → <BWRAP_PATH>/<SIZE>; sha256 → <BWRAP_SHA>
#   engine.version → <R2_VERSION>; engine.manifest_identity → <MANIFEST_IDENTITY>
#   engine.launcher.source path/size → <R2_PATH>/<SIZE>
#   engine.launcher sha256 pair (source == staged) → <SHA_R2>
#   Relative logical paths (input/target.bin, engine/r2) kept as-is.
#   engine.argv kept as-is (all entries relative, safe to commit).
#   runtime.python → <PYTHON>; runtime.kernel → <KERNEL>
#
# CONTENT-ADDRESSED MANIFEST TRAP (spec correction D): the on-disk
#   engine/analysis-manifest.v1.json is NEVER normalized — verify recomputes
#   identity from raw bytes and a normalized manifest would fail.  Only the
#   engine.manifest_identity scalar in the report JSON is replaced with
#   <MANIFEST_IDENTITY>.
#
# Requires: r2, gcc, /usr/bin/bwrap (root-owned), python3.
# shellcheck disable=SC2317  # regen function called via name; not reachable by static flow
regen_corroborate_native_r2() {
  local toolbelt="$SCRIPT_DIR/.."
  local sut="$toolbelt/corroborate-native.sh"

  if ! [ -x "$sut" ]; then
    echo "regen_corroborate_native_r2: SUT not found: $sut; skipping" >&2
    return 0
  fi

  for _regen_tool in r2 gcc python3; do
    command -v "$_regen_tool" >/dev/null 2>&1 || {
      echo "regen_corroborate_native_r2: '$_regen_tool' not found; skipping" >&2
      return 0
    }
  done
  if ! [ -x /usr/bin/bwrap ]; then
    echo "regen_corroborate_native_r2: /usr/bin/bwrap not found or not executable; skipping" >&2
    return 0
  fi

  local tmp; tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" RETURN

  # Compile tiny ELF with a constructor that writes TARGET_EXECUTED if executed.
  # bwrap isolation must prevent this; the fixture records the analysis, not execution.
  cat >"$tmp/fixture.c" <<'CSRC'
#include <stdio.h>
__attribute__((constructor)) static void marker(void){FILE*f=fopen("TARGET_EXECUTED","w");if(f)fclose(f);}
static int helper(int n){return n+7;} int main(void){return helper(35)==42?0:1;}
CSRC
  gcc -O0 -g -fno-pie -no-pie -o "$tmp/fixture.elf" "$tmp/fixture.c" || {
    echo "regen_corroborate_native_r2: gcc failed; aborting" >&2; return 1
  }

  # Inline normalizer (called per fixture; reads raw JSON from stdin via sys.argv[1]).
  # Verifies sha256 equality pairs before replacing with distinct placeholders:
  #   <SHA_INPUT> for the input binary pair, <SHA_R2> for the r2 launcher pair.
  # This preserves both equality invariants independently (a single global placeholder
  # would let an input↔r2 swap pass undetected — spec correction C).
  _normalize() {
    local raw="$1"
    python3 - "$raw" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))

# Verify equality pairs before normalizing (SUT correctness gate).
inp = d["input"]
assert inp["source"]["sha256"] == inp["staged"]["sha256"], (
    f"input sha256 mismatch: {inp['source']['sha256']!r} != {inp['staged']['sha256']!r}")
lnch = d["engine"]["launcher"]
assert lnch["source"]["sha256"] == lnch["staged"]["sha256"], (
    f"r2 launcher sha256 mismatch: {lnch['source']['sha256']!r} != {lnch['staged']['sha256']!r}")

# input — absolute path + machine-specific size and sha256
d["input"]["source"]["path"] = "<INPUT_PATH>"
d["input"]["source"]["size"] = "<SIZE>"
d["input"]["source"]["sha256"] = "<SHA_INPUT>"
d["input"]["staged"]["size"] = "<SIZE>"
d["input"]["staged"]["sha256"] = "<SHA_INPUT>"
# input.staged.path == "input/target.bin" — relative logical path, kept as-is

# runtime
d["runtime"]["python"] = "<PYTHON>"
d["runtime"]["kernel"] = "<KERNEL>"

# isolation.launcher (bwrap binary) — absolute path, machine-specific
d["isolation"]["launcher"]["path"] = "<BWRAP_PATH>"
d["isolation"]["launcher"]["size"] = "<SIZE>"
d["isolation"]["launcher"]["sha256"] = "<BWRAP_SHA>"
# isolation.profile is a constant struct, no paths to normalize

# engine
d["engine"]["version"] = "<R2_VERSION>"
d["engine"]["manifest_identity"] = "<MANIFEST_IDENTITY>"
d["engine"]["launcher"]["source"]["path"] = "<R2_PATH>"
d["engine"]["launcher"]["source"]["size"] = "<SIZE>"
d["engine"]["launcher"]["source"]["sha256"] = "<SHA_R2>"
d["engine"]["launcher"]["staged"]["size"] = "<SIZE>"
d["engine"]["launcher"]["staged"]["sha256"] = "<SHA_R2>"
# engine.launcher.staged.path == "engine/r2" — relative, kept as-is
# engine.argv == ["engine/r2", *SAFE_R2] — all relative, safe to commit

print(json.dumps(d, indent=2, sort_keys=True))
PY
  }

  # --- Happy run (complete, no cap) ---
  local out_happy="$tmp/out_happy"
  bash "$sut" --input "$tmp/fixture.elf" --output "$out_happy" 2>/dev/null || {
    echo "regen_corroborate_native_r2: happy run failed" >&2; return 1
  }
  local normalized_happy
  normalized_happy="$(_normalize "$out_happy/native-static.v1.json")" || {
    echo "regen_corroborate_native_r2: normalization failed for happy" >&2; return 1
  }
  if [[ -z "$normalized_happy" ]]; then
    echo "regen_corroborate_native_r2: normalization produced empty output (happy)" >&2; return 1
  fi
  # Mandatory leak check (model: regen_ghidra_c_exporter :378-385).
  # Any remaining host path aborts the regen — do NOT trust the normalizer blind.
  if printf '%s\n' "$normalized_happy" \
       | grep -qE '/home/|/tmp/|cristian|linuxbrew|\.dotnet'; then
    echo "regen_corroborate_native_r2: host path leaked after normalization (happy) — aborting" >&2
    printf '%s\n' "$normalized_happy" \
      | grep -E '/home/|/tmp/|cristian|linuxbrew|\.dotnet' >&2
    return 1
  fi
  write_fixture "corroborate-native-r2" "happy" "$normalized_happy"

  # --- Capped run (--max-functions 1, status=partial, exits 1) ---
  local out_capped="$tmp/out_capped"
  bash "$sut" --input "$tmp/fixture.elf" --output "$out_capped" --max-functions 1 2>/dev/null
  local capped_rc=$?
  # SUT exits 1 for partial (truncated=true) — this is expected, not an error.
  if [[ "$capped_rc" -ne 1 ]]; then
    echo "regen_corroborate_native_r2: capped run should exit 1 (partial), got $capped_rc" >&2
    return 1
  fi
  local normalized_capped
  normalized_capped="$(_normalize "$out_capped/native-static.v1.json")" || {
    echo "regen_corroborate_native_r2: normalization failed for capped" >&2; return 1
  }
  if [[ -z "$normalized_capped" ]]; then
    echo "regen_corroborate_native_r2: normalization produced empty output (capped)" >&2; return 1
  fi
  if printf '%s\n' "$normalized_capped" \
       | grep -qE '/home/|/tmp/|cristian|linuxbrew|\.dotnet'; then
    echo "regen_corroborate_native_r2: host path leaked after normalization (capped) — aborting" >&2
    printf '%s\n' "$normalized_capped" \
      | grep -E '/home/|/tmp/|cristian|linuxbrew|\.dotnet' >&2
    return 1
  fi
  write_fixture "corroborate-native-r2" "capped" "$normalized_capped"
}

# --- Main ---------------------------------------------------------------------

if [[ ${#KNOWN_SUITES[@]} -eq 0 ]]; then
  echo "regen-lane-fixtures: no suites registered yet." >&2
  echo "  Add a regen_<suite>() function and a KNOWN_SUITES entry to register one." >&2
  exit 0
fi

ran=0
skipped=0

for suite in "${KNOWN_SUITES[@]}"; do
  if [[ -n "$SUITE_FILTER" && "$suite" != "$SUITE_FILTER" ]]; then
    skipped=$((skipped + 1))
    continue
  fi

  # Derive function name: replace hyphens with underscores.
  fn="regen_${suite//-/_}"
  if ! declare -F "$fn" >/dev/null 2>&1; then
    echo "WARNING: no regen function $fn for suite $suite — skipping" >&2
    skipped=$((skipped + 1))
    continue
  fi

  echo "--- regenerating fixtures for: $suite (lane=$REGEN_LANE) ---"
  "$fn"
  ran=$((ran + 1))
done

echo ""
echo "regen-lane-fixtures: ran=$ran skipped=$skipped lane=$REGEN_LANE dry_run=$DRY_RUN"
