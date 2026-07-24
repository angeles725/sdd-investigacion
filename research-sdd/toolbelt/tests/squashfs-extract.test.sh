#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; SUT="$HERE/../squashfs-extract.sh"
ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT; pass=0; fail=0
ok(){ echo "  PASS  $1"; pass=$((pass+1)); }; no(){ echo "  FAIL  $1"; fail=$((fail+1)); }

# SKIP guard: all required tools must be present
for _cmd in unsquashfs mksquashfs bwrap python3; do
  if ! command -v "$_cmd" >/dev/null 2>&1; then
    echo "SKIP: squashfs-extract tests (missing: $_cmd)"; echo "== 0 passed · 0 failed =="; exit 0
  fi
done
[ -f "$SUT" ] || { echo "SKIP: $SUT not found"; echo "== 0 passed · 0 failed =="; exit 0; }

# Build good fixture: two files + one subdir
mkdir -p "$ROOT/tree/subdir"
printf hello > "$ROOT/tree/hello.txt"; printf world > "$ROOT/tree/subdir/world.txt"
mksquashfs "$ROOT/tree" "$ROOT/good.sqfs" -noappend -quiet 2>/dev/null

# Build symlink-escape fixture: symlink targeting an absolute path outside the tree
mkdir -p "$ROOT/tree_sym"; printf hi > "$ROOT/tree_sym/normal.txt"
ln -s /etc/passwd "$ROOT/tree_sym/escape"
mksquashfs "$ROOT/tree_sym" "$ROOT/sym_escape.sqfs" -noappend -quiet 2>/dev/null

run(){ "$SUT" --input "$1" --output "$2" "${@:3}"; }

# 1. Determinism: two extractions of the same input produce byte-identical evidence JSON
if run "$ROOT/good.sqfs" "$ROOT/out_a" && run "$ROOT/good.sqfs" "$ROOT/out_b" \
   && cmp -s "$ROOT/out_a/squashfs-extract.v1.json" "$ROOT/out_b/squashfs-extract.v1.json"; then
  ok "two runs produce byte-identical evidence JSON"; else no "determinism"; fi

# 2. Evidence schema, sorted entries, per-file sha256, closed tree, ownership/modes
if python3 - "$ROOT/out_a" <<'PY'
import hashlib,json,os,pathlib,stat,sys
p=pathlib.Path(sys.argv[1]); d=json.loads((p/'squashfs-extract.v1.json').read_bytes())
assert d['schema']=='squashfs-extract.v1', d.get('schema')
entries=d['entries']; assert entries==sorted(entries,key=lambda e:e['path']), "entries not sorted"
for e in [x for x in entries if x['type']=='file']:
  actual='sha256:'+hashlib.sha256((p/'extracted'/e['path']).read_bytes()).hexdigest()
  assert e['sha256']==actual and 'mode' in e and 'size' in e,(e['path'],e['sha256'],actual)
# closed tree: exactly expected files present
expected_files={'squashfs-extract.v1.json','analysis-manifest.v1.json','stdout.txt','stderr.txt'}
expected_files|={'extracted/'+e['path'] for e in entries if e['type']=='file'}
actual_files={str(x.relative_to(p)) for x in p.rglob('*') if x.is_file()}
assert actual_files==expected_files,(expected_files,actual_files)
# ownership + modes (0700 dirs, 0400 files, no symlinks)
for x in p.rglob('*'):
  assert not x.is_symlink(),f"symlink in output: {x}"
  m=x.lstat(); assert m.st_uid==os.getuid() and stat.S_IMODE(m.st_mode)==(0o700 if stat.S_ISDIR(m.st_mode) else 0o400)
PY
then ok "evidence schema, sorted entries, file hashes, closed tree, ownership/modes"; else no "evidence format"; fi

# 3. Analysis manifest verifies
if python3 "$HERE/../analysis_manifest.py" verify --root "$ROOT/out_a" "$ROOT/out_a/analysis-manifest.v1.json" >/dev/null 2>&1; then
  ok "analysis manifest verifies"; else no "analysis manifest"; fi

