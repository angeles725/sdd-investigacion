#!/usr/bin/env bash
# Test suite for palette-lexicon-agents.sh (palette-lexicon.v1)
# TDD: tests written before implementation.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../palette-lexicon-agents.sh"
SUT_PY="$HERE/../palette_lexicon_agents.py"
FIXTURES="$HERE/fixtures/palette-lexicon-agents"
mkdir -p "$FIXTURES"

[ -x "$SUT" ] || { echo "FATAL: SUT not found or not executable: $SUT" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 not found" >&2; exit 2; }

pass=0; fail=0
ok(){ echo "  PASS  $1"; pass=$((pass+1)); }
no(){ echo "  FAIL  $1"; fail=$((fail+1)); }

ROOT="$(mktemp -d)"
trap '
  chmod 755 "$ROOT/unreadable-subdir-module/art-x/extracted/secret-dir" 2>/dev/null || true
  chmod 644 "$ROOT/unreadable-lexicon-module/art-y/extracted/locked.lexicon" 2>/dev/null || true
  rm -rf "$ROOT"
' EXIT

# ---------------------------------------------------------------------------
# Build hermetic fixtures (under tests/fixtures/, never inside a live target).
# Fixed date_time used in any ZIP fixtures for deterministic bytes.
# ---------------------------------------------------------------------------
python3 - "$FIXTURES" <<'PY'
import os, sys

out = sys.argv[1]

def write(p, content):
    os.makedirs(os.path.dirname(p), exist_ok=True)
    if not os.path.exists(p):
        with open(p, 'w', encoding='utf-8') as f:
            f.write(content)

def write_bytes(p, data):
    os.makedirs(os.path.dirname(p), exist_ok=True)
    if not os.path.exists(p):
        with open(p, 'wb') as f:
            f.write(data)

# ---------------------------------------------------------------------------
# valid-module: one artifact "alarm-rt" with palette, lexicon (duplicates), agents
# ---------------------------------------------------------------------------
BASE = os.path.join(out, 'valid-module', 'alarm-rt', 'extracted')

# module.palette: 3 <p> elements with at least one of n/t/m (root container + 2 children)
write(os.path.join(BASE, 'module.palette'), """\
<?xml version="1.0" encoding="UTF-8"?>
<bajaObjectGraph version="1.0">
<p m="b=baja" t="b:Folder">
<p m="alarm=alarm" n="AlarmSource" t="alarm:AlarmSource" />
<p m="alarm=alarm" n="AlarmDb" t="alarm:AlarmDb" />
</p>
</bajaObjectGraph>
""")

# alarm-rt.lexicon: 5 key lines, alarm.displayName appears twice (duplicate-bare-key hazard)
write(os.path.join(BASE, 'alarm-rt.lexicon'), """\
# Alarm module lexicon
alarm.displayName=Alarm
alarm.icon=alarm.png
alarm.description=This is the alarm module
alarm.displayName=Alarm Override
alarm.status=active
""")

# META-INF/module.xml: 1 type with 1 agent
write(os.path.join(BASE, 'META-INF', 'module.xml'), """\
<?xml version="1.0" encoding="UTF-8"?>
<module>
<type name="AlarmSource" class="com.example.alarm.BAlarmSource">
  <agent>
    <on type="baja:Component"/>
  </agent>
</type>
</module>
""")

# ---------------------------------------------------------------------------
# empty-module: directory exists but has no artifact subdirs
# ---------------------------------------------------------------------------
os.makedirs(os.path.join(out, 'empty-module'), exist_ok=True)
write(os.path.join(out, 'empty-module', 'README.txt'), 'empty module\n')

# ---------------------------------------------------------------------------
# no-data-module: artifact dir exists but no extracted/ contents
# ---------------------------------------------------------------------------
os.makedirs(os.path.join(out, 'no-data-module', 'bare-rt', 'extracted'), exist_ok=True)

# ---------------------------------------------------------------------------
# dup-keys-module: two artifacts, each with duplicate keys
# ---------------------------------------------------------------------------
ART1 = os.path.join(out, 'dup-keys-module', 'art-a', 'extracted')
write(os.path.join(ART1, 'art-a.lexicon'), """\
foo=value1
bar=value2
foo=value1b
""")

ART2 = os.path.join(out, 'dup-keys-module', 'art-b', 'extracted')
write(os.path.join(ART2, 'art-b.lexicon'), """\
x=1
y=2
x=3
y=4
z=5
""")

# ---------------------------------------------------------------------------
# bad-palette-module: module.palette is not valid XML
# ---------------------------------------------------------------------------
BAD = os.path.join(out, 'bad-palette-module', 'bad-rt', 'extracted')
write(os.path.join(BAD, 'module.palette'), "NOT VALID XML <unclosed")
write(os.path.join(BAD, 'bad-rt.lexicon'), "key1=value1\n")

# ---------------------------------------------------------------------------
# multi-lexicon-module: one locale module with MULTIPLE namespace files
# (e.g. lang-rt/extracted/{baja,alarm}.lexicon).
# Tests per-file dup detection:
#   - same key in two different files (shared.key) → NOT a dup (cross-file-only)
#   - key repeated within one file (slot.name in baja.lexicon) → IS a dup
# ---------------------------------------------------------------------------
LMB = os.path.join(out, 'multi-lexicon-module', 'lang-rt', 'extracted')
# baja.lexicon: 4 key lines; slot.name appears twice (within-file dup hazard)
write(os.path.join(LMB, 'baja.lexicon'), """\
# Baja namespace lexicon
shared.key=Baja Value
slot.name=Component
slot.name=Component Override
slot.desc=Description
""")
# alarm.lexicon: 2 key lines; shared.key appears once (cross-file from baja; NOT a dup under per-file)
write(os.path.join(LMB, 'alarm.lexicon'), """\
# Alarm namespace lexicon
shared.key=Alarm Value
alarm.status=Active
""")

# ---------------------------------------------------------------------------
# bom-lexicon-module: lexicon file starting with UTF-8 BOM (0xEF BB BF).
# 'title' appears on line 1 (BOM-prefixed) and again on line 3.
# With BOM stripping: 'title' x2 -> dup detected.
# Without stripping: '﻿title' + 'title' are different keys -> no dup.
# ---------------------------------------------------------------------------
BOM_DIR = os.path.join(out, 'bom-lexicon-module', 'bom-rt', 'extracted')
os.makedirs(BOM_DIR, exist_ok=True)
write_bytes(
    os.path.join(BOM_DIR, 'bom-rt.lexicon'),
    b'\xef\xbb\xbf' + b'title=Hello World\nversion=1.0\ntitle=Duplicate Title\n'
)


# ---------------------------------------------------------------------------
# same-basename-module: two locale subdirs each named baja.lexicon (Fix 1 / BLOCKER)
# fr/baja.lexicon:    'a' appears twice (within-file dup)
# fr_CA/baja.lexicon: 'b' appears twice (within-file dup)
# Before fix: keyed by basename -> second overwrites first -> count=1 (false-negative §7)
# After fix:  keyed by relpath  -> both distinct         -> count=2 (correct)
# ---------------------------------------------------------------------------
SMB = os.path.join(out, 'same-basename-module', 'locale-pack', 'extracted')
write(os.path.join(SMB, 'fr',    'baja.lexicon'), "a=x\na=y\n")
write(os.path.join(SMB, 'fr_CA', 'baja.lexicon'), "b=x\nb=y\n")

# ---------------------------------------------------------------------------
# nested-lexicon-module: lexicons at FIRST / MIDDLE / LAST depth (§7 list-edges)
# FIRST:  extracted/top.lexicon
# MIDDLE: extracted/sub/mid.lexicon
# LAST:   extracted/sub/deep/bottom.lexicon
# Proves _find_lexicon_files recurses to all levels; symlink fixture built in bash.
# ---------------------------------------------------------------------------
NLB = os.path.join(out, 'nested-lexicon-module', 'nested-rt', 'extracted')
write(os.path.join(NLB,                    'top.lexicon'),    "key_top=v\n")
write(os.path.join(NLB, 'sub',             'mid.lexicon'),    "key_mid=v\n")
write(os.path.join(NLB, 'sub', 'deep',     'bottom.lexicon'), "key_bottom=v\n")

PY

# ---------------------------------------------------------------------------
# Runtime-only fixtures (symlinks, chmod-000 dirs/files) — built in bash
# ---------------------------------------------------------------------------

# Symlink .lexicon inside nested-lexicon-module extracted/ for T20b / M12.
# Placed in $ROOT (not $FIXTURES) to avoid committing symlinks to git.
_T20b_MOD="$ROOT/symlink-lex-module"
mkdir -p "$_T20b_MOD/sym-rt/extracted"
printf 'key1=v\n' > "$_T20b_MOD/sym-rt/extracted/real.lexicon"
ln -sf "$_T20b_MOD/sym-rt/extracted/real.lexicon" \
  "$_T20b_MOD/sym-rt/extracted/link.lexicon"

# unreadable-subdir-module for T21 / M13
_T21_MOD="$ROOT/unreadable-subdir-module"
mkdir -p "$_T21_MOD/art-x/extracted/secret-dir"
printf 'key1=v1\n' > "$_T21_MOD/art-x/extracted/normal.lexicon"
printf 'hidden=secret\n' > "$_T21_MOD/art-x/extracted/secret-dir/hidden.lexicon"
chmod 000 "$_T21_MOD/art-x/extracted/secret-dir" 2>/dev/null || true

# unreadable-lexicon-module for T22 / M14
_T22_MOD="$ROOT/unreadable-lexicon-module"
mkdir -p "$_T22_MOD/art-y/extracted"
printf 'key1=v1\n' > "$_T22_MOD/art-y/extracted/readable.lexicon"
printf 'key2=v2\n' > "$_T22_MOD/art-y/extracted/locked.lexicon"
chmod 000 "$_T22_MOD/art-y/extracted/locked.lexicon" 2>/dev/null || true

# Detect root (chmod 000 is ineffective when running as root)
_IS_ROOT=0
[ "$(id -u)" -eq 0 ] && _IS_ROOT=1 || true

# ---------------------------------------------------------------------------
# T1: absent input → exit 2, no JSON produced
# ---------------------------------------------------------------------------
_t1_exit=0
"$SUT" --input "$ROOT/no-such-dir" --output "$ROOT/t1.json" 2>/dev/null \
  || _t1_exit=$?
if [ "$_t1_exit" -eq 2 ] && [ ! -f "$ROOT/t1.json" ]; then
  ok "T1 absent input: exit 2, no JSON"
else
  no "T1 absent input: expected exit 2 + no JSON, got exit $_t1_exit"
fi

# ---------------------------------------------------------------------------
# T2: symlink input → exit 2 (symlink guard)
# ---------------------------------------------------------------------------
ln -sf "$FIXTURES/valid-module" "$ROOT/sym-module"
_t2_exit=0
"$SUT" --input "$ROOT/sym-module" --output "$ROOT/t2.json" 2>/dev/null \
  || _t2_exit=$?
if [ "$_t2_exit" -eq 2 ]; then
  ok "T2 symlink input: exit 2 (symlink guard)"
else
  no "T2 symlink input: expected exit 2, got $_t2_exit"
fi

# ---------------------------------------------------------------------------
# T3: regular file input (not a directory) → exit 2
# ---------------------------------------------------------------------------
echo "notadir" > "$ROOT/notadir.txt"
_t3_exit=0
"$SUT" --input "$ROOT/notadir.txt" --output "$ROOT/t3.json" 2>/dev/null \
  || _t3_exit=$?
if [ "$_t3_exit" -eq 2 ]; then
  ok "T3 file input (not dir): exit 2"
else
  no "T3 file input (not dir): expected exit 2, got $_t3_exit"
fi

# ---------------------------------------------------------------------------
# T4: symlink input with trailing slash → exit 2
#     os.lstat("link/") follows symlinks on POSIX; must strip trailing sep
# ---------------------------------------------------------------------------
_t4_exit=0
"$SUT" --input "$ROOT/sym-module/" --output "$ROOT/t4.json" 2>/dev/null \
  || _t4_exit=$?
if [ "$_t4_exit" -eq 2 ]; then
  ok "T4 symlink input trailing slash: exit 2"
else
  no "T4 symlink input trailing slash: expected exit 2, got $_t4_exit"
fi

# ---------------------------------------------------------------------------
# T5: empty module dir (no artifact subdirs) → exit 0, status:complete,
#     artifacts_scanned=0, keys_examined=0 (proves instrument ran, §7)
# ---------------------------------------------------------------------------
_t5_exit=0
"$SUT" --input "$FIXTURES/empty-module" --output "$ROOT/t5.json" 2>/dev/null \
  || _t5_exit=$?
if [ "$_t5_exit" -eq 0 ]; then
  if python3 - "$ROOT/t5.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
assert d['schema'] == 'palette-lexicon.v1', f"bad schema: {d.get('schema')!r}"
assert d['status'] == 'complete', f"bad status: {d.get('status')!r}"
s = d['summary']
assert s['artifacts_scanned'] == 0, \
    f"artifacts_scanned must be 0 for empty module, got {s.get('artifacts_scanned')}"
assert s['keys_examined'] == 0, \
    f"keys_examined must be 0, got {s.get('keys_examined')}"
assert s['palette_entries'] == 0, \
    f"palette_entries must be 0, got {s.get('palette_entries')}"
assert d['artifacts'] == [], f"artifacts must be [] for empty module"
PY
  then
    ok "T5 empty module: exit 0, status:complete, artifacts_scanned=0 (instrument ran)"
  else
    no "T5 empty module: exit 0 but JSON validation failed"
  fi
else
  no "T5 empty module: expected exit 0, got $_t5_exit"
fi

# ---------------------------------------------------------------------------
# T6: valid module with palette, lexicon (duplicates), agents →
#     exact counts and structures emitted
# ---------------------------------------------------------------------------
_t6_exit=0
"$SUT" --input "$FIXTURES/valid-module" --output "$ROOT/t6.json" 2>/dev/null \
  || _t6_exit=$?
if [ "$_t6_exit" -eq 0 ]; then
  if python3 - "$ROOT/t6.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
assert d['schema'] == 'palette-lexicon.v1', f"bad schema: {d.get('schema')!r}"
assert d['status'] == 'complete', f"bad status: {d.get('status')!r}"
s = d['summary']
assert s['artifacts_scanned'] == 1, \
    f"artifacts_scanned must be 1, got {s.get('artifacts_scanned')}"
# Palette: root <p> + 2 child <p> = 3
assert s['palette_entries'] == 3, \
    f"palette_entries must be 3, got {s.get('palette_entries')}"
# Lexicon: 5 key=value lines (comment + blank excluded)
assert s['lexicon_keys'] == 5, \
    f"lexicon_keys must be 5, got {s.get('lexicon_keys')}"
# keys_examined proves the lexicon parser looked
assert s['keys_examined'] == 5, \
    f"keys_examined must be 5, got {s.get('keys_examined')}"
# Duplicate: alarm.displayName appears twice
assert s['duplicate_bare_keys'] == 1, \
    f"duplicate_bare_keys summary must be 1, got {s.get('duplicate_bare_keys')}"
# Agents: 1 type with 1 agent
assert s['agents'] == 1, f"agents must be 1, got {s.get('agents')}"
# Per-artifact data
art = d['artifacts'][0]
assert art['artifact'] == 'alarm-rt', f"artifact name wrong: {art.get('artifact')!r}"
assert art['palette_count'] == 3, f"palette_count must be 3, got {art.get('palette_count')}"
assert art['lexicon_keys'] == 5, f"lexicon_keys must be 5"
assert art['duplicate_bare_keys_count'] == 1, \
    f"duplicate_bare_keys_count must be 1, got {art.get('duplicate_bare_keys_count')}"
# Per-file structure: duplicate_bare_keys is {filename: {key: count}}
assert 'alarm-rt.lexicon' in art['duplicate_bare_keys'], \
    f"alarm-rt.lexicon must be a key in duplicate_bare_keys (per-file structure)"
assert 'alarm.displayName' in art['duplicate_bare_keys']['alarm-rt.lexicon'], \
    f"alarm.displayName must be in alarm-rt.lexicon dups"
assert art['duplicate_bare_keys']['alarm-rt.lexicon']['alarm.displayName'] == 2, \
    f"alarm.displayName must have count 2 in alarm-rt.lexicon"
assert art['agents_count'] == 1, f"agents_count must be 1, got {art.get('agents_count')}"
agent = art['agents'][0]
assert agent['type_name'] == 'AlarmSource', f"agent type_name wrong: {agent!r}"
# Secrets discipline: no lexicon values in output
import json as _json
_full = _json.dumps(d)
assert 'alarm.png' not in _full, "lexicon value 'alarm.png' must not appear in output"
assert 'active' not in _full, "lexicon value 'active' must not appear in output"
PY
  then
    ok "T6 valid module: exact palette/lexicon/agents counts, duplicate key detected, no values"
  else
    no "T6 valid module: JSON validation failed"
  fi
else
  no "T6 valid module: expected exit 0, got $_t6_exit"
fi

# ---------------------------------------------------------------------------
# T7: no-data artifact (extracted/ exists but no palette/lexicon/module.xml)
#     → exit 0, status:complete, all counts 0, artifacts_scanned=1
#     (distinguishes empty-module from artifact-found-but-no-data)
# ---------------------------------------------------------------------------
_t7_exit=0
"$SUT" --input "$FIXTURES/no-data-module" --output "$ROOT/t7.json" 2>/dev/null \
  || _t7_exit=$?
if [ "$_t7_exit" -eq 0 ]; then
  if python3 - "$ROOT/t7.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
assert d['status'] == 'complete', f"bad status: {d.get('status')!r}"
s = d['summary']
assert s['artifacts_scanned'] == 1, \
    f"artifacts_scanned must be 1 (extracted/ dir found), got {s.get('artifacts_scanned')}"
assert s['palette_entries'] == 0, f"palette_entries must be 0"
assert s['lexicon_keys'] == 0, f"lexicon_keys must be 0"
assert s['duplicate_bare_keys'] == 0, f"duplicate_bare_keys must be 0"
assert s['agents'] == 0, f"agents must be 0"
PY
  then
    ok "T7 no-data artifact: artifacts_scanned=1, all counts 0"
  else
    no "T7 no-data artifact: JSON validation failed"
  fi
else
  no "T7 no-data artifact: expected exit 0, got $_t7_exit"
fi

# ---------------------------------------------------------------------------
# T8: duplicate-key aggregation across multiple artifacts
#     dup-keys-module has art-a (foo x2) + art-b (x x2, y x2)
#     Summary: duplicate_bare_keys=3, keys_examined=8
# ---------------------------------------------------------------------------
_t8_exit=0
"$SUT" --input "$FIXTURES/dup-keys-module" --output "$ROOT/t8.json" 2>/dev/null \
  || _t8_exit=$?
if [ "$_t8_exit" -eq 0 ]; then
  if python3 - "$ROOT/t8.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
assert d['status'] == 'complete', f"bad status: {d.get('status')!r}"
s = d['summary']
assert s['artifacts_scanned'] == 2, \
    f"artifacts_scanned must be 2, got {s.get('artifacts_scanned')}"
# art-a: foo x2 = 1 dup; art-b: x x2 + y x2 = 2 dups; total = 3
assert s['duplicate_bare_keys'] == 3, \
    f"duplicate_bare_keys must be 3, got {s.get('duplicate_bare_keys')}"
# art-a: 3 keys; art-b: 5 keys; total = 8
assert s['keys_examined'] == 8, \
    f"keys_examined must be 8, got {s.get('keys_examined')}"
PY
  then
    ok "T8 dup-keys aggregation: 3 dup groups across 2 artifacts, keys_examined=8"
  else
    no "T8 dup-keys aggregation: JSON validation failed"
  fi
else
  no "T8 dup-keys aggregation: expected exit 0, got $_t8_exit"
fi

# ---------------------------------------------------------------------------
# T9: bad palette XML → exit 1, status:failed JSON emitted
# ---------------------------------------------------------------------------
_t9_exit=0
"$SUT" --input "$FIXTURES/bad-palette-module" --output "$ROOT/t9.json" 2>/dev/null \
  || _t9_exit=$?
if [ "$_t9_exit" -eq 1 ]; then
  if python3 - "$ROOT/t9.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
assert d['status'] == 'failed', f"bad palette must be failed, got {d.get('status')!r}"
assert len(d.get('errors', [])) > 0, "errors must be non-empty for bad XML"
PY
  then
    ok "T9 bad palette XML: exit 1, status:failed, errors non-empty"
  else
    no "T9 bad palette XML: exit 1 but JSON validation failed"
  fi
else
  no "T9 bad palette XML: expected exit 1, got $_t9_exit"
fi

# ---------------------------------------------------------------------------
# T10: --output symlink → exit 2, victim file not overwritten
# ---------------------------------------------------------------------------
echo "victim-content" > "$ROOT/victim.txt"
ln -sf "$ROOT/victim.txt" "$ROOT/out_sym.json"
_t10_exit=0
"$SUT" --input "$FIXTURES/valid-module" --output "$ROOT/out_sym.json" \
  2>/dev/null || _t10_exit=$?
_victim_ok=0
[ "$(cat "$ROOT/victim.txt" 2>/dev/null)" = "victim-content" ] && _victim_ok=1
if [ "$_t10_exit" -eq 2 ] && [ "$_victim_ok" -eq 1 ]; then
  ok "T10 output symlink: exit 2, victim not overwritten"
else
  no "T10 output symlink: expected exit 2 + victim intact, got exit $_t10_exit (victim_ok=$_victim_ok)"
fi

# ---------------------------------------------------------------------------
# T11: --output pre-existing file → exit 2 (O_CREAT|O_EXCL guard)
# ---------------------------------------------------------------------------
echo "existing" > "$ROOT/pre_existing.json"
_t11_exit=0
"$SUT" --input "$FIXTURES/valid-module" --output "$ROOT/pre_existing.json" \
  2>/dev/null || _t11_exit=$?
if [ "$_t11_exit" -eq 2 ]; then
  ok "T11 pre-existing output: exit 2 (O_CREAT|O_EXCL refused)"
else
  no "T11 pre-existing output: expected exit 2, got $_t11_exit"
fi

# ---------------------------------------------------------------------------
# T12: keys_examined proves instrument looked — zero is distinct from absent
#      valid-module has lexicon with 5 keys; if keys_examined=0 the parser never ran
# ---------------------------------------------------------------------------
_t12_exit=0
"$SUT" --input "$FIXTURES/valid-module" --output "$ROOT/t12.json" 2>/dev/null \
  || _t12_exit=$?
if [ "$_t12_exit" -eq 0 ]; then
  if python3 - "$ROOT/t12.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
# keys_examined > 0 proves the lexicon parser ran on a non-empty lexicon (§7)
art = d['artifacts'][0]
assert art['keys_examined'] > 0, \
    f"keys_examined must be >0 for a lexicon with real keys; got {art.get('keys_examined')}"
# Also the summary must carry keys_examined
s = d['summary']
assert s['keys_examined'] > 0, \
    f"summary.keys_examined must be >0 for module with real lexicon keys"
PY
  then
    ok "T12 keys_examined proves instrument looked (§7 anti-silent-zero)"
  else
    no "T12 keys_examined: JSON validation failed"
  fi
else
  no "T12 keys_examined: expected exit 0, got $_t12_exit"
fi

# ---------------------------------------------------------------------------
# T13: symlink artifact subdir inside module → skipped (containment guard)
#      Module dir contains a symlink subdir pointing outside root; tool must skip it.
# ---------------------------------------------------------------------------
_t13_mod="$ROOT/containment-module"
mkdir -p "$_t13_mod"
# Create a symlink artifact dir pointing to valid-module (which has extracted/)
ln -sf "$FIXTURES/valid-module" "$_t13_mod/escaped"
_t13_exit=0
"$SUT" --input "$_t13_mod" --output "$ROOT/t13.json" 2>/dev/null \
  || _t13_exit=$?
if [ "$_t13_exit" -eq 0 ]; then
  if python3 - "$ROOT/t13.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
assert d['status'] == 'complete', f"bad status: {d.get('status')!r}"
s = d['summary']
# Symlink subdir must be skipped; no artifacts scanned
assert s['artifacts_scanned'] == 0, \
    f"symlink artifact dir must be skipped; artifacts_scanned={s.get('artifacts_scanned')}"
assert s['palette_entries'] == 0, \
    f"containment breach: palette_entries={s.get('palette_entries')}"
PY
  then
    ok "T13 containment: symlink artifact subdir skipped, no data from outside root"
  else
    no "T13 containment: JSON validation failed"
  fi
else
  no "T13 containment: expected exit 0, got $_t13_exit"
fi

# ---------------------------------------------------------------------------
# T14: palette > old 4 MiB cap (4,194,304 bytes) now parsed correctly with
#      new 16 MiB cap — generated inline in temp dir (not committed to fixtures)
# ---------------------------------------------------------------------------
_T14_MOD="$ROOT/large-palette-module"
python3 - "$_T14_MOD" <<'PY'
import os, sys
out = sys.argv[1]
ext = os.path.join(out, 'big-rt', 'extracted')
os.makedirs(ext, exist_ok=True)
# Each entry ~40 bytes; 130000 entries ≈ 5.2 MB > 4 MiB old cap, < 16 MiB new cap
lines = ['<?xml version="1.0" encoding="UTF-8"?>', '<bajaObjectGraph version="1.0">',
         '<p m="b=baja" t="b:Folder">']
for i in range(130000):
    lines.append(f'<p m="x=y" n="entry{i:06d}" t="t:Type" />')
lines.append('</p></bajaObjectGraph>')
content = '\n'.join(lines) + '\n'
bsz = len(content.encode('utf-8'))
assert bsz > 4 * 1024 * 1024, f"fixture too small: {bsz}"
assert bsz < 16 * 1024 * 1024, f"fixture too large: {bsz}"
with open(os.path.join(ext, 'module.palette'), 'w', encoding='utf-8') as f:
    f.write(content)
PY
_t14_exit=0
"$SUT" --input "$_T14_MOD" --output "$ROOT/t14.json" 2>/dev/null \
  || _t14_exit=$?
if [ "$_t14_exit" -eq 0 ]; then
  if python3 - "$ROOT/t14.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
assert d['status'] == 'complete', f"expected complete, got {d.get('status')!r}"
s = d['summary']
# 130000 child <p> entries + 1 root container = 130001 total elements with attrs
assert s['palette_entries'] > 0, \
    f"palette_entries must be >0 for large palette; got {s.get('palette_entries')}"
assert s['palette_entries'] == 130001, \
    f"palette_entries must be 130001, got {s.get('palette_entries')}"
assert d['errors'] == [], f"no errors expected, got {d.get('errors')}"
PY
  then
    ok "T14 large palette (>4 MiB): parsed correctly with new 16 MiB cap"
  else
    no "T14 large palette: exit 0 but JSON validation failed"
  fi
else
  no "T14 large palette: expected exit 0, got $_t14_exit"
fi

# ---------------------------------------------------------------------------
# T15: multi-lexicon module — per-file dup detection.
#      Fixture: lang-rt/extracted/{baja.lexicon, alarm.lexicon}
#      baja.lexicon: shared.key x1, slot.name x2, slot.desc x1 (4 keys)
#      alarm.lexicon: shared.key x1, alarm.status x1 (2 keys)
#      Expected: slot.name IS a dup (within-file in baja.lexicon)
#               shared.key is NOT a dup (cross-file-only — one in each file)
# ---------------------------------------------------------------------------
_t15_exit=0
"$SUT" --input "$FIXTURES/multi-lexicon-module" --output "$ROOT/t15.json" 2>/dev/null \
  || _t15_exit=$?
if [ "$_t15_exit" -eq 0 ]; then
  if python3 - "$ROOT/t15.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
assert d['status'] == 'complete', f"expected complete, got {d.get('status')!r}"
s = d['summary']
# 4 keys in baja.lexicon + 2 keys in alarm.lexicon = 6 total
assert s['keys_examined'] == 6, \
    f"keys_examined must be 6 (4+2 across 2 lexicon files), got {s.get('keys_examined')}"
# Per-file dups: only slot.name in baja.lexicon (within-file) = 1 dup
assert s['duplicate_bare_keys'] == 1, \
    f"duplicate_bare_keys must be 1 (slot.name within baja.lexicon only), got {s.get('duplicate_bare_keys')}"
art = d['artifacts'][0]
# lexicon_files_seen must reflect both files found
assert art.get('lexicon_files_seen', 'MISSING') == 2, \
    f"lexicon_files_seen must be 2, got {art.get('lexicon_files_seen', 'MISSING')}"
# Per-file structure: baja.lexicon has slot.name dup
dups = art.get('duplicate_bare_keys', {})
assert 'baja.lexicon' in dups, \
    f"baja.lexicon must be a key in duplicate_bare_keys for within-file dup; got keys: {list(dups.keys())}"
assert 'slot.name' in dups.get('baja.lexicon', {}), \
    f"slot.name must be in baja.lexicon dups (within-file); got: {dups.get('baja.lexicon', {})}"
# Negative control: cross-file-only 'shared.key' must NOT be flagged in any file
for fname, fdups in dups.items():
    assert 'shared.key' not in fdups, \
        f"shared.key must not be flagged in {fname!r} (cross-file-only key); got: {fdups}"
PY
  then
    ok "T15 multi-lexicon per-file: slot.name within-file dup detected; shared.key cross-file NOT flagged; lexicon_files_seen=2"
  else
    no "T15 multi-lexicon per-file: JSON validation failed"
  fi
else
  no "T15 multi-lexicon per-file: expected exit 0, got $_t15_exit"
fi

# ---------------------------------------------------------------------------
# T16: presence signals — lexicon_files_seen, palette_present, module_xml_present
#      distinguish absent vs empty vs present (MAJOR 2b / §7 three-state)
# ---------------------------------------------------------------------------
_t16_exit=0
"$SUT" --input "$FIXTURES/no-data-module" --output "$ROOT/t16.json" 2>/dev/null \
  || _t16_exit=$?
if [ "$_t16_exit" -eq 0 ]; then
  if python3 - "$ROOT/t16.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
art = d['artifacts'][0]
# no files in extracted/ → all presence signals absent/false
lex_seen = art.get('lexicon_files_seen', 'MISSING')
assert lex_seen == 0, f"lexicon_files_seen must be 0 for no-data-module, got {lex_seen!r}"
pal_present = art.get('palette_present', 'MISSING')
assert pal_present is False, f"palette_present must be False for no-data-module, got {pal_present!r}"
xml_present = art.get('module_xml_present', 'MISSING')
assert xml_present is False, f"module_xml_present must be False for no-data-module, got {xml_present!r}"
PY
  then
    ok "T16a presence signals: no-data-module → lexicon_files_seen=0, palette_present=false, module_xml_present=false"
  else
    no "T16a presence signals (no-data): JSON validation failed"
  fi
else
  no "T16a presence signals (no-data): expected exit 0, got $_t16_exit"
fi

_t16b_exit=0
"$SUT" --input "$FIXTURES/valid-module" --output "$ROOT/t16b.json" 2>/dev/null \
  || _t16b_exit=$?
if [ "$_t16b_exit" -eq 0 ]; then
  if python3 - "$ROOT/t16b.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
art = d['artifacts'][0]
lex_seen = art.get('lexicon_files_seen', 'MISSING')
assert lex_seen == 1, f"lexicon_files_seen must be 1 for valid-module, got {lex_seen!r}"
pal_present = art.get('palette_present', 'MISSING')
assert pal_present is True, f"palette_present must be True for valid-module, got {pal_present!r}"
xml_present = art.get('module_xml_present', 'MISSING')
assert xml_present is True, f"module_xml_present must be True for valid-module, got {xml_present!r}"
PY
  then
    ok "T16b presence signals: valid-module → lexicon_files_seen=1, palette_present=true, module_xml_present=true"
  else
    no "T16b presence signals (valid): JSON validation failed"
  fi
else
  no "T16b presence signals (valid): expected exit 0, got $_t16b_exit"
fi

# ---------------------------------------------------------------------------
# T17: UTF-8 BOM stripped before lexicon parsing — BOM must not become a key
#      name prefix (﻿) causing first key to be mis-keyed (MAJOR 2c)
# ---------------------------------------------------------------------------
_t17_exit=0
"$SUT" --input "$FIXTURES/bom-lexicon-module" --output "$ROOT/t17.json" 2>/dev/null \
  || _t17_exit=$?
if [ "$_t17_exit" -eq 0 ]; then
  if python3 - "$ROOT/t17.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
assert d['status'] == 'complete', f"expected complete, got {d.get('status')!r}"
s = d['summary']
# bom-rt.lexicon has 3 key=value lines (title, version, title again)
assert s['keys_examined'] == 3, \
    f"keys_examined must be 3, got {s.get('keys_examined')}"
art = d['artifacts'][0]
# With BOM stripping: 'title' appears on line 1 and line 3 -> dup detected.
# Without stripping: '﻿title' and 'title' are different -> no dup.
assert art.get('duplicate_bare_keys_count', 'MISSING') == 1, \
    f"duplicate_bare_keys_count must be 1 ('title' x2 after BOM stripped), " \
    f"got {art.get('duplicate_bare_keys_count', 'MISSING')}"
# Per-file structure: bom-rt.lexicon key maps to its dups dict
_t17_dups = art.get('duplicate_bare_keys', {})
assert 'bom-rt.lexicon' in _t17_dups, \
    f"'bom-rt.lexicon' must be in duplicate_bare_keys; got keys: {list(_t17_dups.keys())}"
assert 'title' in _t17_dups.get('bom-rt.lexicon', {}), \
    f"'title' must be the detected dup in bom-rt.lexicon; got: {_t17_dups.get('bom-rt.lexicon', {})}"
PY
  then
    ok "T17 BOM stripping: 'title' dup detected after BOM stripped (not mis-keyed as BOM+title)"
  else
    no "T17 BOM stripping: JSON validation failed"
  fi
else
  no "T17 BOM stripping: expected exit 0, got $_t17_exit"
fi

# ---------------------------------------------------------------------------
# T18: MemoryError during palette XML parse → caught as typed error, not traceback
#      Monkey-patches ET.fromstring to raise MemoryError and verifies parse_palette
#      returns a typed error string rather than propagating the exception.
# ---------------------------------------------------------------------------
_t18_dir="$(dirname "$SUT_PY")"
_t18_exit=0
python3 - "$_t18_dir" <<'PY' 2>/dev/null && _t18_exit=0 || _t18_exit=1
import sys, os
sys.path.insert(0, sys.argv[1])
import palette_lexicon_agents as pla
# Monkey-patch ET.fromstring in the module's namespace
def _raise_mem(*a, **kw): raise MemoryError('simulated OOM')
pla.ET.fromstring = _raise_mem
entries, err = pla.parse_palette('<bajaObjectGraph/>')
assert err is not None, f'Expected err not None, got: {err!r}'
assert 'memory' in err.lower(), f'Expected "memory" in err, got: {err!r}'
assert entries == [], f'Expected empty entries, got: {entries!r}'
PY
if [ "$_t18_exit" -eq 0 ]; then
  ok "T18 MemoryError in parse_palette: caught as typed error (not uncaught traceback)"
else
  no "T18 MemoryError in parse_palette: not caught correctly (would produce traceback)"
fi

# ---------------------------------------------------------------------------
# T19: same-basename lexicons in different subdirs — both dups counted (Fix 1 / BLOCKER)
#      fr/baja.lexicon has 'a' x2; fr_CA/baja.lexicon has 'b' x2.
#      Before fix: second overwrites first → count=1 (false-negative §7).
#      After fix:  both stored under distinct relpaths → count=2.
# ---------------------------------------------------------------------------
_t19_exit=0
"$SUT" --input "$FIXTURES/same-basename-module" --output "$ROOT/t19.json" 2>/dev/null \
  || _t19_exit=$?
if [ "$_t19_exit" -eq 0 ]; then
  if python3 - "$ROOT/t19.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
assert d['status'] == 'complete', f"status must be complete, got {d.get('status')!r}"
art = d['artifacts'][0]
# Both per-file dup entries must be present under their distinct relpath keys
dups = art.get('duplicate_bare_keys', {})
assert 'fr/baja.lexicon' in dups, \
    f"fr/baja.lexicon must be a relpath key in duplicate_bare_keys; got keys: {list(dups.keys())}"
assert 'fr_CA/baja.lexicon' in dups, \
    f"fr_CA/baja.lexicon must be a relpath key in duplicate_bare_keys; got keys: {list(dups.keys())}"
assert 'a' in dups.get('fr/baja.lexicon', {}), \
    f"'a' must be in fr/baja.lexicon dups; got {dups.get('fr/baja.lexicon')}"
assert 'b' in dups.get('fr_CA/baja.lexicon', {}), \
    f"'b' must be in fr_CA/baja.lexicon dups; got {dups.get('fr_CA/baja.lexicon')}"
# duplicate_bare_keys_count must reflect BOTH files
cnt = art.get('duplicate_bare_keys_count', 'MISSING')
assert cnt == 2, \
    f"duplicate_bare_keys_count must be 2 (one dup per file, two files); got {cnt!r}"
PY
  then
    ok "T19 same-basename relpaths: fr/baja.lexicon and fr_CA/baja.lexicon both counted, count=2"
  else
    no "T19 same-basename relpaths: JSON validation failed"
  fi
else
  no "T19 same-basename relpaths: expected exit 0, got $_t19_exit"
fi

# ---------------------------------------------------------------------------
# T20a: nested-lexicon recursion — FIRST/MIDDLE/LAST depth all found (Fix 2 / MAJOR)
#        extracted/top.lexicon (FIRST), extracted/sub/mid.lexicon (MIDDLE),
#        extracted/sub/deep/bottom.lexicon (LAST)
#        lexicon_files_seen=3, keys_examined=3
# ---------------------------------------------------------------------------
_t20a_exit=0
"$SUT" --input "$FIXTURES/nested-lexicon-module" --output "$ROOT/t20a.json" 2>/dev/null \
  || _t20a_exit=$?
if [ "$_t20a_exit" -eq 0 ]; then
  if python3 - "$ROOT/t20a.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
assert d['status'] == 'complete', f"status must be complete, got {d.get('status')!r}"
art = d['artifacts'][0]
lfs = art.get('lexicon_files_seen', 'MISSING')
assert lfs == 3, f"lexicon_files_seen must be 3 (top+mid+bottom), got {lfs!r}"
kex = art.get('keys_examined', 'MISSING')
assert kex == 3, f"keys_examined must be 3 (one key per file), got {kex!r}"
PY
  then
    ok "T20a nested recursion: lexicon_files_seen=3 (FIRST+MIDDLE+LAST depth all found), keys_examined=3"
  else
    no "T20a nested recursion: JSON validation failed"
  fi
else
  no "T20a nested recursion: expected exit 0, got $_t20a_exit"
fi

# ---------------------------------------------------------------------------
# T20b: symlink .lexicon inside extracted/ is NOT counted (S_ISLNK guard, Fix 2 / MAJOR)
#        Module has 1 real .lexicon + 1 symlink .lexicon.
#        lexicon_files_seen must be 1 (symlink excluded).
# ---------------------------------------------------------------------------
_t20b_exit=0
"$SUT" --input "$_T20b_MOD" --output "$ROOT/t20b.json" 2>/dev/null \
  || _t20b_exit=$?
if [ "$_t20b_exit" -eq 0 ]; then
  if python3 - "$ROOT/t20b.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
assert d['status'] == 'complete', f"status must be complete, got {d.get('status')!r}"
art = d['artifacts'][0]
lfs = art.get('lexicon_files_seen', 'MISSING')
assert lfs == 1, f"lexicon_files_seen must be 1 (symlink .lexicon excluded), got {lfs!r}"
PY
  then
    ok "T20b symlink excluded: lexicon_files_seen=1 (S_ISLNK guard rejects symlink .lexicon)"
  else
    no "T20b symlink excluded: JSON validation failed"
  fi
else
  no "T20b symlink excluded: expected exit 0, got $_t20b_exit"
fi

# ---------------------------------------------------------------------------
# T21: unreadable nested subdir → errors non-empty, status:failed (Fix 3 / MINOR)
#      extracted/secret-dir (chmod 000) triggers onerror callback.
#      Skip when running as root (chmod 000 ineffective).
# ---------------------------------------------------------------------------
if [ "$_IS_ROOT" -eq 1 ]; then
  ok "T21 unreadable-subdir: SKIP (running as root — chmod 000 ineffective)"
else
  _t21_exit=0
  "$SUT" --input "$_T21_MOD" --output "$ROOT/t21.json" 2>/dev/null \
    || _t21_exit=$?
  # Restore permissions immediately so cleanup can delete the dir
  chmod 755 "$_T21_MOD/art-x/extracted/secret-dir" 2>/dev/null || true
  if [ "$_t21_exit" -ne 2 ]; then
    if python3 - "$ROOT/t21.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
# Unreadable subdir must surface in errors (status:failed) — §7 absent-not-traversable
errs = d.get('errors', [])
assert len(errs) > 0, f"errors must be non-empty for module with unreadable subdir; got {errs!r}"
# The readable lexicon must still be processed
s = d['summary']
assert s.get('keys_examined', 0) > 0, \
    f"keys_examined must be >0 (normal.lexicon is readable); got {s.get('keys_examined')}"
PY
    then
      ok "T21 unreadable-subdir: errors non-empty (§7 absent-not-traversable distinct from no-match)"
    else
      no "T21 unreadable-subdir: exit=$_t21_exit but JSON validation failed"
    fi
  else
    no "T21 unreadable-subdir: exit 2 unexpected (expected 0 or 1 with errors in JSON)"
  fi
fi

# ---------------------------------------------------------------------------
# T22: unreadable .lexicon file → errors non-empty (Fix 4 / MINOR)
#      extracted/locked.lexicon (chmod 000) fails _read_file_bounded.
#      Must emit an error (not silently skip). Skip when running as root.
# ---------------------------------------------------------------------------
if [ "$_IS_ROOT" -eq 1 ]; then
  ok "T22 unreadable-lexicon-file: SKIP (running as root — chmod 000 ineffective)"
else
  _t22_exit=0
  "$SUT" --input "$_T22_MOD" --output "$ROOT/t22.json" 2>/dev/null \
    || _t22_exit=$?
  # Restore permissions immediately
  chmod 644 "$_T22_MOD/art-y/extracted/locked.lexicon" 2>/dev/null || true
  if [ "$_t22_exit" -ne 2 ]; then
    if python3 - "$ROOT/t22.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
# Unreadable lexicon must surface in errors — §7 absent vs unreadable distinct
errs = d.get('errors', [])
assert len(errs) > 0, \
    f"errors must be non-empty for module with unreadable lexicon file; got {errs!r}"
# The readable lexicon must still be processed
art = d['artifacts'][0]
assert art.get('keys_examined', 0) > 0, \
    f"keys_examined must be >0 (readable.lexicon has keys); got {art.get('keys_examined')}"
PY
    then
      ok "T22 unreadable-lexicon-file: errors non-empty (unreadable distinct from empty, §7)"
    else
      no "T22 unreadable-lexicon-file: exit=$_t22_exit but JSON validation failed"
    fi
  else
    no "T22 unreadable-lexicon-file: exit 2 unexpected"
  fi
fi

# ---------------------------------------------------------------------------
# T23: no unmeasured numeric claim in limitations (Fix 5 / MINOR)
#      limitations must NOT contain '~22x' or '14.7 MiB' — §7 report-only-measured.
# ---------------------------------------------------------------------------
_t23_exit=0
"$SUT" --input "$FIXTURES/valid-module" --output "$ROOT/t23.json" 2>/dev/null \
  || _t23_exit=$?
if [ "$_t23_exit" -eq 0 ]; then
  if python3 - "$ROOT/t23.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
lims = ' '.join(d.get('limitations', []))
assert '~22x' not in lims, \
    f"limitations must not contain unmeasured '~22x' amplification claim; got: {lims!r}"
assert '14.7 MiB' not in lims, \
    f"limitations must not contain unmeasured '14.7 MiB' size claim; got: {lims!r}"
PY
  then
    ok "T23 no unmeasured numeric claims in limitations (§7 report-only-measured)"
  else
    no "T23 no unmeasured numeric claims: JSON validation failed"
  fi
else
  no "T23 no unmeasured numeric claims: expected exit 0, got $_t23_exit"
fi

# ---------------------------------------------------------------------------
# Summary (non-teeth path)
# ---------------------------------------------------------------------------
if [ "${1:-}" != "--prove-teeth" ]; then
  echo "== $pass passed · $fail failed =="; [ "$fail" -eq 0 ]
  exit $?
fi

# ---------------------------------------------------------------------------
echo "-- teeth: palette-lexicon-agents mutation controls --"
# ---------------------------------------------------------------------------
MUT_PASS=0; MUT_FAIL=0
mut_ok(){ echo "  PASS(mut)  $1"; MUT_PASS=$((MUT_PASS+1)); }
mut_no(){ echo "  FAIL(mut)  $1"; MUT_FAIL=$((MUT_FAIL+1)); }

SUT_DIR="$(cd "$(dirname "$SUT")" && pwd)"
ORIG_PY="$SUT_DIR/palette_lexicon_agents.py"
if [ ! -f "$ORIG_PY" ]; then
  echo "  FAIL(mut)  palette_lexicon_agents.py not found: $ORIG_PY"
  echo "== $pass passed · $fail failed =="
  exit 1
fi


# --- mutation-control helpers (kit issues #943, #1299) ---------------------------------------------
# Every mutant is a COPY of the SUT directory under a mktemp dir (outside the live tree) whose
# palette_lexicon_agents.py is built FROM the original by lib/mutant.sh (MUTANT_SYNTAX=none: the
# bash syntax check does not apply to Python; py_compile below replaces it). lib/mutant.sh REFUSES an
# empty, byte-identical or live-tree mutant. Each tooth then asserts the EXACT GOOD verdict on the
# original AND the EXACT BAD verdict on the mutant: a mutant that merely crashes (no JSON, odd exit)
# is NOT teeth — the old `!= <good value>` verdicts counted a crash as "DETECTED".
# shellcheck source=lib/mutant.sh
. "$HERE/lib/mutant.sh"
typeset -f mutant_sed >/dev/null 2>&1 && typeset -f mutant_verify >/dev/null 2>&1 \
  || { echo "FATAL: lib/mutant.sh did not define mutant_sed/mutant_verify ($HERE/lib/mutant.sh)" >&2; exit 2; }
# TODO(#1299): replace with shared lib/mutant.sh helpers once promoted
MUTDIR=""
trap '
  chmod 755 "$ROOT/unreadable-subdir-module/art-x/extracted/secret-dir" 2>/dev/null || true
  chmod 644 "$ROOT/unreadable-lexicon-module/art-y/extracted/locked.lexicon" 2>/dev/null || true
  rm -rf "$ROOT" ${MUTDIR:+"$MUTDIR"}
' EXIT

# mk_mutant LABEL EXPR...  build $MUTDIR/palette_lexicon_agents.py from $ORIG_PY, one sed stage per EXPR.
# Each stage must change the original ON ITS OWN. Returns 1 (after recording a FAIL) when refused.
mk_mutant() {
  local label="$1" e rc err; shift
  local -a args=()
  MUTDIR="$(mktemp -d)"; cp -a "$SUT_DIR/." "$MUTDIR/"
  for e in "$@"; do
    if sed -e "$e" "$ORIG_PY" | cmp -s - "$ORIG_PY"; then
      mut_no "$label: sed stage matches nothing in the original (silent no-op) :: [${e:0:70}]"; rm -rf "$MUTDIR"; return 1
    fi
    args+=(-e "$e")
  done
  err="$(MUTANT_SYNTAX=none mutant_sed "$ORIG_PY" "$MUTDIR/palette_lexicon_agents.py" "${args[@]}" 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ]; then mut_no "$label: mutant refused by lib/mutant.sh (rc=$rc) :: $err"; rm -rf "$MUTDIR"; return 1; fi
  if ! python3 -m py_compile "$MUTDIR/palette_lexicon_agents.py" 2>/dev/null; then
    mut_no "$label: mutant failed py_compile"; rm -rf "$MUTDIR"; return 1
  fi
}

# art_field JSON FIELD  print one value of the output document. FIELD forms: <artifact field> ·
# top:<key> · len:top:<key> · xfile:<bare key flagged as duplicated in any file> · lim:<substring of limitations>.
art_field() {
  python3 - "$1" "$2" 2>/dev/null <<'PY' || echo "pyerr"
import json, sys
d = json.load(open(sys.argv[1])); f = sys.argv[2]
art = d['artifacts'][0] if d.get('artifacts') else {}
if f.startswith('top:'): print(d.get(f[4:], 'absent'))
elif f.startswith('len:top:'): print(len(d.get(f[8:], [])))
elif f.startswith('xfile:'):
    dups = art.get('duplicate_bare_keys', {})
    print('yes' if any(f[6:] in fd for fd in dups.values() if isinstance(fd, dict)) else 'no')
elif f.startswith('lim:'): print('yes' if f[4:] in ' '.join(d.get('limitations', [])) else 'no')
else: print(art.get(f, 'absent'))
PY
}

# art_run PY INPUT OUT FIELD  run PY on INPUT, set RA_RC (exit code) and RA_VAL (FIELD, or 'nojson').
art_run() {
  rm -f "$3"; RA_RC=0
  python3 "$1" --input "$2" --output "$3" 2>/dev/null || RA_RC=$?
  if [ -f "$3" ]; then RA_VAL="$(art_field "$3" "$4")"; else RA_VAL="nojson"; fi
}

# mut_verdict LABEL G_RC G_VAL WANT_G_RC WANT_G_VAL B_RC B_VAL WANT_B_RC WANT_B_VAL  exact GOOD + exact BAD.
mut_verdict() {
  local label="$1"
  if [ "$2" = "$4" ] && [ "$3" = "$5" ] && [ "$6" = "$8" ] && [ "$7" = "$9" ]; then
    mut_ok "$label: original rc=$2 value='$3' → mutant rc=$6 value='$7' — DETECTED"
  else
    mut_no "$label — THEATER: original rc=$2 value='$3' (want rc=$4 '$5'); mutant rc=$6 value='$7' (want rc=$8 '$9')"
  fi
}

# mut_field_tooth LABEL INPUT FIELD GOOD_VAL BAD_VAL EXPR...  exact exit code (MF_GRC/MF_BRC, default 0) and exact value on both runs.
mut_field_tooth() {
  local label="$1" input="$2" field="$3" good="$4" bad="$5" grc gval; shift 5
  mk_mutant "$label" "$@" || return 1
  art_run "$ORIG_PY" "$input" "$ROOT/good.json" "$field"; grc=$RA_RC; gval=$RA_VAL
  art_run "$MUTDIR/palette_lexicon_agents.py" "$input" "$ROOT/bad.json" "$field"
  mut_verdict "$label" "$grc" "$gval" "${MF_GRC:-0}" "$good" "$RA_RC" "$RA_VAL" "${MF_BRC:-0}" "$bad"
  rm -rf "$MUTDIR"
}

# --- M1: S_ISLNK → S_ISBLK so a symlink INPUT is no longer rejected (original exit 2 + no document).
if mk_mutant "M1 symlink guard" 's/if _stat\.S_ISLNK(lstat_in\.st_mode):/if _stat.S_ISBLK(lstat_in.st_mode):  # MUTANT-M1/'; then
  art_run "$ORIG_PY" "$ROOT/sym-module" "$ROOT/m1g.json" top:status; _m1g_rc=$RA_RC; _m1g_val=$RA_VAL
  art_run "$MUTDIR/palette_lexicon_agents.py" "$ROOT/sym-module" "$ROOT/m1.json" top:status
  mut_verdict "M1 symlink guard" "$_m1g_rc" "$_m1g_val" 2 nojson "$RA_RC" "$RA_VAL" 0 complete
  rm -rf "$MUTDIR"
fi

# --- M2 dup dict always empty · M3 keys_examined never counted · M4 entries never appended
mut_field_tooth "M2 dup detection" "$FIXTURES/valid-module" duplicate_bare_keys_count 1 0 \
  's/dups = {k: v for k, v in counts\.items() if v > 1}/dups = {}  # MUTANT-M2/'
mut_field_tooth "M3 keys_examined counter" "$FIXTURES/valid-module" keys_examined 5 0 \
  's/        keys_examined += 1$/        pass  # MUTANT-M3/'
mut_field_tooth "M4 palette accumulation" "$FIXTURES/valid-module" palette_count 3 0 \
  's/        entries\.append(entry)$/        pass  # MUTANT-M4/'
# --- M5 single <artifact>.lexicon discovery · M6 presence signal zeroed · M7 BOM stripping reverted
MF_BRC=1 mut_field_tooth "M5 multi-lexicon" "$FIXTURES/multi-lexicon-module" lexicon_files_seen 2 1 \
  's/    lexicon_files = _find_lexicon_files(ext_dir, module_root, onerror=_walk_onerror)/    lexicon_files = [os.path.join(ext_dir, artifact_name + ".lexicon")]  # MUTANT-M5/'
mut_field_tooth "M6 presence signals" "$FIXTURES/valid-module" lexicon_files_seen 1 0 \
  's/    lexicon_files_seen = len(lexicon_files)/    lexicon_files_seen = 0  # MUTANT-M6/'
mut_field_tooth "M7 BOM stripping" "$FIXTURES/bom-lexicon-module" duplicate_bare_keys_count 1 0 \
  's/text = raw\.decode("utf-8-sig", errors="replace")/text = raw.decode("utf-8", errors="replace")  # MUTANT-M7/'

# --- M8: palette cap reverted to 4 MiB: the large palette (original: complete, exit 0) is truncated again.
if mk_mutant "M8 palette cap" 's/_MAX_PALETTE_BYTES    = 16 \* 1024 \* 1024/_MAX_PALETTE_BYTES    = 4 * 1024 * 1024  # MUTANT-M8/'; then
  art_run "$ORIG_PY" "$_T14_MOD" "$ROOT/m8g.json" top:status; _m8g_rc=$RA_RC; _m8g_val=$RA_VAL
  art_run "$MUTDIR/palette_lexicon_agents.py" "$_T14_MOD" "$ROOT/m8.json" top:status
  mut_verdict "M8 palette cap" "$_m8g_rc" "$_m8g_val" 0 complete "$RA_RC" "$RA_VAL" 1 failed
  rm -rf "$MUTDIR"
fi

# --- M9: per-file dup detection reverted to concatenation: the cross-file key 'shared.key' is wrongly flagged.
mut_field_tooth "M9 per-file dup" "$FIXTURES/multi-lexicon-module" xfile:shared.key no yes \
  's/    per_file_dups = {}/    per_file_dups = {}\n    _m9_concat = ""  # MUTANT-M9/' \
  's/        text = raw\.decode("utf-8-sig", errors="replace")/        text = raw.decode("utf-8-sig", errors="replace"); _m9_concat += text + "\\n"/' \
  's/        fkex, fdups, ferr = parse_lexicon(text)$/        fkex, fdups, ferr = parse_lexicon(_m9_concat)  # MUTANT-M9/'

# --- M10 relpath → basename · M11 recursive walk flattened · M12 symlink/regular-file guard dropped
mut_field_tooth "M10 relpath→basename" "$FIXTURES/same-basename-module" duplicate_bare_keys_count 2 1 \
  's/lex_relpath = os\.path\.relpath(lex_path, ext_dir)/lex_relpath = os.path.basename(lex_path)  # MUTANT-M10/'
mut_field_tooth "M11 flat walk" "$FIXTURES/nested-lexicon-module" lexicon_files_seen 3 1 \
  's/        dirnames\.sort()  # deterministic traversal order/        dirnames[:] = []  # MUTANT-M11/'
MF_BRC=1 mut_field_tooth "M12 symlink guard dropped" "$_T20b_MOD" lexicon_files_seen 1 2 \
  's/            if _stat\.S_ISLNK(lstat\.st_mode) or not _stat\.S_ISREG(lstat\.st_mode):/            if False:  # MUTANT-M12/'

# --- M13: onerror=None: the unreadable subdir (original: 1 error recorded) is silently dropped (0 errors).
if [ "$_IS_ROOT" -eq 1 ]; then
  mut_ok "M13 onerror=None: SKIP (running as root)"
elif mk_mutant "M13 onerror=None" 's/lexicon_files = _find_lexicon_files(ext_dir, module_root, onerror=_walk_onerror)/lexicon_files = _find_lexicon_files(ext_dir, module_root, onerror=None)  # MUTANT-M13/'; then
  # Recreate the chmod-000 dir (it was restored after T21)
  mkdir -p "$_T21_MOD/art-x/extracted/secret-dir" 2>/dev/null || true
  printf 'hidden=secret\n' > "$_T21_MOD/art-x/extracted/secret-dir/hidden.lexicon" 2>/dev/null || true
  chmod 000 "$_T21_MOD/art-x/extracted/secret-dir" 2>/dev/null || true
  art_run "$ORIG_PY" "$_T21_MOD" "$ROOT/m13g.json" len:top:errors; _m13g_rc=$RA_RC; _m13g_val=$RA_VAL
  art_run "$MUTDIR/palette_lexicon_agents.py" "$_T21_MOD" "$ROOT/m13.json" len:top:errors
  chmod 755 "$_T21_MOD/art-x/extracted/secret-dir" 2>/dev/null || true
  mut_verdict "M13 onerror=None" "$_m13g_rc" "$_m13g_val" 1 1 "$RA_RC" "$RA_VAL" 0 0
  rm -rf "$MUTDIR"
fi

# --- M14: the unreadable-file error append deleted: the chmod-000 lexicon (original: 1 error) is silently skipped.
if [ "$_IS_ROOT" -eq 1 ]; then
  mut_ok "M14 unreadable-file error removed: SKIP (running as root)"
elif mk_mutant "M14 unreadable-file error" '/: lexicon file unreadable/d'; then
  # Recreate the chmod-000 file (restored after T22)
  printf 'key2=v2\n' > "$_T22_MOD/art-y/extracted/locked.lexicon" 2>/dev/null || true
  chmod 000 "$_T22_MOD/art-y/extracted/locked.lexicon" 2>/dev/null || true
  art_run "$ORIG_PY" "$_T22_MOD" "$ROOT/m14g.json" len:top:errors; _m14g_rc=$RA_RC; _m14g_val=$RA_VAL
  art_run "$MUTDIR/palette_lexicon_agents.py" "$_T22_MOD" "$ROOT/m14.json" len:top:errors
  chmod 644 "$_T22_MOD/art-y/extracted/locked.lexicon" 2>/dev/null || true
  mut_verdict "M14 unreadable-file error" "$_m14g_rc" "$_m14g_val" 1 1 "$RA_RC" "$RA_VAL" 0 0
  rm -rf "$MUTDIR"
fi

# --- M15: the unmeasured '~22x' claim is reintroduced into limitations (original: absent).
mut_field_tooth "M15 ~22x reintroduced" "$FIXTURES/valid-module" lim:~22x no yes \
  's/a pathological XML tree can still exceed available memory during parse/ET amplifies ~22x — a ~14.7 MiB palette can exhaust memory  # MUTANT-M15/'

pass=$((pass + MUT_PASS))
fail=$((fail + MUT_FAIL))
echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
