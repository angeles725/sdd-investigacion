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

# --- M1: Remove symlink guard on input ---
# Mutation: S_ISLNK → S_ISBLK so symlink input is not rejected.
# Expected: T2 symlink input now exits 0 instead of 2 → DETECTED.
MUTDIR="$(mktemp -d)"
cp -a "$SUT_DIR/." "$MUTDIR/"
sed -i 's/if _stat\.S_ISLNK(lstat_in\.st_mode):/if _stat.S_ISBLK(lstat_in.st_mode):  # MUTANT-M1/' \
  "$MUTDIR/palette_lexicon_agents.py"
if ! python3 -m py_compile "$MUTDIR/palette_lexicon_agents.py" 2>/dev/null; then
  mut_no "M1 symlink guard: mutant failed py_compile"
elif cmp -s "$ORIG_PY" "$MUTDIR/palette_lexicon_agents.py"; then
  mut_no "M1 symlink guard: sed had no effect (pattern not found)"
else
  _m1_exit=0
  python3 "$MUTDIR/palette_lexicon_agents.py" \
    --input "$ROOT/sym-module" --output "$ROOT/m1.json" 2>/dev/null || _m1_exit=$?
  if [ "$_m1_exit" -ne 2 ]; then
    mut_ok "M1 symlink guard removal detected (exit $_m1_exit, not 2)"
  else
    mut_no "M1 symlink guard: mutation NOT detected (still exits 2)"
  fi
fi
rm -rf "$MUTDIR"

# --- M2: Break duplicate key detection (dup dict always empty) ---
# Mutation: dups = {k: v ...} → dups = {}
# Expected: T6 sees duplicate_bare_keys_count=0 even though alarm.displayName appears twice → DETECTED.
MUTDIR="$(mktemp -d)"
cp -a "$SUT_DIR/." "$MUTDIR/"
sed -i 's/dups = {k: v for k, v in counts\.items() if v > 1}/dups = {}  # MUTANT-M2/' \
  "$MUTDIR/palette_lexicon_agents.py"
if ! python3 -m py_compile "$MUTDIR/palette_lexicon_agents.py" 2>/dev/null; then
  mut_no "M2 dup detection: mutant failed py_compile"
elif cmp -s "$ORIG_PY" "$MUTDIR/palette_lexicon_agents.py"; then
  mut_no "M2 dup detection: sed had no effect (pattern not found)"
else
  _m2_exit=0
  python3 "$MUTDIR/palette_lexicon_agents.py" \
    --input "$FIXTURES/valid-module" --output "$ROOT/m2.json" 2>/dev/null || _m2_exit=$?
  _m2_dup=""
  if [ -f "$ROOT/m2.json" ]; then
    _m2_dup="$(python3 -c \
      "import json; d=json.load(open('$ROOT/m2.json')); art=d['artifacts'][0]; print(art.get('duplicate_bare_keys_count','absent'))" \
      2>/dev/null || echo "")"
  fi
  if [ "$_m2_dup" != "1" ]; then
    mut_ok "M2 dup detection broken: duplicate_bare_keys_count='$_m2_dup' not 1 — DETECTED"
  else
    mut_no "M2 dup detection: mutation NOT detected (still 1)"
  fi
fi
rm -rf "$MUTDIR"

# --- M3: Break keys_examined counter (always 0) ---
# Mutation: keys_examined += 1 → pass  # MUTANT-M3
# Expected: T12 sees keys_examined=0 even for a lexicon with real keys → DETECTED.
MUTDIR="$(mktemp -d)"
cp -a "$SUT_DIR/." "$MUTDIR/"
sed -i 's/        keys_examined += 1$/        pass  # MUTANT-M3/' \
  "$MUTDIR/palette_lexicon_agents.py"
if ! python3 -m py_compile "$MUTDIR/palette_lexicon_agents.py" 2>/dev/null; then
  mut_no "M3 keys_examined counter: mutant failed py_compile"
elif cmp -s "$ORIG_PY" "$MUTDIR/palette_lexicon_agents.py"; then
  mut_no "M3 keys_examined counter: sed had no effect (pattern not found)"
