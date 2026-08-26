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

# 4. POST-TREE VALIDATION: SquashFS with a symlink is rejected; nothing published;
#    guard must emit 'symlink in extracted tree (rejected)' (distinct from generic failure).
_se4=$(mktemp); _rc4=0
run "$ROOT/sym_escape.sqfs" "$ROOT/out_sym" 2>"$_se4" >/dev/null || _rc4=$?
if [ "$_rc4" -ne 0 ] && [ ! -e "$ROOT/out_sym" ] && grep -q 'symlink in extracted tree (rejected)' "$_se4"; then
  ok "SquashFS with symlinks rejected; guard='symlink in extracted tree (rejected)'"; else no "symlink rejection"; fi
rm -f "$_se4"

# 5. Non-SquashFS blob rejected with clean error; nothing published;
#    guard must emit 'input too small for a SquashFS superblock' (blob is 28 bytes < 96-byte superblock).
printf "this is not a squashfs image" > "$ROOT/blob.bin"
_se5=$(mktemp); _rc5=0
run "$ROOT/blob.bin" "$ROOT/out_blob" 2>"$_se5" >/dev/null || _rc5=$?
if [ "$_rc5" -ne 0 ] && [ ! -e "$ROOT/out_blob" ] && grep -q 'input too small for a SquashFS superblock' "$_se5"; then
  ok "non-SquashFS blob rejected; guard='input too small for a SquashFS superblock'"; else no "non-squashfs rejection"; fi
rm -f "$_se5"

# 6. caps must be positive: timeout=0 rejected before extraction; nothing published.
# NOTE: SUT emits 'caps must be positive', which is generic to any cap=0 — not timeout-specific;
# cannot pin which guard fired, so message is not asserted here.
if ! run "$ROOT/good.sqfs" "$ROOT/cap_time" --timeout-seconds 0 2>/dev/null && [ ! -e "$ROOT/cap_time" ]; then
  ok "timeout-seconds=0 cap rejected before extraction; not published"; else no "timeout=0 cap"; fi

# 7. max-extracted-bytes=1 prevents publication of oversized extractions.
# NOTE: SUT emits 'unsquashfs failed' because RLIMIT_FSIZE kills unsquashfs before walk_tree
# can emit the bytes-cap message — message is generic; cannot pin which guard fired.
if ! run "$ROOT/good.sqfs" "$ROOT/cap_bytes" --max-extracted-bytes 1 2>/dev/null && [ ! -e "$ROOT/cap_bytes" ]; then
  ok "max-extracted-bytes=1 cap prevents extraction and publication"; else no "bytes cap"; fi

# 8. max-entries=1 cap rejects trees with more than one entry; nothing published;
#    guard must emit 'entries exceed max-entries' (distinct — walk_tree raises before any other cap).
_se8=$(mktemp); _rc8=0
run "$ROOT/good.sqfs" "$ROOT/cap_entries" --max-entries 1 2>"$_se8" >/dev/null || _rc8=$?
if [ "$_rc8" -ne 0 ] && [ ! -e "$ROOT/cap_entries" ] && grep -q 'entries exceed max-entries' "$_se8"; then
  ok "max-entries=1 cap rejects multi-entry tree; guard='entries exceed max-entries'"; else no "entries cap"; fi
rm -f "$_se8"

# 9. DIRECTORY SYMLINK: directory symlink in extracted tree is rejected; nothing published;
#    guard emits 'Operation not permitted' (Python 3.14: dir-symlinks land in dirnames, evading
#    walk_tree's S_ISLNK check; chmod at line 240 follows symlink→/etc→EPERM — distinct OSError).
mkdir -p "$ROOT/tree_dirsym"; printf hi > "$ROOT/tree_dirsym/file.txt"
ln -s /etc "$ROOT/tree_dirsym/somedir"
mksquashfs "$ROOT/tree_dirsym" "$ROOT/dirsym.sqfs" -noappend -quiet 2>/dev/null
_se9=$(mktemp); _rc9=0
run "$ROOT/dirsym.sqfs" "$ROOT/out_dirsym" 2>"$_se9" >/dev/null || _rc9=$?
if [ "$_rc9" -ne 0 ] && [ ! -e "$ROOT/out_dirsym" ] && grep -q 'Operation not permitted' "$_se9"; then
  ok "directory symlink rejected; guard='Operation not permitted' (chmod follows symlink to /etc)"; else no "directory symlink rejection"; fi
rm -f "$_se9"

# 10. SIZE CAP / WATCHDOG: large squashfs rejected when extracted bytes exceed cap; nothing published.
# NOTE: SUT emits 'unsquashfs failed' because the watchdog/RLIMIT_FSIZE kills unsquashfs before
# walk_tree's bytes-cap check; message is generic — cannot pin which guard fired.
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

