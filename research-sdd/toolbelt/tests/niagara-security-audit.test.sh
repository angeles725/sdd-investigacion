#!/usr/bin/env bash
# Test suite for niagara-security-audit.sh (niagara-audit.v1)
# TDD: write tests first, then implement.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../niagara-security-audit.sh"
FIXTURES="$HERE/fixtures/niagara-security-audit"
mkdir -p "$FIXTURES"

[ -x "$SUT" ] || { echo "FATAL: SUT not found or not executable: $SUT" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 not found" >&2; exit 2; }

pass=0; fail=0
ok(){ echo "  PASS  $1"; pass=$((pass+1)); }
no(){ echo "  FAIL  $1"; fail=$((fail+1)); }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT

# ---------------------------------------------------------------------------
# Build fixture install trees (hermetic; never inside a live target dir)
# ---------------------------------------------------------------------------
python3 - "$FIXTURES" <<'PY'
import os, sys, zipfile, io

out = sys.argv[1]

def mkdir(p):
    os.makedirs(p, exist_ok=True)

def write(p, content):
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, 'w', encoding='utf-8') as f:
        f.write(content)

def write_bin(p, data):
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, 'wb') as f:
        f.write(data)

def make_bog_zip(path, xml_content):
    """Create a deflate-compressed ZIP .bog with a single file.xml entry."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, 'w', zipfile.ZIP_DEFLATED) as z:
        z.writestr('file.xml', xml_content)
    with open(path, 'wb') as f:
        f.write(buf.getvalue())

def make_jar(path, module_xml, signed=False):
    """Create a minimal JAR file with META-INF/module.xml."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, 'w') as z:
        z.writestr('META-INF/module.xml', module_xml)
        if signed:
            z.writestr('META-INF/CERT.RSA', 'fake-cert-data')
    with open(path, 'wb') as f:
        f.write(buf.getvalue())

# ---- existing fixtures ----

# secure-home: hardened config — all three property-based checks should PASS
write(os.path.join(out, 'secure-home', 'defaults', 'system.properties'), (
    'niagara.moduleVerificationMode=high\n'
    'program.requireSigning=true\n'
    'niagara.commandLinePropertyBlacklist='
    'skipModuleValidation,commissioning.ignoreVerificationMode\n'
))
mkdir(os.path.join(out, 'secure-home', 'security'))

# insecure-home: weakened config — SEC-01 and SEC-07 should FAIL
write(os.path.join(out, 'insecure-home', 'defaults', 'system.properties'), (
    'niagara.moduleVerificationMode=low\n'
    'program.requireSigning=false\n'
))
mkdir(os.path.join(out, 'insecure-home', 'security'))

# empty-home: just an empty directory (no Niagara files present)
mkdir(os.path.join(out, 'empty-home'))

# ---- ZIP bog fixtures for SEC-08/10/12 ----
bogs = os.path.join(out, 'bogs')
mkdir(bogs)

# bog-exec-on.zip: allowProgramRuntimeExec="true" → SEC-08 FAIL
make_bog_zip(os.path.join(bogs, 'bog-exec-on.zip'),
    '<config><ProgramService allowProgramRuntimeExec="true"/></config>')

# bog-exec-off.zip: allowProgramRuntimeExec="false" → SEC-08 PASS
make_bog_zip(os.path.join(bogs, 'bog-exec-off.zip'),
    '<config><ProgramService allowProgramRuntimeExec="false"/></config>')

# bog-syslog-on.zip: SyslogService enabled="true" → SEC-10 PASS
make_bog_zip(os.path.join(bogs, 'bog-syslog-on.zip'),
    '<config><SyslogService enabled="true" serverHost="siem.example.com"/></config>')

# bog-syslog-off.zip: SyslogService enabled="false" → SEC-10 FAIL
make_bog_zip(os.path.join(bogs, 'bog-syslog-off.zip'),
    '<config><SyslogService enabled="false"/></config>')

# bog-ext-key.zip: reversibleEncodingKeySource="external" → SEC-12 PASS
make_bog_zip(os.path.join(bogs, 'bog-ext-key.zip'),
    '<config><SecurityService reversibleEncodingKeySource="external"/></config>')

# bog-no-key.zip: no encoding key source attr → SEC-12 FAIL
make_bog_zip(os.path.join(bogs, 'bog-no-key.zip'),
    '<config><station someAttr="value"/></config>')

# bog-binary.dat: non-ZIP binary blob → all three checks MANUAL (format unrecognized)
write_bin(os.path.join(bogs, 'bog-binary.dat'),
    bytes([0x00, 0x01, 0x02, 0xFF, 0xFE, 0x00, 0xAB, 0xCD] * 256))

# bog-plaintext.xml: plaintext XML (not a ZIP) → same attribute parsing as ZIP path
with open(os.path.join(bogs, 'bog-plaintext.xml'), 'w', encoding='utf-8') as f:
    f.write('<config><ProgramService allowProgramRuntimeExec="true"/>'
            '<SyslogService enabled="false"/></config>')

# ---- SEC-06 fixtures ----
# lic-hit-home: has a license with smDeveloperMode="true" → SEC-06 FAIL
# The attribute must be directly in the tag (smDeveloperMode="true") to match the regex.
write(os.path.join(out, 'lic-hit-home', 'defaults', 'system.properties'),
    'niagara.moduleVerificationMode=high\n')
write(os.path.join(out, 'lic-hit-home', 'security', 'licenses', 'dev.license'),
    '<?xml version="1.0"?>\n<license smDeveloperMode="true"/>\n')

# ---- SEC-15 fixture ----
# modules-wild-home: has a wildcard unsigned JAR → SEC-15 FAIL
moddir = os.path.join(out, 'modules-wild-home', 'modules')
mkdir(moddir)
make_jar(os.path.join(moddir, 'wildcard-unsigned.jar'),
    '<module><permission class="com.tridium.security.KeyRingPermission" name="*"/></module>',
    signed=False)
# also a non-wildcard JAR for scan-count test
make_jar(os.path.join(moddir, 'plain-unsigned.jar'),
    '<module><permission class="com.tridium.security.SomeOtherPermission" name="*"/></module>',
    signed=False)

# ---- T24 fixture: bog-large.zip (file.xml > _MAX_BOG_INFLATE = 32 MiB) ----
# Well-formed ZIP; content = 32 MiB + 1 byte of 'A' (no bog attributes).
# Used to verify that the bounded-read guard truncates oversized entries.
# Created once; subsequent runs reuse it.
_bog_large = os.path.join(bogs, 'bog-large.zip')
if not os.path.exists(_bog_large):
    _cap_inflate = 32 * 1024 * 1024
    _large_bytes = b'A' * (_cap_inflate + 1)
    _buf = io.BytesIO()
    with zipfile.ZipFile(_buf, 'w', zipfile.ZIP_DEFLATED) as _z:
        _z.writestr('file.xml', _large_bytes)
    with open(_bog_large, 'wb') as _f:
        _f.write(_buf.getvalue())