else
  _m3_exit=0
  python3 "$MUTDIR/palette_lexicon_agents.py" \
    --input "$FIXTURES/valid-module" --output "$ROOT/m3.json" 2>/dev/null || _m3_exit=$?
  _m3_kex=""
  if [ -f "$ROOT/m3.json" ]; then
    _m3_kex="$(python3 -c \
      "import json; d=json.load(open('$ROOT/m3.json')); art=d['artifacts'][0]; print(art.get('keys_examined','absent'))" \
      2>/dev/null || echo "")"
  fi
  if [ "$_m3_kex" = "0" ] || [ "$_m3_kex" = "0.0" ]; then
    mut_ok "M3 keys_examined broken: keys_examined='$_m3_kex' (zero) — DETECTED"
  else
    mut_no "M3 keys_examined: mutation NOT detected (keys_examined=$_m3_kex)"
  fi
fi
rm -rf "$MUTDIR"

# --- M4: Break palette entry accumulation (entries never appended) ---
# Mutation: entries.append(entry) → pass  # MUTANT-M4
# Expected: T6 sees palette_count=0 for a module with 3 palette entries → DETECTED.
MUTDIR="$(mktemp -d)"
cp -a "$SUT_DIR/." "$MUTDIR/"
sed -i 's/        entries\.append(entry)$/        pass  # MUTANT-M4/' \
  "$MUTDIR/palette_lexicon_agents.py"
if ! python3 -m py_compile "$MUTDIR/palette_lexicon_agents.py" 2>/dev/null; then
  mut_no "M4 palette accumulation: mutant failed py_compile"
elif cmp -s "$ORIG_PY" "$MUTDIR/palette_lexicon_agents.py"; then
  mut_no "M4 palette accumulation: sed had no effect (pattern not found)"
else
  _m4_exit=0
  python3 "$MUTDIR/palette_lexicon_agents.py" \
    --input "$FIXTURES/valid-module" --output "$ROOT/m4.json" 2>/dev/null || _m4_exit=$?
  _m4_pal=""
  if [ -f "$ROOT/m4.json" ]; then
    _m4_pal="$(python3 -c \
      "import json; d=json.load(open('$ROOT/m4.json')); art=d['artifacts'][0]; print(art.get('palette_count','absent'))" \
      2>/dev/null || echo "")"
  fi
  if [ "$_m4_pal" != "3" ]; then
    mut_ok "M4 palette accumulation broken: palette_count='$_m4_pal' not 3 — DETECTED"
  else
    mut_no "M4 palette accumulation: mutation NOT detected (still 3)"
  fi
fi
rm -rf "$MUTDIR"

# --- M5: Break multi-lexicon discovery (revert to single <artifact>.lexicon) ---
# Mutation: _find_lexicon_files(...) → single-file list  (MUTANT-M5)
# Expected: T15 sees lexicon_files_seen != 2 (only one file returned) → DETECTED.
MUTDIR="$(mktemp -d)"
cp -a "$SUT_DIR/." "$MUTDIR/"
sed -i 's/    lexicon_files = _find_lexicon_files(ext_dir, module_root, onerror=_walk_onerror)/    lexicon_files = [os.path.join(ext_dir, artifact_name + ".lexicon")]  # MUTANT-M5/' \
  "$MUTDIR/palette_lexicon_agents.py"
if ! python3 -m py_compile "$MUTDIR/palette_lexicon_agents.py" 2>/dev/null; then
  mut_no "M5 multi-lexicon: mutant failed py_compile"
elif cmp -s "$ORIG_PY" "$MUTDIR/palette_lexicon_agents.py"; then
  mut_no "M5 multi-lexicon: sed had no effect (pattern not found)"
else
  _m5_exit=0
  python3 "$MUTDIR/palette_lexicon_agents.py" \
    --input "$FIXTURES/multi-lexicon-module" --output "$ROOT/m5.json" 2>/dev/null || _m5_exit=$?
  _m5_lex_seen=""
  if [ -f "$ROOT/m5.json" ]; then
    _m5_lex_seen="$(python3 -c \
      "import json; d=json.load(open('$ROOT/m5.json')); art=d['artifacts'][0]; print(art.get('lexicon_files_seen','absent'))" \
      2>/dev/null || echo "")"
  fi
  if [ "$_m5_lex_seen" != "2" ]; then
    mut_ok "M5 multi-lexicon broken: lexicon_files_seen='$_m5_lex_seen' not 2 — DETECTED"
  else
    mut_no "M5 multi-lexicon: mutation NOT detected (still 2)"
  fi
