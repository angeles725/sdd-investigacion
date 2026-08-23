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
if isinstance(d.get("input"), dict):
    if "path" in d["input"]: d["input"]["path"] = "__INPUT_PATH__"
    if "file" in d["input"]: d["input"]["file"] = "__INPUT_PATH__"
if isinstance(d.get("isolation"), dict) and isinstance(d["isolation"].get("launcher"), dict):
    if "path" in d["isolation"]["launcher"]:
        d["isolation"]["launcher"]["path"] = "__BWRAP_PATH__"
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
if isinstance(d.get("input"), dict):
    if "path" in d["input"]: d["input"]["path"] = "__INPUT_PATH__"
    if "file" in d["input"]: d["input"]["file"] = "__INPUT_PATH__"
if isinstance(d.get("isolation"), dict) and isinstance(d["isolation"].get("launcher"), dict):
    if "path" in d["isolation"]["launcher"]:
        d["isolation"]["launcher"]["path"] = "__BWRAP_PATH__"
print(json.dumps(d, indent=2, sort_keys=True))
PY
)"
    write_fixture "floss" "$name" "$normalized"
  }

  _floss_run_and_write "happy"
  _floss_run_and_write "capped"     --max-strings 2
  _floss_run_and_write "len_capped" --max-string-len 5
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