# ---- T25 fixture: jar-bomb-home with bomb.jar (module.xml > _MAX_MODULE_XML = 64 KiB) ----
# Well-formed JAR; module.xml starts with a wildcard KeyRingPermission then 'A' padding.
# Total > 65536 bytes so the bounded-read guard skips it; the wildcard is reachable
# only if the guard is removed (mutation M13).
_bomb_moddir = os.path.join(out, 'jar-bomb-home', 'modules')
mkdir(_bomb_moddir)
_kring_prefix = ('<module><permission class="com.tridium.security.KeyRingPermission"'
                 ' name="*"/></module>')
_bomb_xml = _kring_prefix + 'A' * (64 * 1024 + 1)  # total > _MAX_MODULE_XML
_bomb_buf = io.BytesIO()
with zipfile.ZipFile(_bomb_buf, 'w', zipfile.ZIP_DEFLATED) as _z:
    _z.writestr('META-INF/module.xml', _bomb_xml)
with open(os.path.join(_bomb_moddir, 'bomb.jar'), 'wb') as _f:
    _f.write(_bomb_buf.getvalue())

PY

# ---------------------------------------------------------------------------
# T1: absent install root → exit 2, no JSON produced
# ---------------------------------------------------------------------------
_t1_exit=0
"$SUT" "$ROOT/no-such-dir" --output "$ROOT/t1.json" 2>/dev/null \
  || _t1_exit=$?
if [ "$_t1_exit" -eq 2 ] && [ ! -f "$ROOT/t1.json" ]; then
  ok "T1 absent root: exit 2, no JSON"
else
  no "T1 absent root: expected exit 2 + no JSON, got exit $_t1_exit"
fi

# ---------------------------------------------------------------------------
# T2: symlink root → exit 2 (symlink guard on install root)
# ---------------------------------------------------------------------------
ln -sf "$FIXTURES/secure-home" "$ROOT/sym-home"
_t2_exit=0
"$SUT" "$ROOT/sym-home" --output "$ROOT/t2.json" 2>/dev/null \
  || _t2_exit=$?
if [ "$_t2_exit" -eq 2 ]; then
  ok "T2 symlink root: exit 2 (symlink guard)"
else
  no "T2 symlink root: expected exit 2, got $_t2_exit"
fi

# ---------------------------------------------------------------------------
# T3: non-directory input (regular file) → exit 2
# ---------------------------------------------------------------------------
echo "notadir" > "$ROOT/notadir.txt"
_t3_exit=0
"$SUT" "$ROOT/notadir.txt" --output "$ROOT/t3.json" 2>/dev/null \
  || _t3_exit=$?
if [ "$_t3_exit" -eq 2 ]; then
  ok "T3 non-directory input: exit 2"
else
  no "T3 non-directory input: expected exit 2, got $_t3_exit"
fi

# ---------------------------------------------------------------------------
# T4: empty directory → exit 0, status:complete, checks_run > 0
#     (proves instrument looked; all checks are MANUAL/NA but count > 0)
# ---------------------------------------------------------------------------
_t4_exit=0
"$SUT" "$FIXTURES/empty-home" --output "$ROOT/t4.json" 2>/dev/null \
  || _t4_exit=$?
if [ "$_t4_exit" -eq 0 ]; then
  if python3 - "$ROOT/t4.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
assert d['schema'] == 'niagara-audit.v1', f"bad schema: {d.get('schema')!r}"
assert d['status'] == 'complete', f"bad status: {d.get('status')!r}"
assert d['errors'] == [], f"unexpected errors: {d.get('errors')}"
s = d['summary']
# Must prove it looked: checks_run > 0 (even on empty dir, static checks still fire)
assert s['checks_run'] > 0, f"checks_run must be > 0, got {s.get('checks_run')}"
PY
  then
    ok "T4 empty dir: exit 0, status:complete, checks_run > 0"
  else
    no "T4 empty dir: exit 0 but JSON validation failed"
  fi
else
  no "T4 empty dir: expected exit 0, got $_t4_exit"
fi

# ---------------------------------------------------------------------------
# T5: secure install → exit 0, SEC-01/SEC-05/SEC-07 all PASS
# ---------------------------------------------------------------------------
_t5_exit=0
"$SUT" "$FIXTURES/secure-home" --output "$ROOT/t5.json" 2>/dev/null \
  || _t5_exit=$?
if [ "$_t5_exit" -eq 0 ]; then
  if python3 - "$ROOT/t5.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
assert d['schema'] == 'niagara-audit.v1', f"bad schema: {d.get('schema')!r}"
assert d['status'] == 'complete', f"bad status: {d.get('status')!r}"
checks = {c['id']: c for c in d['checks']}
assert checks['SEC-01']['verdict'] == 'PASS', \
    f"SEC-01: expected PASS, got {checks['SEC-01']['verdict']!r}"
assert checks['SEC-07']['verdict'] == 'PASS', \
    f"SEC-07: expected PASS, got {checks['SEC-07']['verdict']!r}"
assert checks['SEC-05']['verdict'] == 'PASS', \
    f"SEC-05: expected PASS, got {checks['SEC-05']['verdict']!r}"
PY
  then
    ok "T5 secure install: exit 0, SEC-01/05/07 PASS"
  else
    no "T5 secure install: exit 0 but JSON validation failed"
  fi
else
  no "T5 secure install: expected exit 0, got $_t5_exit"
fi

# ---------------------------------------------------------------------------
# T6: insecure install → exit 0, SEC-01 FAIL, SEC-07 FAIL, checks_fail >= 2
# ---------------------------------------------------------------------------
_t6_exit=0
"$SUT" "$FIXTURES/insecure-home" --output "$ROOT/t6.json" 2>/dev/null \
  || _t6_exit=$?
if [ "$_t6_exit" -eq 0 ]; then
  if python3 - "$ROOT/t6.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
assert d['status'] == 'complete', f"bad status: {d.get('status')!r}"
checks = {c['id']: c for c in d['checks']}
assert checks['SEC-01']['verdict'] == 'FAIL', \
    f"SEC-01: expected FAIL, got {checks['SEC-01']['verdict']!r}"
assert checks['SEC-07']['verdict'] == 'FAIL', \
    f"SEC-07: expected FAIL, got {checks['SEC-07']['verdict']!r}"
s = d['summary']
assert s['checks_fail'] >= 2, \
    f"expected checks_fail >= 2, got {s.get('checks_fail')}"
PY
  then
    ok "T6 insecure install: exit 0, SEC-01/07 FAIL, checks_fail >= 2"
  else
    no "T6 insecure install: exit 0 but JSON validation failed"
  fi
else
  no "T6 insecure install: expected exit 0, got $_t6_exit"
fi

# ---------------------------------------------------------------------------
# T7: --output symlink → exit 2, victim file not overwritten
# ---------------------------------------------------------------------------
echo "victim-content" > "$ROOT/victim.txt"
ln -sf "$ROOT/victim.txt" "$ROOT/out_sym.json"
_t7_exit=0
"$SUT" "$FIXTURES/secure-home" --output "$ROOT/out_sym.json" \
  2>/dev/null || _t7_exit=$?
_victim_ok=0
[ "$(cat "$ROOT/victim.txt" 2>/dev/null)" = "victim-content" ] && _victim_ok=1
if [ "$_t7_exit" -eq 2 ] && [ "$_victim_ok" -eq 1 ]; then
  ok "T7 output symlink: exit 2, victim not overwritten"