fi
rm -rf "$MUTDIR"

# --- M6: Break presence signals (lexicon_files_seen always 0) ---
# Mutation: lexicon_files_seen = len(lexicon_files) → lexicon_files_seen = 0  (MUTANT-M6)
# Expected: T16b sees lexicon_files_seen=0 for valid-module (should be 1) → DETECTED.
MUTDIR="$(mktemp -d)"
cp -a "$SUT_DIR/." "$MUTDIR/"
sed -i 's/    lexicon_files_seen = len(lexicon_files)/    lexicon_files_seen = 0  # MUTANT-M6/' \
  "$MUTDIR/palette_lexicon_agents.py"
if ! python3 -m py_compile "$MUTDIR/palette_lexicon_agents.py" 2>/dev/null; then
  mut_no "M6 presence signals: mutant failed py_compile"
elif cmp -s "$ORIG_PY" "$MUTDIR/palette_lexicon_agents.py"; then
  mut_no "M6 presence signals: sed had no effect (pattern not found)"
else
  _m6_exit=0
  python3 "$MUTDIR/palette_lexicon_agents.py" \
    --input "$FIXTURES/valid-module" --output "$ROOT/m6.json" 2>/dev/null || _m6_exit=$?
  _m6_lfs=""
  if [ -f "$ROOT/m6.json" ]; then
    _m6_lfs="$(python3 -c \
      "import json; d=json.load(open('$ROOT/m6.json')); art=d['artifacts'][0]; print(art.get('lexicon_files_seen','absent'))" \
      2>/dev/null || echo "")"
  fi
  if [ "$_m6_lfs" != "1" ]; then
    mut_ok "M6 presence signals broken: lexicon_files_seen='$_m6_lfs' not 1 — DETECTED"
  else
    mut_no "M6 presence signals: mutation NOT detected (still 1)"
  fi
fi
rm -rf "$MUTDIR"

# --- M7: Break BOM stripping (revert to plain utf-8 decode) ---
# Mutation: decode("utf-8-sig",...) → decode("utf-8",...)  (MUTANT-M7)
# Expected: T17 sees BOM residue in key names (﻿ prefix) → DETECTED.
MUTDIR="$(mktemp -d)"
cp -a "$SUT_DIR/." "$MUTDIR/"
sed -i 's/text = raw\.decode("utf-8-sig", errors="replace")/text = raw.decode("utf-8", errors="replace")  # MUTANT-M7/' \
  "$MUTDIR/palette_lexicon_agents.py"
if ! python3 -m py_compile "$MUTDIR/palette_lexicon_agents.py" 2>/dev/null; then
  mut_no "M7 BOM stripping: mutant failed py_compile"
elif cmp -s "$ORIG_PY" "$MUTDIR/palette_lexicon_agents.py"; then
  mut_no "M7 BOM stripping: sed had no effect (pattern not found)"
else
  _m7_exit=0
  python3 "$MUTDIR/palette_lexicon_agents.py" \
    --input "$FIXTURES/bom-lexicon-module" --output "$ROOT/m7.json" 2>/dev/null || _m7_exit=$?
  _m7_dup=""
  if [ -f "$ROOT/m7.json" ]; then
    _m7_dup="$(python3 -c \
      "import json; d=json.load(open('$ROOT/m7.json')); art=d['artifacts'][0]; print(art.get('duplicate_bare_keys_count','absent'))" \
      2>/dev/null || echo "")"
  fi
  # Without BOM stripping: '﻿title' and 'title' are different keys -> no dup (count 0)
  # With BOM stripping (correct): both become 'title' -> dup detected (count 1)
  if [ "$_m7_dup" != "1" ]; then
    mut_ok "M7 BOM stripping broken: duplicate_bare_keys_count='$_m7_dup' not 1 — DETECTED"
  else
    mut_no "M7 BOM stripping: mutation NOT detected (duplicate_bare_keys_count still 1)"
  fi
fi
rm -rf "$MUTDIR"

