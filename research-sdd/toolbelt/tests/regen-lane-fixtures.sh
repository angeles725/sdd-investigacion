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
  floss
  ghidra-c-exporter
  ghidra-exporter
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