else
  no "T7 output symlink: expected exit 2 + victim intact, got exit $_t7_exit (victim_ok=$_victim_ok)"
fi

# ---------------------------------------------------------------------------
# T8: --output pre-existing file → exit 2 (O_CREAT|O_EXCL guard)
# ---------------------------------------------------------------------------
echo "existing" > "$ROOT/pre_existing.json"
_t8_exit=0
"$SUT" "$FIXTURES/secure-home" --output "$ROOT/pre_existing.json" \
  2>/dev/null || _t8_exit=$?
if [ "$_t8_exit" -eq 2 ]; then
  ok "T8 pre-existing output: exit 2 (O_CREAT|O_EXCL refused)"
else
  no "T8 pre-existing output: expected exit 2, got $_t8_exit"
fi

# ---------------------------------------------------------------------------
# T9: SEC-16 always FAIL (architectural — no config knob exists)
# ---------------------------------------------------------------------------
_t9_exit=0
"$SUT" "$FIXTURES/secure-home" --output "$ROOT/t9.json" 2>/dev/null \
  || _t9_exit=$?
if [ "$_t9_exit" -eq 0 ]; then
  if python3 - "$ROOT/t9.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
checks = {c['id']: c for c in d['checks']}
assert 'SEC-16' in checks, "SEC-16 check missing from output"
assert checks['SEC-16']['verdict'] == 'FAIL', \
    f"SEC-16 always-FAIL: expected FAIL, got {checks['SEC-16']['verdict']!r}"
PY
  then
    ok "T9 SEC-16 always-FAIL confirmed"
  else
    no "T9 SEC-16 always-FAIL: JSON validation failed"
  fi
else
  no "T9 SEC-16 always-FAIL: expected exit 0, got $_t9_exit"
fi

# ---------------------------------------------------------------------------
# T10: ZIP bog + --station → SEC-08 FAIL when exec=true
#      (BLOCKER: raw-byte grep on deflated ZIP gave false PASS)
# ---------------------------------------------------------------------------
_t10_exit=0
"$SUT" "$FIXTURES/secure-home" \
  --station "$FIXTURES/bogs/bog-exec-on.zip" \
  --output "$ROOT/t10.json" 2>/dev/null || _t10_exit=$?
if [ "$_t10_exit" -eq 0 ]; then
  if python3 - "$ROOT/t10.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
checks = {c['id']: c for c in d['checks']}
assert checks['SEC-08']['verdict'] == 'FAIL', \
    f"SEC-08 exec-on ZIP: expected FAIL, got {checks['SEC-08']['verdict']!r} (observed={checks['SEC-08'].get('observed')!r})"
PY
  then
    ok "T10 ZIP bog exec-on: SEC-08 FAIL"
  else
    no "T10 ZIP bog exec-on: expected SEC-08=FAIL"
  fi
else
  no "T10 ZIP bog exec-on: expected exit 0, got $_t10_exit"
fi

# ---------------------------------------------------------------------------
# T11: ZIP bog + --station → SEC-08 PASS when exec=false
# ---------------------------------------------------------------------------
_t11_exit=0
"$SUT" "$FIXTURES/secure-home" \
  --station "$FIXTURES/bogs/bog-exec-off.zip" \
  --output "$ROOT/t11.json" 2>/dev/null || _t11_exit=$?
if [ "$_t11_exit" -eq 0 ]; then
  if python3 - "$ROOT/t11.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
checks = {c['id']: c for c in d['checks']}
assert checks['SEC-08']['verdict'] == 'PASS', \
    f"SEC-08 exec-off ZIP: expected PASS, got {checks['SEC-08']['verdict']!r}"
PY
  then
    ok "T11 ZIP bog exec-off: SEC-08 PASS"
  else
    no "T11 ZIP bog exec-off: expected SEC-08=PASS"
  fi
else
  no "T11 ZIP bog exec-off: expected exit 0, got $_t11_exit"
fi

# ---------------------------------------------------------------------------
# T12: ZIP bog + --station → SEC-10 PASS when syslog enabled
#      (BLOCKER: raw bytes missed SyslogService in deflated data → false FAIL)
# ---------------------------------------------------------------------------
_t12_exit=0
"$SUT" "$FIXTURES/secure-home" \
  --station "$FIXTURES/bogs/bog-syslog-on.zip" \
  --output "$ROOT/t12.json" 2>/dev/null || _t12_exit=$?
if [ "$_t12_exit" -eq 0 ]; then
  if python3 - "$ROOT/t12.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
checks = {c['id']: c for c in d['checks']}
assert checks['SEC-10']['verdict'] == 'PASS', \
    f"SEC-10 syslog-on ZIP: expected PASS, got {checks['SEC-10']['verdict']!r} (observed={checks['SEC-10'].get('observed')!r})"
PY
  then
    ok "T12 ZIP bog syslog-on: SEC-10 PASS"
  else
    no "T12 ZIP bog syslog-on: expected SEC-10=PASS"
  fi
else
  no "T12 ZIP bog syslog-on: expected exit 0, got $_t12_exit"
fi

# ---------------------------------------------------------------------------
# T13: ZIP bog + --station → SEC-12 PASS when reversibleEncodingKeySource=external
#      (BLOCKER: wrong attr name EncryptionKeySource vs reversibleEncodingKeySource → false FAIL)
# ---------------------------------------------------------------------------
_t13_exit=0
"$SUT" "$FIXTURES/secure-home" \
  --station "$FIXTURES/bogs/bog-ext-key.zip" \
  --output "$ROOT/t13.json" 2>/dev/null || _t13_exit=$?
if [ "$_t13_exit" -eq 0 ]; then
  if python3 - "$ROOT/t13.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
checks = {c['id']: c for c in d['checks']}
assert checks['SEC-12']['verdict'] == 'PASS', \
    f"SEC-12 ext-key ZIP: expected PASS (external encoding), got {checks['SEC-12']['verdict']!r} (observed={checks['SEC-12'].get('observed')!r})"
PY
  then
    ok "T13 ZIP bog ext-key: SEC-12 PASS (external encoding = secure)"
  else
    no "T13 ZIP bog ext-key: expected SEC-12=PASS"
  fi
else
  no "T13 ZIP bog ext-key: expected exit 0, got $_t13_exit"
fi

# ---------------------------------------------------------------------------
# T14: ZIP bog + --station → SEC-12 FAIL when no encoding key source
# ---------------------------------------------------------------------------
_t14_exit=0
"$SUT" "$FIXTURES/secure-home" \
  --station "$FIXTURES/bogs/bog-no-key.zip" \
  --output "$ROOT/t14.json" 2>/dev/null || _t14_exit=$?
if [ "$_t14_exit" -eq 0 ]; then
  if python3 - "$ROOT/t14.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
checks = {c['id']: c for c in d['checks']}
assert checks['SEC-12']['verdict'] == 'FAIL', \
    f"SEC-12 no-key ZIP: expected FAIL, got {checks['SEC-12']['verdict']!r}"
PY
  then
    ok "T14 ZIP bog no-key: SEC-12 FAIL"
  else
    no "T14 ZIP bog no-key: expected SEC-12=FAIL"
  fi
else
  no "T14 ZIP bog no-key: expected exit 0, got $_t14_exit"