# --- M8: Revert palette cap to old 4 MiB (large palette truncated again) ---
# Mutation: _MAX_PALETTE_BYTES = 16 * 1024 * 1024 → 4 * 1024 * 1024  (MUTANT-M8)
# Expected: T14 large palette exits 1 (parse error from truncated XML) → DETECTED.
MUTDIR="$(mktemp -d)"
cp -a "$SUT_DIR/." "$MUTDIR/"
sed -i 's/_MAX_PALETTE_BYTES    = 16 \* 1024 \* 1024/_MAX_PALETTE_BYTES    = 4 * 1024 * 1024  # MUTANT-M8/' \
  "$MUTDIR/palette_lexicon_agents.py"
if ! python3 -m py_compile "$MUTDIR/palette_lexicon_agents.py" 2>/dev/null; then
  mut_no "M8 palette cap: mutant failed py_compile"
elif cmp -s "$ORIG_PY" "$MUTDIR/palette_lexicon_agents.py"; then
  mut_no "M8 palette cap: sed had no effect (pattern not found)"
else
  # Use the large palette module created for T14
  _m8_exit=0
  python3 "$MUTDIR/palette_lexicon_agents.py" \
    --input "$_T14_MOD" --output "$ROOT/m8.json" 2>/dev/null || _m8_exit=$?
  _m8_status=""
  if [ -f "$ROOT/m8.json" ]; then
    _m8_status="$(python3 -c \
      "import json; d=json.load(open('$ROOT/m8.json')); print(d.get('status','absent'))" \
      2>/dev/null || echo "")"
  fi
  if [ "$_m8_exit" -ne 0 ] || [ "$_m8_status" != "complete" ]; then
    mut_ok "M8 palette cap reverted: exit=$_m8_exit status='$_m8_status' — DETECTED"
  else
    mut_no "M8 palette cap: mutation NOT detected (still complete)"
  fi
fi
rm -rf "$MUTDIR"

# --- M9: Revert per-file dup detection to concatenation ---
# Mutation (3 sed steps):
#   1. Add _m9_concat accumulator before the per-file loop.
#   2. Accumulate text across iterations.
#   3. Parse accumulated text instead of single-file text.
# Expected: T15 cross-file 'shared.key' is wrongly flagged as a dup -> DETECTED.
MUTDIR="$(mktemp -d)"
cp -a "$SUT_DIR/." "$MUTDIR/"
# Step 1: insert _m9_concat = "" after per_file_dups = {}
sed -i 's/    per_file_dups = {}/    per_file_dups = {}\n    _m9_concat = ""  # MUTANT-M9/' \
  "$MUTDIR/palette_lexicon_agents.py"
# Step 2: accumulate text on the decode line (inline extension)
sed -i 's/        text = raw\.decode("utf-8-sig", errors="replace")/        text = raw.decode("utf-8-sig", errors="replace"); _m9_concat += text + "\\n"/' \
  "$MUTDIR/palette_lexicon_agents.py"
# Step 3: parse accumulated text instead of single-file text
sed -i 's/        fkex, fdups, ferr = parse_lexicon(text)$/        fkex, fdups, ferr = parse_lexicon(_m9_concat)  # MUTANT-M9/' \
  "$MUTDIR/palette_lexicon_agents.py"
if ! python3 -m py_compile "$MUTDIR/palette_lexicon_agents.py" 2>/dev/null; then
  mut_no "M9 per-file dup: mutant failed py_compile"
elif cmp -s "$ORIG_PY" "$MUTDIR/palette_lexicon_agents.py"; then
  mut_no "M9 per-file dup: sed had no effect (pattern not found)"
else
  _m9_exit=0
  python3 "$MUTDIR/palette_lexicon_agents.py" \
    --input "$FIXTURES/multi-lexicon-module" --output "$ROOT/m9.json" 2>/dev/null || _m9_exit=$?
  _m9_cross_flagged=""
  if [ -f "$ROOT/m9.json" ]; then
    _m9_cross_flagged="$(python3 -c "
import json
d = json.load(open('$ROOT/m9.json'))
art = d['artifacts'][0]
dups = art.get('duplicate_bare_keys', {})
found = any('shared.key' in fdups for fdups in dups.values() if isinstance(fdups, dict))
print('yes' if found else 'no')
" 2>/dev/null || echo "")"
  fi
  if [ "$_m9_cross_flagged" = "yes" ]; then
    mut_ok "M9 per-file dup reverted: cross-file 'shared.key' wrongly flagged — DETECTED"
  else
    mut_no "M9 per-file dup: mutation NOT detected (shared.key not flagged or JSON missing)"
  fi
