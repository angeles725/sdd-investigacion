#!/usr/bin/env bash
# zip-stored.test.sh — the end-to-end check of the zip-stored.sh compatibility shim (kit issue #2416, epic #2270).
#
# The extractor moved to Go: `rsdd formats zip-stored` (research-sdd/rsdd/internal/formats/zipstored.go). Its cases
# (every legacy case of this suite, the legacy Python as the oracle over single-byte corruptions of the fixtures, and
# the Go mutation controls) live in the Go tests (`go test ./internal/formats`, `make teeth`). This suite keeps a few
# end-to-end cases through the shim and the mutation controls of the shim itself.
#
# Usage: zip-stored.test.sh [--prove-teeth]     Exit: 0 all held · 1 regression · 2 harness error
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"  # LINT-CD-PHYSICAL-OK: test driver locating its SUT; run from the kit checkout by path
TB="$(cd "$HERE/.." && pwd)"  # LINT-CD-PHYSICAL-OK: as above
SUT="$TB/zip-stored.sh"
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
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 not on PATH (fixtures and the manifest tool need it)" >&2; exit 2; }

mkdir "$ROOT/in" "$ROOT/out" && chmod 755 "$ROOT/out" || exit 2
python3 - "$ROOT/in" <<'PY' || exit 2
import binascii,pathlib,struct,sys
r=pathlib.Path(sys.argv[1])
def make(path,entries):
 body=bytearray(); central=bytearray()
 for name,data,method,flags,attrs,extra in entries:
  raw=name.encode(); off=len(body); crc=binascii.crc32(data)&0xffffffff
  body+=struct.pack('<I5H3I2H',0x04034b50,20,flags,method,1,0x5821,crc,len(data),len(data),len(raw),len(extra))+raw+extra+data
  central+=struct.pack('<I6H3I5H2I',0x02014b50,(3<<8)|20,20,flags,method,1,0x5821,crc,len(data),len(data),len(raw),len(extra),0,0,0,attrs,off)+raw+extra
 cd=len(body); body+=central; body+=struct.pack('<I4H2IH',0x06054b50,0,0,len(entries),len(entries),len(central),cd,0); path.write_bytes(body)
reg=0o100644<<16; directory=(0o40755<<16)|0x10
make(r/'good.zip',[('dir/',b'',0,0,directory,b''),('dir/a.txt',b'alpha',0,0,reg,b''),('b.bin',b'\0\1',0,0,reg,b'')])
for name,entries in [('deflate',[('x',b'x',8,0,reg,b'')]),('traversal',[('../x',b'x',0,0,reg,b'')]),('symlink',[('x',b'target',0,0,0o120777<<16,b'')]),
 ('duplicate',[('x',b'a',0,0,reg,b''),('x',b'b',0,0,reg,b'')])]: make(r/f'{name}.zip',entries)
data=bytearray((r/'good.zip').read_bytes()); data[73]^=1; (r/'payload.zip').write_bytes(data)
PY
run() { "$SUT" --input "$1" --output "$2" "${@:3}"; }

if run "$ROOT/in/good.zip" "$ROOT/out/a" && run "$ROOT/in/good.zip" "$ROOT/out/b" && cmp -s "$ROOT/out/a/zip-stored.v1.json" "$ROOT/out/b/zip-stored.v1.json"; then
  ok "the shim extracts STORED files deterministically"
else no "the shim extracts STORED files deterministically"; fi

if python3 - "$ROOT/out/a" <<'PY'
import hashlib,json,os,pathlib,stat,sys
p=pathlib.Path(sys.argv[1]); d=json.loads((p/'zip-stored.v1.json').read_bytes())
assert d['schema']=='zip-stored.v1' and [x['path'] for x in d['entries']]==['dir/','dir/a.txt','b.bin']
assert (p/'dir/a.txt').read_bytes()==b'alpha' and d['entries'][1]['sha256']=='sha256:'+hashlib.sha256(b'alpha').hexdigest()
assert {str(x.relative_to(p)) for x in p.rglob('*') if x.is_file()}=={'dir/a.txt','b.bin','zip-stored.v1.json','stdout.txt','stderr.txt','analysis-manifest.v1.json'}
assert {str(x.relative_to(p)) for x in p.rglob('*') if x.is_dir()}=={'dir'}
for x in p.rglob('*'): assert not x.is_symlink() and x.stat().st_uid==os.getuid() and stat.S_IMODE(x.stat().st_mode)==(0o700 if x.is_dir() else 0o400)
PY
then ok "report, hashes, modes, and the closed tree are exact"; else no "published tree"; fi