fi

# ---------------------------------------------------------------------------
# T15: binary (non-ZIP, non-XML) bog → SEC-08/10/12 all MANUAL with format reason
#      (format unrecognized → never a false PASS/FAIL)
# ---------------------------------------------------------------------------
_t15_exit=0
"$SUT" "$FIXTURES/secure-home" \
  --station "$FIXTURES/bogs/bog-binary.dat" \
  --output "$ROOT/t15.json" 2>/dev/null || _t15_exit=$?
if [ "$_t15_exit" -eq 0 ]; then
  if python3 - "$ROOT/t15.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
checks = {c['id']: c for c in d['checks']}
not_provided = "not checked (no --station config.bog provided)"
for cid in ('SEC-08', 'SEC-10', 'SEC-12'):
    c = checks[cid]
    assert c['verdict'] == 'MANUAL', \
        f"{cid}: expected MANUAL for binary bog, got {c['verdict']!r}"
    assert c.get('observed', '') != not_provided, \
        f"{cid}: binary bog observed must differ from not-provided string"
PY
  then
    ok "T15 binary bog: SEC-08/10/12 MANUAL (format unrecognized, not false PASS/FAIL)"
  else
    no "T15 binary bog: expected SEC-08/10/12 all MANUAL with distinct reason"
  fi
else
  no "T15 binary bog: expected exit 0, got $_t15_exit"
fi

# ---------------------------------------------------------------------------
# T16: plaintext XML bog → SEC-08 FAIL when exec=true (non-ZIP path)
# ---------------------------------------------------------------------------
_t16_exit=0
"$SUT" "$FIXTURES/secure-home" \
  --station "$FIXTURES/bogs/bog-plaintext.xml" \
  --output "$ROOT/t16.json" 2>/dev/null || _t16_exit=$?
if [ "$_t16_exit" -eq 0 ]; then
  if python3 - "$ROOT/t16.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
checks = {c['id']: c for c in d['checks']}
assert checks['SEC-08']['verdict'] == 'FAIL', \
    f"SEC-08 plaintext XML exec-on: expected FAIL, got {checks['SEC-08']['verdict']!r}"
PY
  then
    ok "T16 plaintext XML bog exec-on: SEC-08 FAIL"
  else
    no "T16 plaintext XML bog exec-on: expected SEC-08=FAIL"
  fi
else
  no "T16 plaintext XML bog exec-on: expected exit 0, got $_t16_exit"
fi

# ---------------------------------------------------------------------------
# T17: SEC-06 absent license dir → verdict NA (not PASS)
#      (MINOR-1: absent dir → empty list → PASS was §7 wrong)
# ---------------------------------------------------------------------------
_t17_exit=0
"$SUT" "$FIXTURES/insecure-home" --output "$ROOT/t17.json" 2>/dev/null \
  || _t17_exit=$?
if [ "$_t17_exit" -eq 0 ]; then
  if python3 - "$ROOT/t17.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
checks = {c['id']: c for c in d['checks']}
v = checks['SEC-06']['verdict']
assert v == 'NA', \
    f"SEC-06 absent license dir: expected NA, got {v!r}"
PY
  then
    ok "T17 SEC-06 absent license dir: verdict NA (not PASS)"
  else
    no "T17 SEC-06 absent license dir: expected NA"
  fi
else
  no "T17 SEC-06 absent license dir: expected exit 0, got $_t17_exit"
fi

# ---------------------------------------------------------------------------
# T18: --station provided but file missing → observed distinct from not-provided
#      (MINOR-2: absent station must not collapse to not-given message)
# ---------------------------------------------------------------------------
_t18_exit=0
"$SUT" "$FIXTURES/secure-home" \
  --station "$ROOT/nonexistent-config.bog" \
  --output "$ROOT/t18.json" 2>/dev/null || _t18_exit=$?
if [ "$_t18_exit" -eq 0 ]; then
  if python3 - "$ROOT/t18.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
checks = {c['id']: c for c in d['checks']}
not_provided_msg = "not checked (no --station config.bog provided)"
for cid in ('SEC-08', 'SEC-10', 'SEC-12'):
    c = checks[cid]
    assert c['verdict'] == 'MANUAL', f"{cid}: expected MANUAL, got {c['verdict']!r}"
    obs = c.get('observed', '')
    assert obs != not_provided_msg, \
        f"{cid}: provided-but-missing must have distinct observed (got: {obs!r})"
PY
  then
    ok "T18 --station missing: MANUAL with distinct observed (not same as not-provided)"
  else
    no "T18 --station missing: observed must differ from not-provided string"
  fi
else
  no "T18 --station missing: expected exit 0, got $_t18_exit"
fi

# ---------------------------------------------------------------------------
# T19: symlink root with trailing slash → exit 2
#      (MINOR-3: os.lstat("link/") follows link on POSIX; must strip trailing sep)
# ---------------------------------------------------------------------------
# sym-home was created as a symlink in T2; reuse it here with trailing slash
_t19_exit=0
"$SUT" "$ROOT/sym-home/" --output "$ROOT/t19.json" 2>/dev/null \
  || _t19_exit=$?
if [ "$_t19_exit" -eq 2 ]; then
  ok "T19 symlink root trailing slash: exit 2 (symlink guard fires with /)"
else
  no "T19 symlink root trailing slash: expected exit 2, got $_t19_exit"
fi

# ---------------------------------------------------------------------------
# T20: security/licenses/ symlink escaping home root → SEC-06 NA (skipped)
#      (MINOR-4: intermediate symlinks must not be followed outside install root)
# ---------------------------------------------------------------------------
# Create an "outside" target with a devmode license, then symlink into a home
OUTSIDE_LICS="$ROOT/outside-licenses"
mkdir -p "$OUTSIDE_LICS"
printf '<?xml version="1.0"?>\n<lic><prop name="smDeveloperMode" value="true"/></lic>\n' \
  > "$OUTSIDE_LICS/dev.license"

ESCAPE_HOME="$ROOT/escape-home"
mkdir -p "$ESCAPE_HOME/security"
ln -sf "$OUTSIDE_LICS" "$ESCAPE_HOME/security/licenses"

_t20_exit=0
"$SUT" "$ESCAPE_HOME" --output "$ROOT/t20.json" 2>/dev/null \
  || _t20_exit=$?
if [ "$_t20_exit" -eq 0 ]; then
  if python3 - "$ROOT/t20.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
checks = {c['id']: c for c in d['checks']}
v = checks['SEC-06']['verdict']
assert v == 'NA', \
    f"SEC-06 symlink-escape licenses/: expected NA (symlink skipped), got {v!r}"
PY
  then
    ok "T20 symlink-escape licenses/: SEC-06 NA (symlink not followed outside root)"
  else
    no "T20 symlink-escape licenses/: expected SEC-06=NA"
  fi
else
  no "T20 symlink-escape licenses/: expected exit 0, got $_t20_exit"
fi

# ---------------------------------------------------------------------------
# T21: SEC-05 absent blacklist → FAIL
#      (coverage: sec05_covered=True mutation must be catchable)
# ---------------------------------------------------------------------------
_t21_exit=0
"$SUT" "$FIXTURES/insecure-home" --output "$ROOT/t21.json" 2>/dev/null \
  || _t21_exit=$?
