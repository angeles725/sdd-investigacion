#!/usr/bin/env bash
# zip-metadata.test.sh — the end-to-end check of the zip-metadata.sh compatibility shim (kit issue #2416, epic #2270).
#
# The parser moved to Go: `rsdd formats zip-metadata` (research-sdd/rsdd/internal/formats/zipmetadata.go). Its cases
# (every legacy case of this suite, the legacy Python as the oracle over single-byte corruptions of the fixtures, and
# the Go mutation controls) live in the Go tests (`go test ./internal/formats`, `make teeth`). This suite keeps a few
# end-to-end cases through the shim and the mutation controls of the shim itself.
#
# Usage: zip-metadata.test.sh [--prove-teeth]     Exit: 0 all held · 1 regression · 2 harness error
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"  # LINT-CD-PHYSICAL-OK: test driver locating its SUT; run from the kit checkout by path
TB="$(cd "$HERE/.." && pwd)"  # LINT-CD-PHYSICAL-OK: as above
SUT="$TB/zip-metadata.sh"
# shellcheck source=lib/mutant.sh
. "$HERE/lib/mutant.sh" || exit 2
mutant_bootstrap mutant_chain mutant_tooth || exit 2
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
ROOT="$(mktemp -d)" || exit 2
trap 'rm -rf "$ROOT"' EXIT
pass=0; fail=0
ok() { echo "  PASS  $1"; pass=$((pass+1)); }
no() { echo "  FAIL  $1"; fail=$((fail+1)); }

# The SUT hands over to the Go binary. $RSDD_BIN wins; otherwise one binary is built into the suite temp dir (never
# into the tree). A suite that cannot get rsdd says so with a typed SKIP, or FAILS under RSDD_REQUIRE_GO=1.
if [ -z "${RSDD_BIN:-}" ] || [ ! -x "${RSDD_BIN:-}" ]; then
  if ! command -v go >/dev/null 2>&1; then
    why="go not in PATH"
    [ -z "${RSDD_BIN:-}" ] || why="RSDD_BIN is not an executable file ($RSDD_BIN) and go is not in PATH"
    if [ "${RSDD_REQUIRE_GO:-}" = "1" ]; then
      echo "  FAIL  rsdd-unavailable: $why (RSDD_REQUIRE_GO=1)"; echo "== 0 passed · 1 failed =="; exit 1
    fi
    echo "SKIP rsdd-unavailable: $why (tool-missing; set RSDD_REQUIRE_GO=1 to fail instead)"
    echo "== 0 passed · 0 failed =="; exit 0
  fi
  RSDD_BIN="$ROOT/rsdd"
  ( cd "$TB/../rsdd" && CGO_ENABLED=0 GOTOOLCHAIN=local GOFLAGS='' GOWORK=off go build -o "$RSDD_BIN" ./cmd/rsdd ) >"$ROOT/build.log" 2>&1 \
    || { echo "FATAL: cannot build rsdd" >&2; tail -n 20 "$ROOT/build.log" >&2; exit 2; }
fi
export RSDD_BIN
# A guard stands in for rsdd where the shim's arguments are checked: it refuses (exit 9) any --manifest-cli and otherwise runs
# the real binary, so a shim that hands the manifest tool path over again is caught (the Go commands accept and ignore the flag).
RSDD_REAL_BIN="$RSDD_BIN"; export RSDD_REAL_BIN
printf '%s\n' '#!/usr/bin/env bash' 'for a in "$@"; do [ "$a" = "--manifest-cli" ] && { echo "rsdd-guard: unexpected --manifest-cli" >&2; exit 9; }; done' \
  'exec "$RSDD_REAL_BIN" "$@"' >"$ROOT/rsdd-guard" && chmod 755 "$ROOT/rsdd-guard"
RSDD_BIN="$ROOT/rsdd-guard" "$SUT" --bogus >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 2 ]; then ok "the shim hands no --manifest-cli to rsdd"; else no "the shim hands a --manifest-cli to rsdd (guard exit $rc)"; fi
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 not on PATH (fixtures and the manifest tool need it)" >&2; exit 2; }

mkdir "$ROOT/in" "$ROOT/out" && chmod 755 "$ROOT/out" || exit 2
python3 - "$ROOT/in" <<'PY' || exit 2
import pathlib,struct,sys
r=pathlib.Path(sys.argv[1])
def make(path, entries=(), truncate=0):
 body=bytearray(); central=bytearray()
 for raw,flags,method,payload in entries:
  off=len(body); crc=0x12345678
  body+=struct.pack('<I5H3I2H',0x04034b50,20,flags,method,0,0,crc,len(payload),len(payload),len(raw),0)+raw+payload
  central+=struct.pack('<I6H3I5H2I',0x02014b50,20,20,flags,method,0,0,crc,len(payload),len(payload),len(raw),0,0,0,0,0,off)+raw
 cd=len(body); body+=central
 end=struct.pack('<I4H2IH',0x06054b50,0,0,len(entries),len(entries),len(central),cd,0)
 path.write_bytes((body+end)[:-truncate] if truncate else body+end)
make(r/'mixed.zip',[(b'ok.txt',0,0,b'PAYLOAD-NOT-METADATA'),(b'../evil',1,99,b'SECRET'),(b'\\root',0,8,b'X'),(b'/abs',0,0,b'Y'),(b'dup',0,0,b'A'),(b'dup',0,0,b'B'),(b'nul\0x',0,0,b'C')])
make(r/'truncated.zip',[],1)
PY
run() { "$SUT" --input "$1" --output "$2" "${@:3}"; }