fi
rm -rf "$MUTDIR"

# --- M10: Revert per-file dup key from relpath to basename (Fix 1 / BLOCKER) ---
# Mutation: os.path.relpath(lex_path, ext_dir) → os.path.basename(lex_path)
# Expected: T19 same-basename count drops from 2 to 1 (fr_CA overwrites fr) → DETECTED.
MUTDIR="$(mktemp -d)"
cp -a "$SUT_DIR/." "$MUTDIR/"
sed -i 's/lex_relpath = os\.path\.relpath(lex_path, ext_dir)/lex_relpath = os.path.basename(lex_path)  # MUTANT-M10/' \
  "$MUTDIR/palette_lexicon_agents.py"
if ! python3 -m py_compile "$MUTDIR/palette_lexicon_agents.py" 2>/dev/null; then
  mut_no "M10 relpath→basename: mutant failed py_compile"
elif cmp -s "$ORIG_PY" "$MUTDIR/palette_lexicon_agents.py"; then
  mut_no "M10 relpath→basename: sed had no effect (pattern not found)"
else
  _m10_exit=0
  python3 "$MUTDIR/palette_lexicon_agents.py" \
    --input "$FIXTURES/same-basename-module" --output "$ROOT/m10.json" 2>/dev/null || _m10_exit=$?
  _m10_cnt=""
  if [ -f "$ROOT/m10.json" ]; then
    _m10_cnt="$(python3 -c \
      "import json; d=json.load(open('$ROOT/m10.json')); art=d['artifacts'][0]; print(art.get('duplicate_bare_keys_count','absent'))" \
      2>/dev/null || echo "")"
  fi
  if [ "$_m10_cnt" != "2" ]; then
    mut_ok "M10 relpath→basename: duplicate_bare_keys_count='$_m10_cnt' not 2 — DETECTED"
  else
    mut_no "M10 relpath→basename: mutation NOT detected (still 2)"
  fi
fi
rm -rf "$MUTDIR"

# --- M11: Flatten recursive walk to top-level only (Fix 2 / MAJOR) ---
# Mutation: clear dirnames inside the walk loop so subdirs are never visited.
# Expected: T20a sees lexicon_files_seen < 3 (nested files missed) → DETECTED.
MUTDIR="$(mktemp -d)"
cp -a "$SUT_DIR/." "$MUTDIR/"
sed -i 's/        dirnames\.sort()  # deterministic traversal order/        dirnames[:] = []  # MUTANT-M11/' \
  "$MUTDIR/palette_lexicon_agents.py"
if ! python3 -m py_compile "$MUTDIR/palette_lexicon_agents.py" 2>/dev/null; then
  mut_no "M11 flat walk: mutant failed py_compile"
elif cmp -s "$ORIG_PY" "$MUTDIR/palette_lexicon_agents.py"; then
  mut_no "M11 flat walk: sed had no effect (pattern not found)"
else
  _m11_exit=0
  python3 "$MUTDIR/palette_lexicon_agents.py" \
    --input "$FIXTURES/nested-lexicon-module" --output "$ROOT/m11.json" 2>/dev/null || _m11_exit=$?
  _m11_lfs=""
  if [ -f "$ROOT/m11.json" ]; then
    _m11_lfs="$(python3 -c \
      "import json; d=json.load(open('$ROOT/m11.json')); art=d['artifacts'][0]; print(art.get('lexicon_files_seen','absent'))" \
      2>/dev/null || echo "")"
  fi
  if [ "$_m11_lfs" != "3" ]; then
    mut_ok "M11 flat walk: lexicon_files_seen='$_m11_lfs' not 3 — DETECTED"
  else
    mut_no "M11 flat walk: mutation NOT detected (still 3)"
  fi
fi
rm -rf "$MUTDIR"