if [ "$_t21_exit" -eq 0 ]; then
  if python3 - "$ROOT/t21.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
checks = {c['id']: c for c in d['checks']}
assert checks['SEC-05']['verdict'] == 'FAIL', \
    f"SEC-05 absent blacklist: expected FAIL, got {checks['SEC-05']['verdict']!r}"
PY
  then
    ok "T21 SEC-05 absent blacklist: FAIL"
  else
    no "T21 SEC-05 absent blacklist: expected FAIL"
  fi
else
  no "T21 SEC-05 absent blacklist: expected exit 0, got $_t21_exit"
fi

# ---------------------------------------------------------------------------
# T22: SEC-06 license with relaxation attr → FAIL
#      (coverage: lic_hits mutation must be catchable)
# ---------------------------------------------------------------------------
_t22_exit=0
"$SUT" "$FIXTURES/lic-hit-home" --output "$ROOT/t22.json" 2>/dev/null \
  || _t22_exit=$?
if [ "$_t22_exit" -eq 0 ]; then
  if python3 - "$ROOT/t22.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
checks = {c['id']: c for c in d['checks']}
assert checks['SEC-06']['verdict'] == 'FAIL', \
    f"SEC-06 with dev license: expected FAIL, got {checks['SEC-06']['verdict']!r}"
PY
  then
    ok "T22 SEC-06 with relaxation license: FAIL"
  else
    no "T22 SEC-06 with relaxation license: expected FAIL"
  fi
else
  no "T22 SEC-06 with relaxation license: expected exit 0, got $_t22_exit"
fi

# ---------------------------------------------------------------------------
# T23: SEC-15 wildcard unsigned JAR → FAIL + scan count visible in observed
#      (coverage: keyring mutation must be catchable; also tests JAR count visibility)
# ---------------------------------------------------------------------------
_t23_exit=0
"$SUT" "$FIXTURES/modules-wild-home" --output "$ROOT/t23.json" 2>/dev/null \
  || _t23_exit=$?
if [ "$_t23_exit" -eq 0 ]; then
  if python3 - "$ROOT/t23.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
checks = {c['id']: c for c in d['checks']}
c15 = checks['SEC-15']
assert c15['verdict'] == 'FAIL', \
    f"SEC-15 wildcard unsigned: expected FAIL, got {c15['verdict']!r}"
obs = c15.get('observed', '')
# Scan count must be visible in observed (§7 truncation-always-visible)
assert 'scanned' in obs.lower(), \
    f"SEC-15 observed must include scan count, got: {obs!r}"
PY
  then
    ok "T23 SEC-15 wildcard unsigned: FAIL + scan count visible"
  else
    no "T23 SEC-15 wildcard unsigned: expected FAIL with scan count in observed"
  fi
else
  no "T23 SEC-15 wildcard unsigned: expected exit 0, got $_t23_exit"
fi

# ---------------------------------------------------------------------------
# T24: bog file.xml > _MAX_BOG_INFLATE (32 MiB) → SEC-08/10/12 all MANUAL (truncated)
#      Verifies the bounded-read guard fires on an oversized file.xml.
#      M12 mutation (removing the guard) makes this test FAIL.
# ---------------------------------------------------------------------------
_t24_exit=0
"$SUT" "$FIXTURES/secure-home" \
  --station "$FIXTURES/bogs/bog-large.zip" \
  --output "$ROOT/t24.json" 2>/dev/null || _t24_exit=$?
if [ "$_t24_exit" -eq 0 ]; then
  if python3 - "$ROOT/t24.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
checks = {c['id']: c for c in d['checks']}
for cid in ('SEC-08', 'SEC-10', 'SEC-12'):
    v = checks[cid]['verdict']
    assert v == 'MANUAL', \
        f"{cid}: oversized bog must give MANUAL, got {v!r}"
PY
  then
    ok "T24 bog >32 MiB: SEC-08/10/12 MANUAL (bounded-read guard fired)"
  else
    no "T24 bog >32 MiB: expected SEC-08/10/12=MANUAL"
  fi
else
  no "T24 bog >32 MiB: expected exit 0, got $_t24_exit"
fi

# ---------------------------------------------------------------------------
# T25: module.xml in JAR > _MAX_MODULE_XML (64 KiB) → SEC-15 PASS (bomb JAR skipped)
#      bomb.jar contains a wildcard KeyRingPermission but module.xml is oversized;
#      the bounded-read guard skips it.  M13 mutation reveals the wildcard (FAIL).
# ---------------------------------------------------------------------------
_t25_exit=0
"$SUT" "$FIXTURES/jar-bomb-home" --output "$ROOT/t25.json" 2>/dev/null \
  || _t25_exit=$?
if [ "$_t25_exit" -eq 0 ]; then
  if python3 - "$ROOT/t25.json" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
checks = {c['id']: c for c in d['checks']}
v = checks['SEC-15']['verdict']
assert v == 'PASS', \
    f"SEC-15: oversized module.xml bomb JAR must be skipped (PASS), got {v!r}"
PY
  then
    ok "T25 module.xml bomb: SEC-15 PASS (oversized JAR skipped by bounded-read guard)"
  else
    no "T25 module.xml bomb: expected SEC-15=PASS (JAR skipped)"
  fi
else
  no "T25 module.xml bomb: expected exit 0, got $_t25_exit"
fi

# ---------------------------------------------------------------------------
# Summary (non-teeth path)
# ---------------------------------------------------------------------------
if [ "${1:-}" != "--prove-teeth" ]; then
  echo "== $pass passed · $fail failed =="; [ "$fail" -eq 0 ]
  exit $?
fi

# ---------------------------------------------------------------------------
echo "-- teeth: niagara-security-audit mutation controls --"
# ---------------------------------------------------------------------------
MUT_PASS=0; MUT_FAIL=0
mut_ok(){ echo "  PASS(mut)  $1"; MUT_PASS=$((MUT_PASS+1)); }
mut_no(){ echo "  FAIL(mut)  $1"; MUT_FAIL=$((MUT_FAIL+1)); }

SUT_DIR="$(cd "$(dirname "$SUT")" && pwd)"
ORIG_PY="$SUT_DIR/niagara_security_audit.py"
if [ ! -f "$ORIG_PY" ]; then
  echo "  FAIL(mut)  niagara_security_audit.py not found: $ORIG_PY"
  echo "== $pass passed · $fail failed =="
  exit 1
fi
MUTDIR="$(mktemp -d)"

# --- M1: Remove install-root symlink guard ---
# Expected: symlink root is followed → T2 expects exit 2, mutant exits 0 → DETECTED
cp -a "$SUT_DIR/." "$MUTDIR/"
sed -i 's/_stat\.S_ISLNK(lstat_result\.st_mode):/_stat.S_ISBLK(lstat_result.st_mode):  # MUTANT-M1/' \
  "$MUTDIR/niagara_security_audit.py"
if ! python3 -m py_compile "$MUTDIR/niagara_security_audit.py" 2>/dev/null; then
  mut_no "M1 symlink guard: mutant failed py_compile"
elif cmp -s "$ORIG_PY" "$MUTDIR/niagara_security_audit.py"; then
  mut_no "M1 symlink guard: sed had no effect (pattern not found)"