if run "$ROOT/in/mixed.zip" "$ROOT/out/a" && run "$ROOT/in/mixed.zip" "$ROOT/out/b" && cmp -s "$ROOT/out/a/zip-metadata.v1.json" "$ROOT/out/b/zip-metadata.v1.json"; then
  ok "the shim publishes a deterministic inventory"
else no "the shim publishes a deterministic inventory"; fi

if python3 - "$ROOT/out/a" <<'PY'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1]); d=json.loads((p/'zip-metadata.v1.json').read_bytes()); e=d['entries']
assert d['schema']=='zip-metadata.v1' and len(e)==7 and d['payload_bytes_read']==0
assert e[1]['encrypted'] and e[1]['method']==99 and e[1]['safety']['traversal']
assert e[2]['safety']['backslash'] and e[3]['safety']['absolute']
assert e[4]['safety']['duplicate'] and e[5]['safety']['duplicate'] and e[6]['safety']['nul']
assert {x.name for x in p.iterdir()}=={'input','stdout.txt','stderr.txt','zip-metadata.v1.json','analysis-manifest.v1.json'}
assert b'PAYLOAD-NOT-METADATA' not in (p/'input/central-directory.bin').read_bytes()
PY
then ok "dangerous, duplicate, encrypted, and unknown-method metadata is marked only"; else no "metadata contract"; fi

if "$RSDD_BIN" adapter manifest verify --root "$ROOT/out/a" "$ROOT/out/a/analysis-manifest.v1.json" >/dev/null; then ok "the published analysis manifest verifies"; else no "manifest verification"; fi

run "$ROOT/in/truncated.zip" "$ROOT/out/truncated" 2>"$ROOT/err.txt"; rc=$?
if [ "$rc" -eq 2 ] && grep -q '^zip-metadata: truncated' "$ROOT/err.txt" && [ ! -e "$ROOT/out/truncated" ] && [ ! -e "$ROOT/out/.truncated.stage" ]; then
  ok "a damaged archive exits 2 with the typed message and publishes nothing"; else no "a damaged archive exits $rc: $(cat "$ROOT/err.txt")"; fi

run "$ROOT/in/mixed.zip" "$ROOT/out/capped" --max-entries 2 2>/dev/null; rc=$?
if [ "$rc" -eq 2 ] && [ ! -e "$ROOT/out/capped" ]; then ok "the caller's arguments reach the Go command (a cap fails closed)"; else no "cap pass-through (exit $rc)"; fi

mkdir "$ROOT/out/collision" "$ROOT/out/.occupied.stage"; echo keep >"$ROOT/out/collision/keep"; echo stage >"$ROOT/out/.occupied.stage/keep"
if ! run "$ROOT/in/mixed.zip" "$ROOT/out/collision" 2>/dev/null && ! run "$ROOT/in/mixed.zip" "$ROOT/out/occupied" 2>/dev/null \
  && [ -f "$ROOT/out/collision/keep" ] && [ -f "$ROOT/out/.occupied.stage/keep" ]; then
  ok "destination and stage collisions are preserved"; else no "path collisions"; fi

if [ "${1:-}" != "--prove-teeth" ]; then
  echo "== $pass passed · $fail failed =="
  [ "$fail" -eq 0 ] && exit 0 || exit 1
fi
[ "$fail" -eq 0 ] || { echo "== $pass passed · $fail failed (teeth skipped) =="; exit 1; }

echo "-- teeth: zip-metadata.sh shim mutation controls --"
RSDD_BIN="$ROOT/rsdd-guard"; export RSDD_BIN   # every tooth run goes through the guard of the argument check above
# a mutant of the shim must still find lib/rsdd-exec.sh: it lives in a throwaway kit skeleton
KC="$ROOT/kitcopy"; mkdir -p "$KC" && ln -s "$TB/lib" "$KC/lib"
# each tooth run publishes into a fresh name: the original and the mutant must not collide on one destination
# and an exit 0 that did not publish this tool's report is exit 9 (a sibling command succeeding is not this command)
printf '%s\n' '#!/usr/bin/env bash' 'out="$(mktemp -u "$2/toothXXXXXX")" || exit 2' '"$1" --input "$3" --output "$out"; rc=$?' \
  '[ "$rc" -ne 0 ] || [ -f "$out/zip-metadata.v1.json" ] || exit 9' 'exit "$rc"' >"$ROOT/tooth-run.sh"
tooth() { # LABEL SED_EXPR GOOD_RC BAD_RC [tooth opts...]
  local label="$1" expr="$2" g="$3" b="$4"; shift 4
  local m="$KC/${label// /_}.sh"
  if ! mutant_chain "$label" "$SUT" "$m" "$expr" >"$ROOT/mutant.log"; then cat "$ROOT/mutant.log"; no "tooth $label: mutant refused"; return; fi
  chmod +x "$m"
  if mutant_tooth "tooth $label" "$g" "$b" "$m" "$@" -- bash "$ROOT/tooth-run.sh" @SUT@ "$ROOT/out" "$ROOT/in/mixed.zip"; then pass=$((pass+1)); else fail=$((fail+1)); fi
}
tooth "shim dispatches to the sibling command" 's/rsdd_exec formats zip-metadata/rsdd_exec formats zip-stored/' 0 2
tooth "shim drops the caller's arguments" 's/ "\$@"$//' 0 2
tooth "shim hands the manifest tool over again" 's/ "\$@"$/ --manifest-cli \/nonexistent\/analysis_manifest.py "$@"/' 0 9
echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] && exit 0 || exit 1