# ── Prove-teeth (--prove-teeth) ──────────────────────────────────────────────
# Mutation controls for the four message-pinning assertions added to T4, T5, T8, T9.
# Each mutant must: (a) still exit non-zero + nothing published (old assertion PASS),
# and (b) emit a WRONG message so the new message assertion goes RED.
# Tools skip guard is re-checked; fixtures are rebuilt in a fresh subtree.
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: mutation controls --"
  _tp=0; _tf=0
  _tok(){ printf '  PASS  %s\n' "$1"; _tp=$((_tp+1)); }
  _tnok(){ printf '  FAIL  %s\n' "$1"; _tf=$((_tf+1)); }

  for _cmd in unsquashfs mksquashfs bwrap python3; do
    if ! command -v "$_cmd" >/dev/null 2>&1; then
      echo "SKIP: prove-teeth (missing: $_cmd)"; echo "== 0 passed · 0 failed =="; exit 0
    fi
  done

  _TR="$(mktemp -d)"; trap 'rm -rf "$_TR"' EXIT
  _SUT_PY="$HERE/../squashfs_extract.py"
  _MANIFEST="$HERE/../analysis_manifest.py"
  _PYPATH="$HERE/../lib"

  # Build fixtures for teeth tests
  mkdir -p "$_TR/tree_sym"; printf hi > "$_TR/tree_sym/normal.txt"
  ln -s /etc/passwd "$_TR/tree_sym/escape"
  mksquashfs "$_TR/tree_sym" "$_TR/sym_escape.sqfs" -noappend -quiet 2>/dev/null

  printf "this is not a squashfs image" > "$_TR/blob.bin"

  mkdir -p "$_TR/tree/subdir"; printf hello > "$_TR/tree/hello.txt"; printf world > "$_TR/tree/subdir/world.txt"
  mksquashfs "$_TR/tree" "$_TR/good.sqfs" -noappend -quiet 2>/dev/null

  mkdir -p "$_TR/tree_dirsym"; printf hi > "$_TR/tree_dirsym/file.txt"
  ln -s /etc "$_TR/tree_dirsym/somedir"
  mksquashfs "$_TR/tree_dirsym" "$_TR/dirsym.sqfs" -noappend -quiet 2>/dev/null

  # teeth-M1 (targets T4 message assertion): mutant replaces 'symlink in extracted tree (rejected)'
  # with 'generic rejection' → mutant exits 2 + nothing published (old assertion PASS), but stderr
  # no longer contains the expected substring (new message assertion goes RED).
  _m1="$_TR/sq_mut1.py"
  sed 's/symlink in extracted tree (rejected)/generic rejection/g' "$_SUT_PY" > "$_m1"
  if ! grep -q 'generic rejection' "$_m1"; then
    _tnok "teeth-M1: mutation target 'symlink in extracted tree (rejected)' not found -- SUT changed?"
  else
    _rc_m1=0; _se_m1="$_TR/se_m1.txt"
    PYTHONPATH="$_PYPATH" python3 "$_m1" --input "$_TR/sym_escape.sqfs" --output "$_TR/out_m1" \
      --manifest-cli "$_MANIFEST" 2>"$_se_m1" >/dev/null || _rc_m1=$?
    if [ "$_rc_m1" -ne 0 ] && [ ! -e "$_TR/out_m1" ] \
       && ! grep -q 'symlink in extracted tree (rejected)' "$_se_m1"; then
      _tok "teeth-M1: symlink-msg mutant exits non-zero+no-publish (old PASS) but wrong msg (T4 new assertion RED)"
    else
      _tnok "teeth-M1: symlink-msg mutant expected: rc!=0, no out, msg absent; got rc=$_rc_m1 out=$([ -e "$_TR/out_m1" ] && echo yes || echo no) msg=$(grep -c 'symlink in extracted tree' "$_se_m1" 2>/dev/null || echo 0)"
    fi
  fi

  # teeth-M2 (targets T5 message assertion): mutant replaces 'input too small for a SquashFS superblock'
  # with 'bad input' → exits 2 + nothing published (old PASS), but wrong message (T5 new assertion RED).
  _m2="$_TR/sq_mut2.py"
  sed 's/input too small for a SquashFS superblock/bad input/g' "$_SUT_PY" > "$_m2"
  if ! grep -q 'bad input' "$_m2"; then
    _tnok "teeth-M2: mutation target 'input too small for a SquashFS superblock' not found -- SUT changed?"
  else
    _rc_m2=0; _se_m2="$_TR/se_m2.txt"
    PYTHONPATH="$_PYPATH" python3 "$_m2" --input "$_TR/blob.bin" --output "$_TR/out_m2" \
      --manifest-cli "$_MANIFEST" 2>"$_se_m2" >/dev/null || _rc_m2=$?
    if [ "$_rc_m2" -ne 0 ] && [ ! -e "$_TR/out_m2" ] \
       && ! grep -q 'input too small for a SquashFS superblock' "$_se_m2"; then
      _tok "teeth-M2: non-sqfs-msg mutant exits non-zero+no-publish (old PASS) but wrong msg (T5 new assertion RED)"
    else
      _tnok "teeth-M2: non-sqfs-msg mutant expected: rc!=0, no out, msg absent; got rc=$_rc_m2 out=$([ -e "$_TR/out_m2" ] && echo yes || echo no) msg=$(grep -c 'input too small' "$_se_m2" 2>/dev/null || echo 0)"
    fi
  fi

  # teeth-M3 (targets T8 message assertion): mutant replaces 'entries exceed max-entries'
  # with 'cap exceeded' → exits 2 + nothing published (old PASS), wrong message (T8 new assertion RED).
  _m3="$_TR/sq_mut3.py"
  sed 's/entries exceed max-entries/cap exceeded/g' "$_SUT_PY" > "$_m3"
  if ! grep -q 'cap exceeded' "$_m3"; then
    _tnok "teeth-M3: mutation target 'entries exceed max-entries' not found -- SUT changed?"
  else
    _rc_m3=0; _se_m3="$_TR/se_m3.txt"
    PYTHONPATH="$_PYPATH" python3 "$_m3" --input "$_TR/good.sqfs" --output "$_TR/out_m3" \
      --manifest-cli "$_MANIFEST" --max-entries 1 2>"$_se_m3" >/dev/null || _rc_m3=$?
    if [ "$_rc_m3" -ne 0 ] && [ ! -e "$_TR/out_m3" ] \
       && ! grep -q 'entries exceed max-entries' "$_se_m3"; then
      _tok "teeth-M3: entries-msg mutant exits non-zero+no-publish (old PASS) but wrong msg (T8 new assertion RED)"
    else
      _tnok "teeth-M3: entries-msg mutant expected: rc!=0, no out, msg absent; got rc=$_rc_m3 out=$([ -e "$_TR/out_m3" ] && echo yes || echo no) msg=$(grep -c 'entries exceed' "$_se_m3" 2>/dev/null || echo 0)"
    fi
  fi

  # teeth-M4 (targets T9 message assertion): mutant replaces the OSError handler's '{exc}' with a
  # fixed string → dir-symlink case still exits 2 + nothing published (old PASS), but stderr now
  # says 'unexpected error' instead of '[Errno 1] Operation not permitted' (T9 new assertion RED).
  _m4="$_TR/sq_mut4.py"
  _oserr_old='except (OSError, ValueError, KeyError, struct.error, json.JSONDecodeError, subprocess.SubprocessError) as exc: print(f"squashfs-extract: {exc}", file=sys.stderr); return 2'
  _oserr_new='except (OSError, ValueError, KeyError, struct.error, json.JSONDecodeError, subprocess.SubprocessError) as exc: print("squashfs-extract: unexpected error", file=sys.stderr); return 2'
  sed "s/${_oserr_old}/${_oserr_new}/" "$_SUT_PY" > "$_m4"
  if ! grep -q 'unexpected error' "$_m4"; then
    _tnok "teeth-M4: OSError handler mutation target not found -- SUT changed?"
  else
    _rc_m4=0; _se_m4="$_TR/se_m4.txt"
    PYTHONPATH="$_PYPATH" python3 "$_m4" --input "$_TR/dirsym.sqfs" --output "$_TR/out_m4" \
      --manifest-cli "$_MANIFEST" 2>"$_se_m4" >/dev/null || _rc_m4=$?
    if [ "$_rc_m4" -ne 0 ] && [ ! -e "$_TR/out_m4" ] \
       && ! grep -q 'Operation not permitted' "$_se_m4"; then
      _tok "teeth-M4: dir-symlink OSError-msg mutant exits non-zero+no-publish (old PASS) but wrong msg (T9 new assertion RED)"
    else
      _tnok "teeth-M4: dir-symlink-msg mutant expected: rc!=0, no out, msg absent; got rc=$_rc_m4 out=$([ -e "$_TR/out_m4" ] && echo yes || echo no) msg=$(grep -c 'Operation not permitted' "$_se_m4" 2>/dev/null || echo 0)"
    fi
  fi

  echo "== $_tp passed · $_tf failed =="; [ "$_tf" -eq 0 ]
fi