else
  _m1_exit=0
  python3 "$MUTDIR/niagara_security_audit.py" \
    "$ROOT/sym-home" --output "$ROOT/m1.json" 2>/dev/null || _m1_exit=$?
  if [ "$_m1_exit" -ne 2 ]; then
    mut_ok "M1 symlink guard removal detected (exit $_m1_exit, not 2)"
  else
    mut_no "M1 symlink guard: mutation NOT detected (still exits 2)"
  fi
fi
rm -rf "$MUTDIR"

# --- M2: Clear _sec01_fail (SEC-01 never fires FAIL) ---
# Expected: insecure install returns SEC-01=PASS instead of FAIL → T6 fails
MUTDIR="$(mktemp -d)"
cp -a "$SUT_DIR/." "$MUTDIR/"
sed -i 's/_sec01_fail = v is None or commented or v\.lower() == "low"/_sec01_fail = False  # MUTANT-M2/' \
  "$MUTDIR/niagara_security_audit.py"
if ! python3 -m py_compile "$MUTDIR/niagara_security_audit.py" 2>/dev/null; then
  mut_no "M2 SEC-01 fail: mutant failed py_compile"
elif cmp -s "$ORIG_PY" "$MUTDIR/niagara_security_audit.py"; then
  mut_no "M2 SEC-01 fail: sed had no effect (pattern not found)"
else
  _m2_exit=0
  python3 "$MUTDIR/niagara_security_audit.py" \
    "$FIXTURES/insecure-home" --output "$ROOT/m2.json" 2>/dev/null || _m2_exit=$?
  _m2_sec01=""
  if [ -f "$ROOT/m2.json" ]; then
    _m2_sec01="$(python3 -c \
      "import json; c={x['id']:x for x in json.load(open('$ROOT/m2.json'))['checks']}; print(c['SEC-01']['verdict'])" \
      2>/dev/null || echo "")"
  fi
  if [ "$_m2_sec01" != "FAIL" ]; then
    mut_ok "M2 SEC-01 cleared: verdict='$_m2_sec01' not FAIL — DETECTED"
  else
    mut_no "M2 SEC-01: mutation NOT detected (still FAIL)"
  fi
fi
rm -rf "$MUTDIR"

# --- M3: Clear _sec07_bad (SEC-07 never fires FAIL) ---
# Expected: insecure install returns SEC-07=PASS instead of FAIL → T6 fails
MUTDIR="$(mktemp -d)"
cp -a "$SUT_DIR/." "$MUTDIR/"
sed -i 's/_sec07_bad = v is None or commented or v\.lower() == "false"/_sec07_bad = False  # MUTANT-M3/' \
  "$MUTDIR/niagara_security_audit.py"
if ! python3 -m py_compile "$MUTDIR/niagara_security_audit.py" 2>/dev/null; then
  mut_no "M3 SEC-07 fail: mutant failed py_compile"
elif cmp -s "$ORIG_PY" "$MUTDIR/niagara_security_audit.py"; then
  mut_no "M3 SEC-07 fail: sed had no effect (pattern not found)"
else
  _m3_exit=0
  python3 "$MUTDIR/niagara_security_audit.py" \
    "$FIXTURES/insecure-home" --output "$ROOT/m3.json" 2>/dev/null || _m3_exit=$?
  _m3_sec07=""
  if [ -f "$ROOT/m3.json" ]; then
    _m3_sec07="$(python3 -c \
      "import json; c={x['id']:x for x in json.load(open('$ROOT/m3.json'))['checks']}; print(c['SEC-07']['verdict'])" \
      2>/dev/null || echo "")"
  fi
  if [ "$_m3_sec07" != "FAIL" ]; then
    mut_ok "M3 SEC-07 cleared: verdict='$_m3_sec07' not FAIL — DETECTED"
  else
    mut_no "M3 SEC-07: mutation NOT detected (still FAIL)"
  fi
fi
rm -rf "$MUTDIR"

# --- M4: Disable ZIP inflation (return empty string instead of inflated XML) ---
# Expected: ZIP bog exec-on gives false PASS → T10 detects.
# The mutation clears the decoded xml in the bounded-read path so no attribute
# is ever found; exec_on bog must give PASS instead of FAIL.
MUTDIR="$(mktemp -d)"
cp -a "$SUT_DIR/." "$MUTDIR/"
sed -i 's/xml = data\.decode("utf-8", "replace")/xml = ""  # MUTANT-M4/' \
  "$MUTDIR/niagara_security_audit.py"
if ! python3 -m py_compile "$MUTDIR/niagara_security_audit.py" 2>/dev/null; then
  mut_no "M4 ZIP inflation disabled: mutant failed py_compile"
elif cmp -s "$ORIG_PY" "$MUTDIR/niagara_security_audit.py"; then
  mut_no "M4 ZIP inflation disabled: sed had no effect (pattern not found)"
else
  _m4_exit=0
  python3 "$MUTDIR/niagara_security_audit.py" \
    "$FIXTURES/secure-home" \
    --station "$FIXTURES/bogs/bog-exec-on.zip" \
    --output "$ROOT/m4.json" 2>/dev/null || _m4_exit=$?
  _m4_sec08=""
  if [ -f "$ROOT/m4.json" ]; then
    _m4_sec08="$(python3 -c \
      "import json; c={x['id']:x for x in json.load(open('$ROOT/m4.json'))['checks']}; print(c['SEC-08']['verdict'])" \
      2>/dev/null || echo "")"
  fi
  if [ "$_m4_sec08" != "FAIL" ]; then
    mut_ok "M4 ZIP inflation disabled: SEC-08='$_m4_sec08' not FAIL — DETECTED"
  else
    mut_no "M4 ZIP inflation disabled: mutation NOT detected (still FAIL)"
  fi
fi
rm -rf "$MUTDIR"

# --- M5: Force encoded=False always (ext-key bog never PASS) ---
# Expected: ext-key ZIP gives FAIL instead of PASS → T13 detects
MUTDIR="$(mktemp -d)"
cp -a "$SUT_DIR/." "$MUTDIR/"
sed -i 's/encoded = val not in .*$/encoded = False  # MUTANT-M5/' \
  "$MUTDIR/niagara_security_audit.py"
if ! python3 -m py_compile "$MUTDIR/niagara_security_audit.py" 2>/dev/null; then
  mut_no "M5 enc-key inverted: mutant failed py_compile"
elif cmp -s "$ORIG_PY" "$MUTDIR/niagara_security_audit.py"; then
  mut_no "M5 enc-key inverted: sed had no effect (pattern not found)"
else
  _m5_exit=0
  python3 "$MUTDIR/niagara_security_audit.py" \
    "$FIXTURES/secure-home" \
    --station "$FIXTURES/bogs/bog-ext-key.zip" \
    --output "$ROOT/m5.json" 2>/dev/null || _m5_exit=$?
  _m5_sec12=""
  if [ -f "$ROOT/m5.json" ]; then
    _m5_sec12="$(python3 -c \
      "import json; c={x['id']:x for x in json.load(open('$ROOT/m5.json'))['checks']}; print(c['SEC-12']['verdict'])" \
      2>/dev/null || echo "")"
  fi
  if [ "$_m5_sec12" != "PASS" ]; then
    mut_ok "M5 enc-key inverted: SEC-12='$_m5_sec12' not PASS — DETECTED"
  else
    mut_no "M5 enc-key inverted: mutation NOT detected (still PASS)"
  fi