# --- M12: Drop S_ISLNK/S_ISREG guard so symlink .lexicon is counted (Fix 2 / MAJOR) ---
# Mutation: replace lstat guard with if False: so symlinks pass into results.
# Expected: T20b sees lexicon_files_seen=2 (symlink wrongly counted) → DETECTED.
MUTDIR="$(mktemp -d)"
cp -a "$SUT_DIR/." "$MUTDIR/"
sed -i 's/            if _stat\.S_ISLNK(lstat\.st_mode) or not _stat\.S_ISREG(lstat\.st_mode):/            if False:  # MUTANT-M12/' \
  "$MUTDIR/palette_lexicon_agents.py"
if ! python3 -m py_compile "$MUTDIR/palette_lexicon_agents.py" 2>/dev/null; then
  mut_no "M12 drop symlink guard: mutant failed py_compile"
elif cmp -s "$ORIG_PY" "$MUTDIR/palette_lexicon_agents.py"; then
  mut_no "M12 drop symlink guard: sed had no effect (pattern not found)"
else
  _m12_exit=0
  python3 "$MUTDIR/palette_lexicon_agents.py" \
    --input "$_T20b_MOD" --output "$ROOT/m12.json" 2>/dev/null || _m12_exit=$?
  _m12_lfs=""
  if [ -f "$ROOT/m12.json" ]; then
    _m12_lfs="$(python3 -c \
      "import json; d=json.load(open('$ROOT/m12.json')); art=d['artifacts'][0]; print(art.get('lexicon_files_seen','absent'))" \
      2>/dev/null || echo "")"
  fi
  if [ "$_m12_lfs" != "1" ]; then
    mut_ok "M12 symlink guard dropped: lexicon_files_seen='$_m12_lfs' not 1 — DETECTED"
  else
    mut_no "M12 symlink guard: mutation NOT detected (still 1)"
  fi
fi
rm -rf "$MUTDIR"

# --- M13: Revert onerror to None — unreadable subdir silently dropped (Fix 3 / MINOR) ---
# Mutation: onerror=_walk_onerror → onerror=None
# Expected: T21 errors empty (unreadable dir silently skipped) → DETECTED.
# Skip when running as root (chmod 000 ineffective).
if [ "$_IS_ROOT" -eq 1 ]; then
  mut_ok "M13 onerror=None: SKIP (running as root)"
else
  MUTDIR="$(mktemp -d)"
  cp -a "$SUT_DIR/." "$MUTDIR/"
  sed -i 's/lexicon_files = _find_lexicon_files(ext_dir, module_root, onerror=_walk_onerror)/lexicon_files = _find_lexicon_files(ext_dir, module_root, onerror=None)  # MUTANT-M13/' \
    "$MUTDIR/palette_lexicon_agents.py"
  if ! python3 -m py_compile "$MUTDIR/palette_lexicon_agents.py" 2>/dev/null; then
    mut_no "M13 onerror=None: mutant failed py_compile"
  elif cmp -s "$ORIG_PY" "$MUTDIR/palette_lexicon_agents.py"; then
    mut_no "M13 onerror=None: sed had no effect (pattern not found)"
  else
    # Recreate the chmod-000 dir (it was restored after T21)
    mkdir -p "$_T21_MOD/art-x/extracted/secret-dir" 2>/dev/null || true
    printf 'hidden=secret\n' > "$_T21_MOD/art-x/extracted/secret-dir/hidden.lexicon" 2>/dev/null || true
    chmod 000 "$_T21_MOD/art-x/extracted/secret-dir" 2>/dev/null || true
    _m13_exit=0
    python3 "$MUTDIR/palette_lexicon_agents.py" \
      --input "$_T21_MOD" --output "$ROOT/m13.json" 2>/dev/null || _m13_exit=$?
    chmod 755 "$_T21_MOD/art-x/extracted/secret-dir" 2>/dev/null || true
    _m13_errs=""
    if [ -f "$ROOT/m13.json" ]; then
      _m13_errs="$(python3 -c \
        "import json; d=json.load(open('$ROOT/m13.json')); print(len(d.get('errors',[])))" \
        2>/dev/null || echo "")"
    fi
    if [ "$_m13_errs" = "0" ] || [ -z "$_m13_errs" ]; then
      mut_ok "M13 onerror=None: errors empty (unreadable dir silently dropped) — DETECTED"
    else
      mut_no "M13 onerror=None: mutation NOT detected (errors still non-empty: $_m13_errs)"
    fi
  fi
  rm -rf "$MUTDIR"