if python3 "$TB/analysis_manifest.py" verify --root "$ROOT/out/a" "$ROOT/out/a/analysis-manifest.v1.json" >/dev/null; then ok "the published analysis manifest verifies"; else no "manifest"; fi

bad=1
for name in deflate traversal symlink duplicate payload; do
  run "$ROOT/in/$name.zip" "$ROOT/out/out-$name" 2>"$ROOT/err-$name.txt"; rc=$?
  if [ "$rc" -ne 2 ] || [ -e "$ROOT/out/out-$name" ] || [ -e "$ROOT/out/.out-$name.stage" ]; then bad=0; echo "    $name: exit $rc"; fi
done
if [ "$bad" -eq 1 ] && grep -q '^zip-stored: payload CRC32 mismatch' "$ROOT/err-payload.txt"; then
  ok "unsupported, unsafe, conflicting, and corrupt archives exit 2 and publish nothing"; else no "fail-closed cases"; fi

run "$ROOT/in/good.zip" "$ROOT/out/capped" --max-total-bytes 6 2>/dev/null; rc=$?
if [ "$rc" -eq 2 ] && [ ! -e "$ROOT/out/capped" ]; then ok "the caller's arguments reach the Go command (a cap fails closed)"; else no "cap pass-through (exit $rc)"; fi

mkdir "$ROOT/out/collision" "$ROOT/out/.occupied.stage"; printf keep >"$ROOT/out/collision/keep"; printf keep >"$ROOT/out/.occupied.stage/keep"
if ! run "$ROOT/in/good.zip" "$ROOT/out/collision" 2>/dev/null && ! run "$ROOT/in/good.zip" "$ROOT/out/occupied" 2>/dev/null \
  && [ -f "$ROOT/out/collision/keep" ] && [ -f "$ROOT/out/.occupied.stage/keep" ]; then
  ok "destination and stage collisions are preserved"; else no "publication collisions"; fi

if [ "${1:-}" != "--prove-teeth" ]; then
  echo "== $pass passed · $fail failed =="
  [ "$fail" -eq 0 ] && exit 0 || exit 1
fi
[ "$fail" -eq 0 ] || { echo "== $pass passed · $fail failed (teeth skipped) =="; exit 1; }

echo "-- teeth: zip-stored.sh shim mutation controls --"
# a mutant of the shim must still find lib/rsdd-exec.sh and analysis_manifest.py: it lives in a throwaway kit skeleton
KC="$ROOT/kitcopy"; mkdir -p "$KC" && ln -s "$TB/lib" "$KC/lib" && ln -s "$TB/analysis_manifest.py" "$KC/analysis_manifest.py"
# each tooth run publishes into a fresh name: the original and the mutant must not collide on one destination
# and an exit 0 that did not publish this tool's report is exit 9 (a sibling command succeeding is not this command)
printf '%s\n' '#!/usr/bin/env bash' 'out="$(mktemp -u "$2/toothXXXXXX")" || exit 2' '"$1" --input "$3" --output "$out"; rc=$?' \
  '[ "$rc" -ne 0 ] || [ -f "$out/zip-stored.v1.json" ] || exit 9' 'exit "$rc"' >"$ROOT/tooth-run.sh"
tooth() { # LABEL SED_EXPR GOOD_RC BAD_RC [tooth opts...]
  local label="$1" expr="$2" g="$3" b="$4"; shift 4
  local m="$KC/${label// /_}.sh"
  if ! mutant_chain "$label" "$SUT" "$m" "$expr" >"$ROOT/mutant.log"; then cat "$ROOT/mutant.log"; no "tooth $label: mutant refused"; return; fi
  chmod +x "$m"
  if mutant_tooth "tooth $label" "$g" "$b" "$m" "$@" -- bash "$ROOT/tooth-run.sh" @SUT@ "$ROOT/out" "$ROOT/in/good.zip"; then pass=$((pass+1)); else fail=$((fail+1)); fi
}
tooth "shim dispatches to the sibling command" 's/rsdd_exec formats zip-stored/rsdd_exec formats zip-metadata/' 0 9
tooth "shim drops the caller's arguments" 's/ "\$@"$//' 0 2
tooth "shim drops the manifest tool" 's/--manifest-cli "\$_RSDD_SELF\/analysis_manifest.py" //' 0 2
echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] && exit 0 || exit 1