fi
rm -rf "$MUTDIR"

# --- M6: SEC-06 absent dir treated as PASS (return [] instead of None) ---
# Expected: insecure-home (no licenses/) gives SEC-06=PASS instead of NA → T17 detects
MUTDIR="$(mktemp -d)"
cp -a "$SUT_DIR/." "$MUTDIR/"
sed -i 's/return None  # absent\/unreadable dir/return []  # MUTANT-M6/' \
  "$MUTDIR/niagara_security_audit.py"
if ! python3 -m py_compile "$MUTDIR/niagara_security_audit.py" 2>/dev/null; then
  mut_no "M6 SEC-06 absent→PASS: mutant failed py_compile"
elif cmp -s "$ORIG_PY" "$MUTDIR/niagara_security_audit.py"; then
  mut_no "M6 SEC-06 absent→PASS: sed had no effect (pattern not found)"
else
  _m6_exit=0
  python3 "$MUTDIR/niagara_security_audit.py" \
    "$FIXTURES/insecure-home" --output "$ROOT/m6.json" 2>/dev/null || _m6_exit=$?
  _m6_sec06=""
  if [ -f "$ROOT/m6.json" ]; then
    _m6_sec06="$(python3 -c \
      "import json; c={x['id']:x for x in json.load(open('$ROOT/m6.json'))['checks']}; print(c['SEC-06']['verdict'])" \
      2>/dev/null || echo "")"
  fi
  if [ "$_m6_sec06" != "NA" ]; then
    mut_ok "M6 SEC-06 absent→PASS: verdict='$_m6_sec06' not NA — DETECTED"
  else
    mut_no "M6 SEC-06 absent→PASS: mutation NOT detected (still NA)"
  fi
fi
rm -rf "$MUTDIR"

# --- M7: --station missing treated same as not-given (collapse observed strings) ---
# Expected: missing station file gives same message as not-provided → T18 detects
MUTDIR="$(mktemp -d)"
cp -a "$SUT_DIR/." "$MUTDIR/"
sed -i 's/_bog_fmt = .not_found./_bog_fmt = "not_provided"  # MUTANT-M7/' \
  "$MUTDIR/niagara_security_audit.py"
if ! python3 -m py_compile "$MUTDIR/niagara_security_audit.py" 2>/dev/null; then
  mut_no "M7 missing→same-as-not-given: mutant failed py_compile"
elif cmp -s "$ORIG_PY" "$MUTDIR/niagara_security_audit.py"; then
  mut_no "M7 missing→same-as-not-given: sed had no effect (pattern not found)"
else
  _m7_exit=0
  python3 "$MUTDIR/niagara_security_audit.py" \
    "$FIXTURES/secure-home" \
    --station "$ROOT/nonexistent-m7.bog" \
    --output "$ROOT/m7.json" 2>/dev/null || _m7_exit=$?
  _m7_obs=""
  if [ -f "$ROOT/m7.json" ]; then
    _m7_obs="$(python3 -c \
      "import json; c={x['id']:x for x in json.load(open('$ROOT/m7.json'))['checks']}; print(c['SEC-08'].get('observed',''))" \
      2>/dev/null || echo "")"
  fi
  _not_provided="not checked (no --station config.bog provided)"
  if [ "$_m7_obs" = "$_not_provided" ]; then
    mut_ok "M7 missing→not-given: observed collapsed to not-provided message — DETECTED"
  else
    mut_no "M7 missing→not-given: mutation NOT detected (observed='$_m7_obs')"
  fi
fi
rm -rf "$MUTDIR"

# --- M8: Trailing slash not stripped (symlink bypass survives) ---
# Expected: "sym-home/" is accepted without exit 2 → T19 detects
MUTDIR="$(mktemp -d)"
cp -a "$SUT_DIR/." "$MUTDIR/"
sed -i 's/home = home\.rstrip(os\.sep) or os\.sep/home = home  # MUTANT-M8/' \
  "$MUTDIR/niagara_security_audit.py"
if ! python3 -m py_compile "$MUTDIR/niagara_security_audit.py" 2>/dev/null; then
  mut_no "M8 trailing-slash not stripped: mutant failed py_compile"
elif cmp -s "$ORIG_PY" "$MUTDIR/niagara_security_audit.py"; then
  mut_no "M8 trailing-slash not stripped: sed had no effect (pattern not found)"
else
  _m8_exit=0
  python3 "$MUTDIR/niagara_security_audit.py" \
    "$ROOT/sym-home/" --output "$ROOT/m8.json" 2>/dev/null || _m8_exit=$?
  if [ "$_m8_exit" -ne 2 ]; then
    mut_ok "M8 trailing-slash bypass: exit $_m8_exit (not 2) — DETECTED"
  else
    mut_no "M8 trailing-slash bypass: mutation NOT detected (still exits 2)"
  fi
fi
rm -rf "$MUTDIR"

# --- M9: sec05_covered=True in the absent-blacklist branch ---
# Expected: absent blacklist gives SEC-05=PASS instead of FAIL → T21 detects
MUTDIR="$(mktemp -d)"
cp -a "$SUT_DIR/." "$MUTDIR/"
sed -i 's/sec05_covered = False$/sec05_covered = True  # MUTANT-M9/' \
  "$MUTDIR/niagara_security_audit.py"
if ! python3 -m py_compile "$MUTDIR/niagara_security_audit.py" 2>/dev/null; then
  mut_no "M9 sec05_covered=True: mutant failed py_compile"
elif cmp -s "$ORIG_PY" "$MUTDIR/niagara_security_audit.py"; then
  mut_no "M9 sec05_covered=True: sed had no effect (pattern not found)"
else
  _m9_exit=0
  python3 "$MUTDIR/niagara_security_audit.py" \
    "$FIXTURES/insecure-home" --output "$ROOT/m9.json" 2>/dev/null || _m9_exit=$?
  _m9_sec05=""
  if [ -f "$ROOT/m9.json" ]; then
    _m9_sec05="$(python3 -c \
      "import json; c={x['id']:x for x in json.load(open('$ROOT/m9.json'))['checks']}; print(c['SEC-05']['verdict'])" \
      2>/dev/null || echo "")"
  fi
  if [ "$_m9_sec05" != "FAIL" ]; then
    mut_ok "M9 sec05_covered=True: verdict='$_m9_sec05' not FAIL — DETECTED"
  else
    mut_no "M9 sec05_covered=True: mutation NOT detected (still FAIL)"
  fi
fi
rm -rf "$MUTDIR"

# --- M10: lic_hits ignored (SEC-06 never fires FAIL) ---
# Mutation: replace "FAIL" if lic_hits else "PASS", with "PASS",  (comma preserved)
# → valid Python syntax; always returns clean "PASS" verdict.
# Expected: lic-hit-home with dev license gives SEC-06="PASS" instead of "FAIL" → DETECTED.
# Assertion uses == "PASS" (not != "FAIL") to confirm the mutant produces a well-formed
# "PASS" verdict rather than a malformed implicit-concatenation string.
MUTDIR="$(mktemp -d)"
cp -a "$SUT_DIR/." "$MUTDIR/"
sed -i 's/"FAIL" if lic_hits else "PASS",/"PASS",  # MUTANT-M10/' \
  "$MUTDIR/niagara_security_audit.py"