fi

# --- M14: Remove unreadable-file error append (Fix 4 / MINOR) ---
# Mutation: delete the errors.append for lexicon file unreadable
# Expected: T22 errors empty (unreadable file silently skipped) → DETECTED.
# Skip when running as root.
if [ "$_IS_ROOT" -eq 1 ]; then
  mut_ok "M14 unreadable-file error removed: SKIP (running as root)"
else
  MUTDIR="$(mktemp -d)"
  cp -a "$SUT_DIR/." "$MUTDIR/"
  sed -i '/: lexicon file unreadable/d' "$MUTDIR/palette_lexicon_agents.py"
  if ! python3 -m py_compile "$MUTDIR/palette_lexicon_agents.py" 2>/dev/null; then
    mut_no "M14 unreadable-file error: mutant failed py_compile"
  elif cmp -s "$ORIG_PY" "$MUTDIR/palette_lexicon_agents.py"; then
    mut_no "M14 unreadable-file error: sed had no effect (pattern not found)"
  else
    # Recreate the chmod-000 file (restored after T22)
    printf 'key2=v2\n' > "$_T22_MOD/art-y/extracted/locked.lexicon" 2>/dev/null || true
    chmod 000 "$_T22_MOD/art-y/extracted/locked.lexicon" 2>/dev/null || true
    _m14_exit=0
    python3 "$MUTDIR/palette_lexicon_agents.py" \
      --input "$_T22_MOD" --output "$ROOT/m14.json" 2>/dev/null || _m14_exit=$?
    chmod 644 "$_T22_MOD/art-y/extracted/locked.lexicon" 2>/dev/null || true
    _m14_errs=""
    if [ -f "$ROOT/m14.json" ]; then
      _m14_errs="$(python3 -c \
        "import json; d=json.load(open('$ROOT/m14.json')); print(len(d.get('errors',[])))" \
        2>/dev/null || echo "")"
    fi
    if [ "$_m14_errs" = "0" ] || [ -z "$_m14_errs" ]; then
      mut_ok "M14 unreadable-file error removed: errors empty (file silently skipped) — DETECTED"
    else
      mut_no "M14 unreadable-file error: mutation NOT detected (errors still non-empty: $_m14_errs)"
    fi
  fi
  rm -rf "$MUTDIR"
fi

# --- M15: Reintroduce ~22x unmeasured claim into limitations (Fix 5 / MINOR) ---
# Mutation: revert the measurement-agnostic limitation string back to one containing '~22x'.
# Expected: T23 sees '~22x' in limitations → DETECTED.
MUTDIR="$(mktemp -d)"
cp -a "$SUT_DIR/." "$MUTDIR/"
sed -i 's/a pathological XML tree can still exceed available memory during parse/ET amplifies ~22x — a ~14.7 MiB palette can exhaust memory  # MUTANT-M15/' \
  "$MUTDIR/palette_lexicon_agents.py"
if ! python3 -m py_compile "$MUTDIR/palette_lexicon_agents.py" 2>/dev/null; then
  mut_no "M15 ~22x reintroduced: mutant failed py_compile"
elif cmp -s "$ORIG_PY" "$MUTDIR/palette_lexicon_agents.py"; then
  mut_no "M15 ~22x reintroduced: sed had no effect (pattern not found)"
else
  _m15_exit=0
  python3 "$MUTDIR/palette_lexicon_agents.py" \
    --input "$FIXTURES/valid-module" --output "$ROOT/m15.json" 2>/dev/null || _m15_exit=$?
  _m15_has22x=""
  if [ -f "$ROOT/m15.json" ]; then
    _m15_has22x="$(python3 -c \
      "import json; d=json.load(open('$ROOT/m15.json')); lims=' '.join(d.get('limitations',[])); print('yes' if '~22x' in lims else 'no')" \
      2>/dev/null || echo "")"
  fi
  if [ "$_m15_has22x" = "yes" ]; then
    mut_ok "M15 ~22x reintroduced: limitations contains '~22x' — DETECTED"
  else
    mut_no "M15 ~22x: mutation NOT detected (still no '~22x' in limitations)"
  fi
fi
rm -rf "$MUTDIR"

pass=$((pass + MUT_PASS))
fail=$((fail + MUT_FAIL))
echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