# 4. POST-TREE VALIDATION: SquashFS with a symlink is rejected; nothing published
if ! run "$ROOT/sym_escape.sqfs" "$ROOT/out_sym" 2>/dev/null && [ ! -e "$ROOT/out_sym" ]; then
  ok "SquashFS with symlinks rejected; no partial publication"; else no "symlink rejection"; fi

# 5. Non-SquashFS blob rejected with clean error; nothing published
printf "this is not a squashfs image" > "$ROOT/blob.bin"
if ! run "$ROOT/blob.bin" "$ROOT/out_blob" 2>/dev/null && [ ! -e "$ROOT/out_blob" ]; then
  ok "non-SquashFS blob rejected with AdapterError"; else no "non-squashfs rejection"; fi

# 6. caps must be positive: timeout=0 rejected before extraction; nothing published
if ! run "$ROOT/good.sqfs" "$ROOT/cap_time" --timeout-seconds 0 2>/dev/null && [ ! -e "$ROOT/cap_time" ]; then
  ok "timeout-seconds=0 cap rejected before extraction; not published"; else no "timeout=0 cap"; fi

# 7. max-extracted-bytes=1 prevents publication of oversized extractions
if ! run "$ROOT/good.sqfs" "$ROOT/cap_bytes" --max-extracted-bytes 1 2>/dev/null && [ ! -e "$ROOT/cap_bytes" ]; then
  ok "max-extracted-bytes=1 cap prevents extraction and publication"; else no "bytes cap"; fi

# 8. max-entries=1 cap rejects trees with more than one entry; nothing published
if ! run "$ROOT/good.sqfs" "$ROOT/cap_entries" --max-entries 1 2>/dev/null && [ ! -e "$ROOT/cap_entries" ]; then
  ok "max-entries=1 cap rejects multi-entry tree; not published"; else no "entries cap"; fi

# 9. DIRECTORY SYMLINK: directory symlink in extracted tree is rejected; nothing published
mkdir -p "$ROOT/tree_dirsym"; printf hi > "$ROOT/tree_dirsym/file.txt"
ln -s /etc "$ROOT/tree_dirsym/somedir"
mksquashfs "$ROOT/tree_dirsym" "$ROOT/dirsym.sqfs" -noappend -quiet 2>/dev/null
if ! run "$ROOT/dirsym.sqfs" "$ROOT/out_dirsym" 2>/dev/null && [ ! -e "$ROOT/out_dirsym" ]; then
  ok "directory symlink in extracted tree rejected; nothing published"; else no "directory symlink rejection"; fi

# 10. SIZE CAP / WATCHDOG: large squashfs rejected when extracted bytes exceed cap; nothing published
mkdir -p "$ROOT/tree_bomb"
dd if=/dev/urandom bs=4k count=64 of="$ROOT/tree_bomb/big.bin" 2>/dev/null
mksquashfs "$ROOT/tree_bomb" "$ROOT/bomb.sqfs" -noappend -quiet 2>/dev/null
if ! run "$ROOT/bomb.sqfs" "$ROOT/out_bomb" --max-extracted-bytes 4096 2>/dev/null && [ ! -e "$ROOT/out_bomb" ]; then
  ok "oversized extraction rejected (watchdog+cap); nothing published"; else no "size cap / watchdog"; fi


# 11. root execution refused (geteuid==0) → exit 2, 'root or set-id' in stderr
if python3 - "$HERE/../squashfs_extract.py" <<'PY'
import importlib.util,io,sys
from contextlib import redirect_stderr
s=importlib.util.spec_from_file_location('sq',sys.argv[1]); m=importlib.util.module_from_spec(s); s.loader.exec_module(m)
m.os.geteuid=lambda:0; buf=io.StringIO()
with redirect_stderr(buf): r=m.main(['--input','x','--output','y','--manifest-cli','z'])
assert r==2 and "root or set-id" in buf.getvalue()
PY
then ok "root execution refused (geteuid==0): exit 2, root-or-set-id in stderr"; else no "root refusal"; fi

echo "== $pass passed · $fail failed =="; [ "$fail" -eq 0 ]