if ! python3 -m py_compile "$MUTDIR/niagara_security_audit.py" 2>/dev/null; then
  mut_no "M10 lic_hits ignored: mutant failed py_compile"
elif cmp -s "$ORIG_PY" "$MUTDIR/niagara_security_audit.py"; then
  mut_no "M10 lic_hits ignored: sed had no effect (pattern not found)"
else
  _m10_exit=0
  python3 "$MUTDIR/niagara_security_audit.py" \
    "$FIXTURES/lic-hit-home" --output "$ROOT/m10.json" 2>/dev/null || _m10_exit=$?
  _m10_sec06=""
  if [ -f "$ROOT/m10.json" ]; then
    _m10_sec06="$(python3 -c \
      "import json; c={x['id']:x for x in json.load(open('$ROOT/m10.json'))['checks']}; print(c['SEC-06']['verdict'])" \
      2>/dev/null || echo "")"
  fi
  if [ "$_m10_sec06" = "PASS" ]; then
    mut_ok "M10 lic_hits ignored: verdict='PASS' (not FAIL) — DETECTED"
  else
    mut_no "M10 lic_hits ignored: mutation NOT detected (verdict='$_m10_sec06', expected 'PASS')"
  fi
fi
rm -rf "$MUTDIR"

# --- M11: Wildcard unsigned check disabled (SEC-15 never fires FAIL) ---
# Expected: modules-wild-home gives SEC-15=PASS instead of FAIL → T23 detects
MUTDIR="$(mktemp -d)"
cp -a "$SUT_DIR/." "$MUTDIR/"
sed -i 's/risk = len(wild_uns) > 0/risk = False  # MUTANT-M11/' \
  "$MUTDIR/niagara_security_audit.py"
if ! python3 -m py_compile "$MUTDIR/niagara_security_audit.py" 2>/dev/null; then
  mut_no "M11 wildcard-unsigned disabled: mutant failed py_compile"
elif cmp -s "$ORIG_PY" "$MUTDIR/niagara_security_audit.py"; then
  mut_no "M11 wildcard-unsigned disabled: sed had no effect (pattern not found)"
else
  _m11_exit=0
  python3 "$MUTDIR/niagara_security_audit.py" \
    "$FIXTURES/modules-wild-home" --output "$ROOT/m11.json" 2>/dev/null || _m11_exit=$?
  _m11_sec15=""
  if [ -f "$ROOT/m11.json" ]; then
    _m11_sec15="$(python3 -c \
      "import json; c={x['id']:x for x in json.load(open('$ROOT/m11.json'))['checks']}; print(c['SEC-15']['verdict'])" \
      2>/dev/null || echo "")"
  fi
  if [ "$_m11_sec15" != "FAIL" ]; then
    mut_ok "M11 wildcard-unsigned disabled: verdict='$_m11_sec15' not FAIL — DETECTED"
  else
    mut_no "M11 wildcard-unsigned disabled: mutation NOT detected (still FAIL)"
  fi
fi
rm -rf "$MUTDIR"

# --- M12: bounded bog read guard removed (zip-bomb site 1) ---
# Mutation: `if len(data) > _MAX_BOG_INFLATE:` → `if False:` so oversized bog
# is NOT truncated; `xml` becomes the full large string with no bog attributes.
# Expected: T24 asserts MANUAL but the mutant gives PASS → DETECTED.
MUTDIR="$(mktemp -d)"
cp -a "$SUT_DIR/." "$MUTDIR/"
sed -i 's/if len(data) > _MAX_BOG_INFLATE:/if False:  # MUTANT-M12/' \
  "$MUTDIR/niagara_security_audit.py"
if ! python3 -m py_compile "$MUTDIR/niagara_security_audit.py" 2>/dev/null; then
  mut_no "M12 bog bounded-read removed: mutant failed py_compile"
elif cmp -s "$ORIG_PY" "$MUTDIR/niagara_security_audit.py"; then
  mut_no "M12 bog bounded-read removed: sed had no effect (pattern not found)"
else
  _m12_exit=0
  python3 "$MUTDIR/niagara_security_audit.py" \
    "$FIXTURES/secure-home" \
    --station "$FIXTURES/bogs/bog-large.zip" \
    --output "$ROOT/m12.json" 2>/dev/null || _m12_exit=$?
  _m12_sec08=""
  if [ -f "$ROOT/m12.json" ]; then
    _m12_sec08="$(python3 -c \
      "import json; c={x['id']:x for x in json.load(open('$ROOT/m12.json'))['checks']}; print(c['SEC-08']['verdict'])" \
      2>/dev/null || echo "")"
  fi
  if [ "$_m12_sec08" != "MANUAL" ]; then
    mut_ok "M12 bog guard removed: SEC-08='$_m12_sec08' not MANUAL — DETECTED"
  else
    mut_no "M12 bog guard removed: mutation NOT detected (still MANUAL)"
  fi
fi
rm -rf "$MUTDIR"

# --- M13: bounded module.xml read guard removed (zip-bomb site 2) ---
# Mutation: `if len(xml_data) > _MAX_MODULE_XML:` → `if False:` so oversized
# module.xml JAR is NOT skipped; the wildcard KeyRingPermission is found.
# Expected: T25 asserts SEC-15=PASS but the mutant gives FAIL → DETECTED.
MUTDIR="$(mktemp -d)"
cp -a "$SUT_DIR/." "$MUTDIR/"
sed -i 's/if len(xml_data) > _MAX_MODULE_XML:/if False:  # MUTANT-M13/' \
  "$MUTDIR/niagara_security_audit.py"
if ! python3 -m py_compile "$MUTDIR/niagara_security_audit.py" 2>/dev/null; then
  mut_no "M13 module.xml guard removed: mutant failed py_compile"
elif cmp -s "$ORIG_PY" "$MUTDIR/niagara_security_audit.py"; then
  mut_no "M13 module.xml guard removed: sed had no effect (pattern not found)"
else
  _m13_exit=0
  python3 "$MUTDIR/niagara_security_audit.py" \
    "$FIXTURES/jar-bomb-home" --output "$ROOT/m13.json" 2>/dev/null || _m13_exit=$?
  _m13_sec15=""
  if [ -f "$ROOT/m13.json" ]; then
    _m13_sec15="$(python3 -c \
      "import json; c={x['id']:x for x in json.load(open('$ROOT/m13.json'))['checks']}; print(c['SEC-15']['verdict'])" \
      2>/dev/null || echo "")"
  fi
  if [ "$_m13_sec15" != "PASS" ]; then
    mut_ok "M13 module.xml guard removed: SEC-15='$_m13_sec15' not PASS — DETECTED"
  else
    mut_no "M13 module.xml guard removed: mutation NOT detected (still PASS)"
  fi
fi
rm -rf "$MUTDIR"

pass=$((pass + MUT_PASS))
fail=$((fail + MUT_FAIL))
echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
