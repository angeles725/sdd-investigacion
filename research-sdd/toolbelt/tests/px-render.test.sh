#!/usr/bin/env bash
# Test suite for px-render.sh (Niagara N4 Px renderer -> self-contained HTML)
# TDD: tests written before implementation.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../px-render.sh"

[ -x "$SUT" ] || { echo "FATAL: SUT not found or not executable: $SUT" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 not found" >&2; exit 2; }

pass=0; fail=0
ok(){ echo "  PASS  $1"; pass=$((pass+1)); }
no(){ echo "  FAIL  $1"; fail=$((fail+1)); }

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
# Fixtures are generated into the TEMP root, never into the live tests/fixtures dir (kit issue #1299
# item 6, CLAUDE.md section 8): the kit-tree guard only tolerates identical-byte rewrites.
FIXTURES="$ROOT/fixtures/px-render"
mkdir -p "$FIXTURES" || { echo "FATAL: cannot create $FIXTURES" >&2; exit 2; }

# ---------------------------------------------------------------------------
# Build committed fixtures (idempotent for images; always rewrite XML).
# All text is English; no client paths or site tokens (§9).
# ---------------------------------------------------------------------------
python3 - "$FIXTURES" <<'PY'
import os, sys, base64

out = sys.argv[1]

PNG_1x1 = base64.b64decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=='
)

def write(p, content, mode='w'):
    os.makedirs(os.path.dirname(p), exist_ok=True)
    if mode == 'wb':
        with open(p, 'wb') as f:
            f.write(content)
    else:
        with open(p, 'w', encoding='utf-8') as f:
            f.write(content)

# valid.px: Label + ImageButton + Picture with file:^ image reference (3 widgets)
write(os.path.join(out, 'valid.px'), """\
<?xml version="1.0" encoding="UTF-8"?>
<px version="1.0"><content><ScrollPane>
<CanvasPane name="cv" viewSize="400.0,300.0">
<Label layout="10.0,10.0,200.0,30.0" text="Room 1" font="bold 18.0pt Arial"/>
<ImageButton layout="10.0,50.0,60.0,20.0" text="Auto"/>
<Picture layout="10.0,80.0,40.0,40.0" image="file:^images/on.png"/>
</CanvasPane></ScrollPane></content></px>
""")

# no-canvas.px: valid XML but no CanvasPane element -> exit 1
write(os.path.join(out, 'no-canvas.px'), """\
<?xml version="1.0" encoding="UTF-8"?>
<px version="1.0"><content><label text="no canvas here"/></content></px>
""")

# bad-xml.px: malformed XML -> exit 1
write(os.path.join(out, 'bad-xml.px'), b'<?xml version="1.0"?>\n<px><unclosed', 'wb')

# shared/images/on.png and off.png: 1x1 transparent PNG
write(os.path.join(out, 'shared', 'images', 'on.png'), PNG_1x1, 'wb')
write(os.path.join(out, 'shared', 'images', 'off.png'), PNG_1x1, 'wb')
PY

# ---------------------------------------------------------------------------
# T1: valid .px -> exit 0; HTML correct (canvas size, MOCK label, data URI
#     via CSS class, Room 1 text, font-size, Auto button); stderr widgets>=3
# ---------------------------------------------------------------------------
_t1_exit=0
_t1_stderr="$ROOT/t1.stderr"
"$SUT" "$FIXTURES/valid.px" \
  --shared "$FIXTURES/shared" \
  --out "$ROOT/t1.html" \
  2>"$_t1_stderr" || _t1_exit=$?
if [ "$_t1_exit" -eq 0 ] && [ -f "$ROOT/t1.html" ]; then
  if python3 - "$ROOT/t1.html" "$_t1_stderr" <<'PY'
import sys, re
html = open(sys.argv[1]).read()
stderr = open(sys.argv[2]).read()
# canvas size from viewSize="400.0,300.0"
assert 'width:400px' in html, f"canvas width not found: {html[:300]}"
assert 'height:300px' in html, f"canvas height not found"
# MOCK label (English only)
assert 'MOCK' in html, f"MOCK label not in HTML"
accented_form = 'R' + chr(0xC9) + 'PLICA'
assert accented_form not in html, "Spanish-accented replica form must not appear"
# data:image embedded once (deduplication: CSS class approach)
assert 'data:image/png;base64,' in html, "no embedded image in CSS"
assert html.count('data:image/png;base64,') == 1, \
    f"data URI appears {html.count('data:image/png;base64,')} times (expected 1)"
# Label text and font
assert 'Room 1' in html, "Label text not found"
assert 'font-size:18px' in html, "Label font-size not found"
# ImageButton text
assert 'Auto' in html, "ImageButton text not found"
# stderr summary: widgets_rendered >= 3
m = re.search(r'widgets_rendered=(\d+)', stderr)
assert m and int(m.group(1)) >= 3, \
    f"widgets_rendered must be >=3 in stderr; got: {stderr!r}"
# stderr: shared= always printed
assert 'shared=' in stderr, f"shared= not in stderr summary: {stderr!r}"
PY
  then
    ok "T1 valid render: exit 0, HTML correct (canvas 400x300, MOCK, data URI in CSS, widgets_rendered>=3)"
  else
    no "T1 valid render: exit 0 but HTML/stderr validation failed"
  fi
else
  no "T1 valid render: expected exit 0 + HTML file, got exit $_t1_exit"
fi

# ---------------------------------------------------------------------------
# T2: symlink input -> exit 2, no HTML produced
# ---------------------------------------------------------------------------
ln -sf "$FIXTURES/valid.px" "$ROOT/sym-input.px"
_t2_exit=0
"$SUT" "$ROOT/sym-input.px" \
  --shared "$FIXTURES/shared" \
  --out "$ROOT/t2.html" \
  2>/dev/null || _t2_exit=$?
if [ "$_t2_exit" -eq 2 ] && [ ! -f "$ROOT/t2.html" ]; then
  ok "T2 symlink input: exit 2, no HTML"
else
  no "T2 symlink input: expected exit 2 + no HTML, got exit $_t2_exit"
fi

# ---------------------------------------------------------------------------
# T3: absent input -> exit 2, no HTML produced
# ---------------------------------------------------------------------------
_t3_exit=0
"$SUT" "$ROOT/no-such.px" --out "$ROOT/t3.html" 2>/dev/null || _t3_exit=$?
if [ "$_t3_exit" -eq 2 ] && [ ! -f "$ROOT/t3.html" ]; then
  ok "T3 absent input: exit 2, no HTML"
else
  no "T3 absent input: expected exit 2 + no HTML, got exit $_t3_exit"
fi

# ---------------------------------------------------------------------------
# T4: no CanvasPane found -> exit 1
# ---------------------------------------------------------------------------
_t4_exit=0
"$SUT" "$FIXTURES/no-canvas.px" --out "$ROOT/t4.html" 2>/dev/null || _t4_exit=$?
if [ "$_t4_exit" -eq 1 ]; then
  ok "T4 no CanvasPane: exit 1"
else
  no "T4 no CanvasPane: expected exit 1, got $_t4_exit"
fi

# ---------------------------------------------------------------------------
# T5: bad XML -> exit 1 (ET.ParseError; no traceback on stderr)
# ---------------------------------------------------------------------------
_t5_stderr="$ROOT/t5.stderr"
_t5_exit=0
"$SUT" "$FIXTURES/bad-xml.px" --out "$ROOT/t5.html" 2>"$_t5_stderr" || _t5_exit=$?
if [ "$_t5_exit" -eq 1 ]; then
  if ! grep -q "Traceback" "$_t5_stderr" 2>/dev/null; then
    ok "T5 bad XML: exit 1, no traceback on stderr"
  else
    no "T5 bad XML: exit 1 but Python traceback leaked to stderr"
  fi
else
  no "T5 bad XML: expected exit 1, got $_t5_exit"
fi

# ---------------------------------------------------------------------------
# T6: --out to a symlink target -> exit 2, victim file not overwritten
# ---------------------------------------------------------------------------
echo "victim-content" > "$ROOT/victim.txt"
ln -sf "$ROOT/victim.txt" "$ROOT/out_sym.html"
_t6_exit=0
"$SUT" "$FIXTURES/valid.px" \
  --shared "$FIXTURES/shared" \
  --out "$ROOT/out_sym.html" \
  2>/dev/null || _t6_exit=$?
_victim_ok=0
[ "$(cat "$ROOT/victim.txt" 2>/dev/null)" = "victim-content" ] && _victim_ok=1
if [ "$_t6_exit" -eq 2 ] && [ "$_victim_ok" -eq 1 ]; then
  ok "T6 output symlink: exit 2, victim not overwritten"
else
  no "T6 output symlink: expected exit 2 + victim intact, got exit $_t6_exit (victim_ok=$_victim_ok)"
fi

# ---------------------------------------------------------------------------
# T7: --out to a pre-existing file -> exit 2 (O_CREAT|O_EXCL guard)
# ---------------------------------------------------------------------------
echo "existing" > "$ROOT/pre_existing.html"
_t7_exit=0
"$SUT" "$FIXTURES/valid.px" \
  --shared "$FIXTURES/shared" \
  --out "$ROOT/pre_existing.html" \
  2>/dev/null || _t7_exit=$?
if [ "$_t7_exit" -eq 2 ]; then
  ok "T7 pre-existing output: exit 2 (O_CREAT|O_EXCL refused)"
else
  no "T7 pre-existing output: expected exit 2, got $_t7_exit"
fi

# ---------------------------------------------------------------------------
# T8: containment escape (file:^../secret.txt) -> asset NOT embedded,
#     assets_blocked >= 1 in stderr; exit 0 (render succeeds, asset skipped)
# ---------------------------------------------------------------------------
mkdir -p "$ROOT/c8/shared/images"
cp "$FIXTURES/shared/images/on.png" "$ROOT/c8/shared/images/"
printf 'SECRET-DATA-XYZ\n' > "$ROOT/c8/secret.txt"

python3 - "$ROOT/c8/escape.px" <<'PY'
import sys
path = sys.argv[1]
with open(path, 'w', encoding='utf-8') as f:
    f.write("""\
<?xml version="1.0" encoding="UTF-8"?>
<px version="1.0"><content><ScrollPane>
<CanvasPane name="cv" viewSize="200.0,100.0">
<Label layout="0,0,100,20" text="safe-label"/>
<Picture layout="0,20,40,40" image="file:^../secret.txt"/>
</CanvasPane></ScrollPane></content></px>
""")
PY

_t8_stderr="$ROOT/t8.stderr"
_t8_exit=0
"$SUT" "$ROOT/c8/escape.px" \
  --shared "$ROOT/c8/shared" \
  --out "$ROOT/t8.html" \
  2>"$_t8_stderr" || _t8_exit=$?
if [ "$_t8_exit" -eq 0 ] && [ -f "$ROOT/t8.html" ]; then
  if python3 - "$ROOT/t8.html" "$_t8_stderr" <<'PY'
import sys, re, base64
html = open(sys.argv[1]).read()
stderr = open(sys.argv[2]).read()
assert 'SECRET-DATA-XYZ' not in html, "containment BREACH: secret text in HTML"
secret_b64 = base64.b64encode(b'SECRET-DATA-XYZ\n').decode()
assert secret_b64 not in html, \
    f"containment BREACH: base64 of secret ({secret_b64!r}) in HTML"
m = re.search(r'assets_blocked=(\d+)', stderr)
assert m and int(m.group(1)) >= 1, \
    f"assets_blocked must be >= 1 in stderr; got: {stderr!r}"
PY
  then
    ok "T8 containment escape: secret not embedded, assets_blocked>=1 in stderr"
  else
    no "T8 containment escape: exit 0 but validation failed (containment breach or wrong stderr)"
  fi
else
  no "T8 containment escape: expected exit 0 + HTML, got exit $_t8_exit"
fi

# ---------------------------------------------------------------------------
# T9: oversized image (> 8 MiB cap) -> skipped; assets_oversized >= 1 in
#     stderr; exit 0 (render succeeds, oversized asset not embedded)
# ---------------------------------------------------------------------------
mkdir -p "$ROOT/c9/shared/images"
python3 -c "import sys; sys.stdout.buffer.write(b'X'*(9*1024*1024))" \
  > "$ROOT/c9/shared/images/huge.png"

python3 - "$ROOT/c9/oversized.px" <<'PY'
import sys
path = sys.argv[1]
with open(path, 'w', encoding='utf-8') as f:
    f.write("""\
<?xml version="1.0" encoding="UTF-8"?>
<px version="1.0"><content><ScrollPane>
<CanvasPane name="cv" viewSize="200.0,100.0">
<Label layout="0,0,100,20" text="ok"/>
<Picture layout="0,20,100,80" image="file:^images/huge.png"/>
</CanvasPane></ScrollPane></content></px>
""")
PY

_t9_stderr="$ROOT/t9.stderr"
_t9_exit=0
"$SUT" "$ROOT/c9/oversized.px" \
  --shared "$ROOT/c9/shared" \
  --out "$ROOT/t9.html" \
  2>"$_t9_stderr" || _t9_exit=$?
if [ "$_t9_exit" -eq 0 ] && [ -f "$ROOT/t9.html" ]; then
  if python3 - "$ROOT/t9.html" "$_t9_stderr" <<'PY'
import sys, re
html = open(sys.argv[1]).read()
stderr = open(sys.argv[2]).read()
assert len(html) < 1024 * 1024, \
    f"HTML too large ({len(html)} bytes) -- oversized image may have been embedded"
m = re.search(r'assets_oversized=(\d+)', stderr)
assert m and int(m.group(1)) >= 1, \
    f"assets_oversized must be >= 1 in stderr; got: {stderr!r}"
PY
  then
    ok "T9 oversized image: skipped (HTML small), assets_oversized>=1 in stderr"
  else
    no "T9 oversized image: exit 0 but validation failed"
  fi
else
  no "T9 oversized image: expected exit 0 + HTML, got exit $_t9_exit"
fi

# ---------------------------------------------------------------------------
# T10: XSS guard -- malicious font attribute is sanitized before output.
#      A crafted px with entity-encoded font breakout must NOT produce
#      unescaped HTML injection in the style attribute.
# ---------------------------------------------------------------------------
python3 - "$ROOT/xss.px" <<'PY'
import sys
path = sys.argv[1]
# Font value that, if unescaped, would break out of a style attribute
# and inject an img tag: size becomes '1"><img/src=x/onerror=alert(2)>'
with open(path, 'w', encoding='utf-8') as f:
    f.write("""\
<?xml version="1.0" encoding="UTF-8"?>
<px version="1.0"><content><ScrollPane>
<CanvasPane name="cv" viewSize="200.0,100.0">
<Label layout="0,0,100,20" text="hello"
 font="bold 1&quot;&gt;&lt;img/src=x/onerror=alert(2)&gt;pt Arial"/>
</CanvasPane></ScrollPane></content></px>
""")
PY

_t10_exit=0
"$SUT" "$ROOT/xss.px" --out "$ROOT/t10.html" 2>/dev/null || _t10_exit=$?
if [ "$_t10_exit" -eq 0 ] && [ -f "$ROOT/t10.html" ]; then
  if python3 - "$ROOT/t10.html" <<'PY'
import sys, html as html_mod
content = open(sys.argv[1]).read()
# The raw XSS payload must not appear unescaped anywhere in the HTML
payload = '"><img/src=x/onerror=alert(2)>'
assert payload not in content, \
    f"XSS BREACH: raw payload found in output HTML"
# font-size must not contain anything other than digits
import re
for m in re.finditer(r'font-size:([^;]+);', content):
    sz = m.group(1)
    assert re.fullmatch(r'[0-9]+px', sz), \
        f"font-size contains non-digit chars after sanitization: {sz!r}"
PY
  then
    ok "T10 XSS font guard: payload not in HTML, font-size digits-only"
  else
    no "T10 XSS font guard: XSS payload found or non-digit font-size in HTML"
  fi
else
  no "T10 XSS font guard: expected exit 0 + HTML, got exit $_t10_exit"
fi

# ---------------------------------------------------------------------------
# T11: no --shared, no shared/ ancestor -> file:^ refs NOT embedded,
#      assets_needs_shared >= 1 in stderr; exit 0 (render succeeds).
# ---------------------------------------------------------------------------
mkdir -p "$ROOT/c11"
printf 'NO-SHARED-SECRET\n' > "$ROOT/c11/secret.txt"

python3 - "$ROOT/c11/no-shared.px" <<'PY'
import sys
path = sys.argv[1]
with open(path, 'w', encoding='utf-8') as f:
    f.write("""\
<?xml version="1.0" encoding="UTF-8"?>
<px version="1.0"><content><ScrollPane>
<CanvasPane name="cv" viewSize="200.0,100.0">
<Label layout="0,0,100,20" text="label"/>
<Picture layout="0,20,100,80" image="file:^secret.txt"/>
</CanvasPane></ScrollPane></content></px>
""")
PY

_t11_stderr="$ROOT/t11.stderr"
_t11_exit=0
# Explicitly NO --shared; ROOT/c11/ has no 'shared' ancestor
"$SUT" "$ROOT/c11/no-shared.px" \
  --out "$ROOT/t11.html" \
  2>"$_t11_stderr" || _t11_exit=$?
if [ "$_t11_exit" -eq 0 ] && [ -f "$ROOT/t11.html" ]; then
  if python3 - "$ROOT/t11.html" "$_t11_stderr" <<'PY'
import sys, re, base64
html = open(sys.argv[1]).read()
stderr = open(sys.argv[2]).read()
# secret content must not appear
assert 'NO-SHARED-SECRET' not in html, "no-shared BREACH: secret in HTML"
secret_b64 = base64.b64encode(b'NO-SHARED-SECRET\n').decode()
assert secret_b64 not in html, "no-shared BREACH: base64 secret in HTML"
# assets_needs_shared must be reported
m = re.search(r'assets_needs_shared=(\d+)', stderr)
assert m and int(m.group(1)) >= 1, \
    f"assets_needs_shared must be >=1; got: {stderr!r}"
# shared=none must appear in summary
assert 'shared=none' in stderr, \
    f"shared=none must appear in summary; got: {stderr!r}"
PY
  then
    ok "T11 no-shared: file:^ ref not embedded, assets_needs_shared>=1, shared=none"
  else
    no "T11 no-shared: exit 0 but validation failed"
  fi
else
  no "T11 no-shared: expected exit 0 + HTML, got exit $_t11_exit"
fi

# ---------------------------------------------------------------------------
# T12: amplification guard -- 50 refs to same image -> data URI appears
#      exactly ONCE in the HTML (deduplication via CSS class).
# ---------------------------------------------------------------------------
mkdir -p "$ROOT/c12/shared/images"
cp "$FIXTURES/shared/images/on.png" "$ROOT/c12/shared/images/ref.png"

python3 - "$ROOT/c12/amp.px" <<'PY'
import sys
path = sys.argv[1]
pics = '\n'.join(
    '<Picture layout="%d.0,%d.0,20.0,20.0" image="file:^images/ref.png"/>'
    % (i * 25, 0)
    for i in range(50)
)
with open(path, 'w', encoding='utf-8') as f:
    f.write(
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<px version="1.0"><content><ScrollPane>\n'
        '<CanvasPane name="cv" viewSize="1300.0,50.0">\n'
        + pics + '\n'
        '</CanvasPane></ScrollPane></content></px>\n'
    )
PY

_t12_exit=0
"$SUT" "$ROOT/c12/amp.px" \
  --shared "$ROOT/c12/shared" \
  --out "$ROOT/t12.html" \
  2>/dev/null || _t12_exit=$?
if [ "$_t12_exit" -eq 0 ] && [ -f "$ROOT/t12.html" ]; then
  if python3 - "$ROOT/t12.html" <<'PY'
import sys, re
html = open(sys.argv[1]).read()
count = html.count('data:image/png;base64,')
assert count == 1, \
    f"data URI appears {count} times (expected 1 -- deduplication failed)"
# All widget class references must have a corresponding CSS rule (no orphan ax class)
body_classes = set(re.findall(r'class="(ax\d+)"', html))
css_classes  = set(re.findall(r'\.(ax\d+)\{', html))
orphans = body_classes - css_classes
assert not orphans, \
    f"widget classes {orphans} have no CSS rule (dedup index corruption)"
PY
  then
    ok "T12 amplification guard: 50 refs, data URI once, all widget classes have CSS rules"
  else
    no "T12 amplification guard: data URI duplicated or orphan class references"
  fi
else
  no "T12 amplification guard: expected exit 0 + HTML, got exit $_t12_exit"
fi

# ---------------------------------------------------------------------------
# T13: malformed viewSize -> exit 1, no traceback on stderr
# ---------------------------------------------------------------------------
python3 - "$ROOT/bad-vs.px" <<'PY'
import sys
path = sys.argv[1]
with open(path, 'w', encoding='utf-8') as f:
    f.write("""\
<?xml version="1.0" encoding="UTF-8"?>
<px version="1.0"><content><ScrollPane>
<CanvasPane name="cv" viewSize="abc,def">
<Label layout="0,0,100,20" text="x"/>
</CanvasPane></ScrollPane></content></px>
""")
PY

_t13_stderr="$ROOT/t13.stderr"
_t13_exit=0
"$SUT" "$ROOT/bad-vs.px" --out "$ROOT/t13.html" 2>"$_t13_stderr" || _t13_exit=$?
if [ "$_t13_exit" -eq 1 ]; then
  if ! grep -q "Traceback" "$_t13_stderr" 2>/dev/null; then
    ok "T13 malformed viewSize: exit 1, no traceback on stderr"
  else
    no "T13 malformed viewSize: exit 1 but Python traceback on stderr"
  fi
else
  no "T13 malformed viewSize: expected exit 1, got $_t13_exit"
fi

# ---------------------------------------------------------------------------
# T14: unhandled widget tag -> skipped_by_tag reflects it in stderr; exit 0
# ---------------------------------------------------------------------------
python3 - "$ROOT/c14/unhandled.px" <<'PY'
import sys, os
path = sys.argv[1]
os.makedirs(os.path.dirname(path), exist_ok=True)
with open(path, 'w', encoding='utf-8') as f:
    f.write("""\
<?xml version="1.0" encoding="UTF-8"?>
<px version="1.0"><content><ScrollPane>
<CanvasPane name="cv" viewSize="200.0,100.0">
<Label layout="0,0,100,20" text="visible"/>
<GenericFieldEditor layout="0,30,100,20" name="gfe1"/>
<CheckBox layout="0,55,100,20" name="cb1"/>
</CanvasPane></ScrollPane></content></px>
""")
PY

_t14_stderr="$ROOT/t14.stderr"
_t14_exit=0
"$SUT" "$ROOT/c14/unhandled.px" \
  --out "$ROOT/t14.html" \
  2>"$_t14_stderr" || _t14_exit=$?
if [ "$_t14_exit" -eq 0 ] && [ -f "$ROOT/t14.html" ]; then
  if python3 - "$ROOT/t14.html" "$_t14_stderr" <<'PY'
import sys, re
html = open(sys.argv[1]).read()
stderr = open(sys.argv[2]).read()
# skipped_by_tag must reflect both unhandled tags
assert 'skipped_by_tag' in stderr, f"skipped_by_tag not in stderr: {stderr!r}"
assert 'GenericFieldEditor' in stderr, \
    f"GenericFieldEditor not in skipped_by_tag: {stderr!r}"
assert 'CheckBox' in stderr, f"CheckBox not in skipped_by_tag: {stderr!r}"
PY
  then
    ok "T14 skipped_by_tag: unhandled tags counted in stderr"
  else
    no "T14 skipped_by_tag: exit 0 but skipped_by_tag validation failed"
  fi
else
  no "T14 skipped_by_tag: expected exit 0 + HTML, got exit $_t14_exit"
fi

# ---------------------------------------------------------------------------
# T15: FIFO input -> exit 2 (S_ISREG guard)
# ---------------------------------------------------------------------------
_t15_fifo="$ROOT/input.fifo"
_t15_exit=0
mkfifo "$_t15_fifo"
# px-render opens with O_NONBLOCK so it does not block on the FIFO;
# S_ISREG check on the opened fd causes immediate exit 2.
"$SUT" "$_t15_fifo" --out "$ROOT/t15.html" 2>/dev/null || _t15_exit=$?
if [ "$_t15_exit" -eq 2 ] && [ ! -f "$ROOT/t15.html" ]; then
  ok "T15 FIFO input: exit 2 (S_ISREG guard)"
else
  no "T15 FIFO input: expected exit 2, got $_t15_exit"
fi

# ---------------------------------------------------------------------------
# T16: realpath dedup -- 5 different spellings of the same file -> 1 data URI
# ---------------------------------------------------------------------------
mkdir -p "$ROOT/c16/shared/images"
cp "$FIXTURES/shared/images/on.png" "$ROOT/c16/shared/images/on.png"

python3 - "$ROOT/c16/spellings.px" <<'PY'
import sys
path = sys.argv[1]
# 5 different textual spellings that all resolve to the same realpath
spellings = [
    "file:^images/on.png",
    "file:^images/./on.png",
    "file:^./images/on.png",
    "file:^images/../images/on.png",
    "file:^images/nonexistent/../on.png",
]
pics = "\n".join(
    '<Picture layout="%d.0,0.0,20.0,20.0" image="%s"/>' % (i * 25, s)
    for i, s in enumerate(spellings)
)
with open(path, "w", encoding="utf-8") as f:
    f.write(
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<px version="1.0"><content><ScrollPane>\n'
        '<CanvasPane name="cv" viewSize="200.0,50.0">\n'
        + pics + "\n"
        "</CanvasPane></ScrollPane></content></px>\n"
    )
PY

_t16_stderr="$ROOT/t16.stderr"
_t16_exit=0
"$SUT" "$ROOT/c16/spellings.px" \
  --shared "$ROOT/c16/shared" \
  --out "$ROOT/t16.html" \
  2>"$_t16_stderr" || _t16_exit=$?
if [ "$_t16_exit" -eq 0 ] && [ -f "$ROOT/t16.html" ]; then
  if python3 - "$ROOT/t16.html" "$_t16_stderr" <<'PY'
import sys, re
html = open(sys.argv[1]).read()
stderr = open(sys.argv[2]).read()
count = html.count('data:image/png;base64,')
assert count == 1, \
    f"realpath dedup failed: data URI appears {count} times (expected 1)"
m = re.search(r'assets_embedded=(\d+)', stderr)
assert m and int(m.group(1)) == 1, \
    f"assets_embedded must be 1; got: {stderr!r}"
PY
  then
    ok "T16 realpath dedup: 5 spellings of same file -> 1 data URI, assets_embedded=1"
  else
    no "T16 realpath dedup: dedup failed (multiple data URIs or assets_embedded > 1)"
  fi
else
  no "T16 realpath dedup: expected exit 0 + HTML, got exit $_t16_exit"
fi

# ---------------------------------------------------------------------------
# T17: family-only XSS guard -- font family breakout sanitized
# ---------------------------------------------------------------------------
python3 - "$ROOT/fam-xss.px" <<'PY'
import sys
path = sys.argv[1]
# Family value that would inject an event handler if not sanitized:
# raw: A"onmouseover="alert(1) (13.0pt size, family is the breakout)
with open(path, "w", encoding="utf-8") as f:
    f.write("""\
<?xml version="1.0" encoding="UTF-8"?>
<px version="1.0"><content><ScrollPane>
<CanvasPane name="cv" viewSize="200.0,100.0">
<Label layout="0,0,100,20" text="ok"
 font="13.0pt A&quot;onmouseover=&quot;alert(1)"/>
</CanvasPane></ScrollPane></content></px>
""")
PY

_t17_exit=0
"$SUT" "$ROOT/fam-xss.px" --out "$ROOT/t17.html" 2>/dev/null || _t17_exit=$?
if [ "$_t17_exit" -eq 0 ] && [ -f "$ROOT/t17.html" ]; then
  if python3 - "$ROOT/t17.html" <<'PY'
import sys
content = open(sys.argv[1]).read()
# The injection form has a double-quote breaking out of the style attribute
# (A"onmouseover="alert(1)) -- after _FAM_SAFE the " chars are removed.
# Check that neither the breakout quote-before-handler nor the assignment form
# appear; the sanitized fallout (Aonmouseoveralert1) inside a style value is safe.
assert '"onmouseover' not in content, \
    f"XSS BREACH: quoted onmouseover (attribute injection) found in HTML"
assert 'onmouseover=' not in content, \
    f"XSS BREACH: onmouseover= assignment found in HTML"
PY
  then
    ok "T17 family-only XSS: attribute-injection form stripped from font-family"
  else
    no "T17 family-only XSS: attribute-injection payload found in HTML"
  fi
else
  no "T17 family-only XSS: expected exit 0 + HTML, got exit $_t17_exit"
fi

# ---------------------------------------------------------------------------
# T18: total embed cap (assets_over_budget counter; truncated=true)
#      5 images each 7 MiB: first 4 embed (28 MiB < 32 MiB cap),
#      5th is over budget.
# ---------------------------------------------------------------------------
mkdir -p "$ROOT/c18/shared/images"
python3 - "$ROOT/c18/shared/images" "$ROOT/c18/budget.px" <<'PY'
import sys, os
img_dir = sys.argv[1]
px_path = sys.argv[2]
img_size = 7 * 1024 * 1024   # 7 MiB each (< 8 MiB per-image cap)
imgs = []
for i in range(5):
    name = "img%d.bin" % i
    path = os.path.join(img_dir, name)
    with open(path, "wb") as f:
        f.write(b"\x00" * img_size)
    imgs.append(name)
pics = "\n".join(
    '<Picture layout="%d.0,0.0,20.0,20.0" image="file:^images/%s"/>' % (i * 25, nm)
    for i, nm in enumerate(imgs)
)
with open(px_path, "w", encoding="utf-8") as f:
    f.write(
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<px version="1.0"><content><ScrollPane>\n'
        '<CanvasPane name="cv" viewSize="200.0,50.0">\n'
        + pics + "\n"
        "</CanvasPane></ScrollPane></content></px>\n"
    )
PY

_t18_stderr="$ROOT/t18.stderr"
_t18_exit=0
"$SUT" "$ROOT/c18/budget.px" \
  --shared "$ROOT/c18/shared" \
  --out "$ROOT/t18.html" \
  2>"$_t18_stderr" || _t18_exit=$?
if [ "$_t18_exit" -eq 0 ] && [ -f "$ROOT/t18.html" ]; then
  if python3 - "$ROOT/t18.html" "$_t18_stderr" <<'PY'
import sys, re
html = open(sys.argv[1]).read()
stderr = open(sys.argv[2]).read()
# At least one image should be over budget (not oversized -- distinct counter)
m_ob = re.search(r'assets_over_budget=(\d+)', stderr)
assert m_ob and int(m_ob.group(1)) >= 1, \
    f"assets_over_budget must be >= 1; got: {stderr!r}"
# oversized counter must be 0 (images are 7 MiB, under per-image cap of 8 MiB)
m_os = re.search(r'assets_oversized=(\d+)', stderr)
assert m_os and int(m_os.group(1)) == 0, \
    f"assets_oversized must be 0 (images are under per-image cap); got: {stderr!r}"
# truncated must be true (budget hit)
assert 'truncated=true' in stderr, \
    f"truncated=true must appear in stderr; got: {stderr!r}"
# total embedded bytes must not exceed cap
m_eb = re.search(r'assets_embed_bytes=(\d+)', stderr)
assert m_eb and int(m_eb.group(1)) <= 32 * 1024 * 1024, \
    f"embed bytes exceeded 32 MiB cap; got: {stderr!r}"
PY
  then
    ok "T18 total embed cap: over_budget>=1, oversized=0, truncated=true, bytes within cap"
  else
    no "T18 total embed cap: validation failed"
  fi
else
  no "T18 total embed cap: expected exit 0 + HTML, got exit $_t18_exit"
fi

# ---------------------------------------------------------------------------
# T19: --shared to non-existent path -> exit 2
# ---------------------------------------------------------------------------
_t19_exit=0
"$SUT" "$FIXTURES/valid.px" \
  --shared "$ROOT/no-such-dir-xyz" \
  --out "$ROOT/t19.html" \
  2>/dev/null || _t19_exit=$?
if [ "$_t19_exit" -eq 2 ] && [ ! -f "$ROOT/t19.html" ]; then
  ok "T19 --shared bad path: exit 2, no HTML"
else
  no "T19 --shared bad path: expected exit 2 + no HTML, got exit $_t19_exit"
fi

# T19b: --shared to a file (not a directory) -> exit 2
_t19b_exit=0
"$SUT" "$FIXTURES/valid.px" \
  --shared "$FIXTURES/valid.px" \
  --out "$ROOT/t19b.html" \
  2>/dev/null || _t19b_exit=$?
if [ "$_t19b_exit" -eq 2 ] && [ ! -f "$ROOT/t19b.html" ]; then
  ok "T19b --shared is a file: exit 2, no HTML"
else
  no "T19b --shared is a file: expected exit 2 + no HTML, got exit $_t19b_exit"
fi

# ---------------------------------------------------------------------------
# T20: stdout write error -> exit 2, no traceback
# ---------------------------------------------------------------------------
if [ -c /dev/full ]; then
  _t20_stderr="$ROOT/t20.stderr"
  _t20_exit=0
  "$SUT" "$FIXTURES/valid.px" \
    --shared "$FIXTURES/shared" \
    >/dev/full 2>"$_t20_stderr" || _t20_exit=$?
  if [ "$_t20_exit" -eq 2 ] && ! grep -q "Traceback" "$_t20_stderr" 2>/dev/null; then
    ok "T20 stdout write error: exit 2, no traceback"
  else
    no "T20 stdout write error: expected exit 2 no traceback, got exit $_t20_exit"
  fi
else
  echo "  SKIP  T20 stdout write error: /dev/full not available on this platform"
fi

# ---------------------------------------------------------------------------
# Summary (non-teeth path)
# ---------------------------------------------------------------------------
# Hermeticity (kit issue #1299 item 6): fixtures are built in $ROOT; a rewrite of anything under
# research-sdd/ is caught by the run-all kit-tree guard (no per-suite assertion: the live fixture dir
# no longer exists, so one would be vacuous).
if [ "${1:-}" != "--prove-teeth" ]; then
  echo "== $pass passed · $fail failed =="; [ "$fail" -eq 0 ]
  exit $?
fi

# ---------------------------------------------------------------------------
echo "-- teeth: px-render mutation controls --"
# ---------------------------------------------------------------------------
MUT_PASS=0; MUT_FAIL=0
mut_ok(){ echo "  PASS(mut)  $1"; MUT_PASS=$((MUT_PASS+1)); }
mut_no(){ echo "  FAIL(mut)  $1"; MUT_FAIL=$((MUT_FAIL+1)); }

# Shared helper (kit issue #1299): sourced ONLY on this branch, each function we call is checked.
# shellcheck source=lib/mutant.sh
. "$HERE/lib/mutant.sh" || { echo "FATAL: cannot source lib/mutant.sh" >&2; exit 2; }
for _fn in mutant_chain mutant_tooth; do
  declare -F "$_fn" >/dev/null || { echo "FATAL: lib/mutant.sh lacks $_fn" >&2; exit 2; }
done
export MUTANT_SYNTAX=none   # the mutants are Python; syntax is checked with ast.parse in mut_build

SUT_DIR="$(cd "$(dirname "$SUT")" && pwd)"
ORIG_PY="$SUT_DIR/px_render.py"
if [ ! -f "$ORIG_PY" ]; then
  echo "  FAIL(mut)  px_render.py not found: $ORIG_PY"
  echo "== $pass passed · $fail failed =="
  exit 1
fi
# Mutants live under $ROOT (a mktemp dir, removed by the single EXIT trap above), one dir each.
# Only the single mutated file is copied: px_render.py imports no sibling module and its one __file__
# use (the default organized/ root, px_render.py:200-206) resolves to an absent dir for original and
# mutant alike, and no tooth exercises module:// assets.
MUTBASE="$ROOT/mut"; mkdir -p "$MUTBASE"
MUTPY=""

# mut_build LABEL ID SED_EXPR... — builds $MUTBASE/ID/px_render.py through mutant_chain (empty,
# identical, dead-stage, placement refusals; every stage must change the SUT on its own) plus a
# Python syntax check. On refusal the tooth is counted ONCE here and never runs; returns 1.
mut_build(){
  local label="$1" id="$2"; shift 2
  MUTPY="$MUTBASE/$id/px_render.py"; mkdir -p "$MUTBASE/$id"
  if ! mutant_chain "$label" "$ORIG_PY" "$MUTPY" "$@"; then
    mut_no "$label: mutant refused by lib/mutant.sh (refusal counted here once; tooth not run)"; return 1
  fi
  if ! python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' "$MUTPY" 2>/dev/null; then
    mut_no "$label: mutant is not valid Python (refusal counted here once; tooth not run)"; return 1
  fi
}

# Typed facts printed for every run, computed from the SAME artifacts the base tests assert on
# (the rendered HTML and the stderr summary).
PX_FACTS='import sys, re, base64, os
hp, ep = sys.argv[1], sys.argv[2]
html = open(hp).read() if os.path.isfile(hp) else None
err = open(ep).read() if os.path.isfile(ep) else ""
print("HTML=" + ("present" if html is not None else "absent"))
h = html or ""
print("OUTHEAD=" + h[:8].replace("\n", " "))
print("B64SECRET=%d" % (base64.b64encode(b"SECRET-DATA-XYZ\n").decode() in h))
print("NOSHARED=%d" % ("NO-SHARED-SECRET" in h or base64.b64encode(b"NO-SHARED-SECRET\n").decode() in h))
print("PAYLOAD=%d" % ("\"><img/src=x/onerror=alert(2)>" in h))
print("FAMXSS=%d" % ("\"onmouseover" in h or "onmouseover=" in h))
print("URIS=%d" % h.count("data:image/png;base64,"))
print("ORPHAN=%d" % bool(set(re.findall(r"class=\"(ax\d+)\"", h)) - set(re.findall(r"\.(ax\d+)\{", h))))
def num(k):
    m = re.search(k + r"=(\d+)", err)
    return m.group(1) if m else "-1"
print("WIDGETS=" + num("widgets_rendered"))
print("OB=" + num("assets_over_budget"))
print("OSZ=" + num("assets_oversized"))
print("SKIPTAG=%d" % ("skipped_by_tag" in err))'

# Wrapper: PY INPUT SHARED SETUP FACTS_SCRIPT. Each run gets a FRESH output dir (removed by the
# wrapper's own trap); SETUP builds the per-run precondition (symlinked input, pre-existing output).
PX_WRAP='py="$1"; in="$2"; sh="$3"; setup="$4"; facts="$5"
o="$(mktemp -d)" || exit 99
trap "rm -rf \"$o\"" EXIT
case "$setup" in
  symlink) ln -s "$in" "$o/link.px"; in="$o/link.px" ;;
  preexist) echo existing > "$o/out.html" ;;
esac
args=("$py" "$in")
[ "$sh" = - ] || args+=(--shared "$sh")
python3 "${args[@]}" --out "$o/out.html" 2>"$o/err"; rc=$?
echo "RC=$rc"
python3 -c "$facts" "$o/out.html" "$o/err"
exit "$rc"'
# pt LABEL GOOD_RC BAD_RC [--good-has RE ...] -- INPUT SHARED SETUP
pt(){
  local label="$1" g="$2" b="$3"; shift 3
  local -a opts=()
  while [ "${1:-}" != -- ]; do opts+=("$1" "$2"); shift 2; done
  shift
  if mutant_tooth "$label" "$g" "$b" "$MUTPY" --orig "$ORIG_PY" "${opts[@]}" -- bash -c "$PX_WRAP" _ @SUT@ "$1" "$2" "$3" "$PX_FACTS"; then
    MUT_PASS=$((MUT_PASS+1))
  else
    MUT_FAIL=$((MUT_FAIL+1))
  fi
}

# M1: remove the input O_NOFOLLOW: a symlinked input is no longer refused
if mut_build "M1 input O_NOFOLLOW" M1 's/_IN_FLAGS = os\.O_RDONLY | _O_NOFOLLOW | _O_NONBLOCK | _O_CLOEXEC/_IN_FLAGS = os.O_RDONLY | _O_NONBLOCK | _O_CLOEXEC  # MUTANT-M1/'; then
  pt "M1 input O_NOFOLLOW" 2 0 --good-has '^HTML=absent$' --bad-has '^HTML=present$' \
    -- "$FIXTURES/valid.px" "$FIXTURES/shared" symlink
fi

# M2: remove the output O_EXCL: a pre-existing output file is no longer refused
if mut_build "M2 output O_EXCL" M2 's/_OUT_FLAGS = os\.O_WRONLY | os\.O_CREAT | os\.O_EXCL | _O_NOFOLLOW | _O_CLOEXEC/_OUT_FLAGS = os.O_WRONLY | os.O_CREAT | _O_CLOEXEC  # MUTANT-M2/'; then
  pt "M2 output O_EXCL" 2 0 --good-has '^OUTHEAD=existing$' --bad-lacks '^OUTHEAD=existing$' \
    -- "$FIXTURES/valid.px" "$FIXTURES/shared" preexist
fi

# M3: remove the containment check: the path-traversal escape is embedded
if mut_build "M3 containment" M3 's/if not self\._is_contained(candidate, self\.shared):/if False:  # MUTANT-M3/'; then
  pt "M3 containment" 0 0 --good-has '^B64SECRET=0$' --bad-has '^B64SECRET=1$' \
    -- "$ROOT/c8/escape.px" "$ROOT/c8/shared" none
fi

# M4: suppress the widgets_rendered counter: stderr reports 0
if mut_build "M4 widgets_rendered" M4 's/widgets_rendered += 1/pass  # MUTANT-M4/'; then
  pt "M4 widgets_rendered" 0 0 --good-has '^WIDGETS=[1-9]' --bad-has '^WIDGETS=0$' \
    -- "$FIXTURES/valid.px" "$FIXTURES/shared" none
fi

# M5: remove font sanitisation (both guards): the XSS payload appears unescaped
if mut_build "M5 XSS font guard" M5 \
  's/_FAM_SAFE = lambda fam:.*/_FAM_SAFE = lambda fam: fam  # MUTANT-M5/' \
  's/_SZ_SAFE  = lambda sz:.*/_SZ_SAFE  = lambda sz:  sz  # MUTANT-M5/'; then
  pt "M5 XSS font guard" 0 0 --good-has '^PAYLOAD=0$' --bad-has '^PAYLOAD=1$' \
    -- "$ROOT/xss.px" - none
fi

# M6: restore the grandparent fallback: a no-shared .px can embed a sibling secret
if mut_build "M6 no-shared fallback" M6 's/return None  # find_shared-no-ancestor/return os.path.dirname(os.path.abspath(px_path))  # MUTANT-M6/'; then
  pt "M6 no-shared fallback" 0 0 --good-has '^NOSHARED=0$' --bad-has '^NOSHARED=1$' \
    -- "$ROOT/c11/no-shared.px" - none
fi

# M7: suppress the skipped_by_tag accumulation: the counter never reaches stderr
if mut_build "M7 skipped_by_tag" M7 's/skipped_by_tag\[t\] = skipped_by_tag.get(t, 0) + 1/pass  # MUTANT-M7/'; then
  pt "M7 skipped_by_tag" 0 0 --good-has '^SKIPTAG=1$' --bad-has '^SKIPTAG=0$' \
    -- "$ROOT/c14/unhandled.px" - none
fi

# M8: remove the S_ISREG check: the char device /dev/null is no longer refused with exit 2; the
# mutant reads empty bytes and fails the XML parse with exit 1 instead.
if [ ! -c /dev/null ]; then
  mut_no "M8 S_ISREG: /dev/null not available on this platform"
elif mut_build "M8 S_ISREG" M8 's/if not _stat\.S_ISREG(st\.st_mode):/if False:  # MUTANT-M8/'; then
  pt "M8 S_ISREG" 2 1 --good-has '^HTML=absent$' --bad-has '^HTML=absent$' \
    -- /dev/null - none
fi

# M-AMP: disable the dedup in css_class(): a widget body class has no CSS rule
if mut_build "M-AMP amplification" MAMP 's/if real_key not in self\._cls_idx:.*$/if True:  # MUTANT-MAMP/'; then
  pt "M-AMP amplification" 0 0 --good-has '^ORPHAN=0$' --bad-has '^ORPHAN=1$' \
    -- "$ROOT/c12/amp.px" "$ROOT/c12/shared" none
fi

# M5a: remove family-only sanitisation (_SZ_SAFE intact): the font-family breakout appears
if mut_build "M5a family-only XSS" M5A 's/_FAM_SAFE = lambda fam:.*/_FAM_SAFE = lambda fam: fam  # MUTANT-M5A/'; then
  pt "M5a family-only XSS" 0 0 --good-has '^FAMXSS=0$' --bad-has '^FAMXSS=1$' \
    -- "$ROOT/fam-xss.px" - none
fi

# M-DEDUP: key the cache on the raw ref instead of the realpath: 5 spellings give 5 data URIs
if mut_build "M-DEDUP realpath" MDEDUP 's/real_key = os\.path\.realpath(path)/real_key = path  # MUTANT-MDEDUP/'; then
  pt "M-DEDUP realpath" 0 0 --good-has '^URIS=1$' --bad-has '^URIS=([2-9]|[0-9]{2,})$' \
    -- "$ROOT/c16/spellings.px" "$ROOT/c16/shared" none
fi

# M-BUDGET: count over-budget refusals as oversized: the distinct counters merge
if mut_build "M-BUDGET over_budget" MBUDGET 's/self\.over_budget\.append(ref)/self.oversized.append(ref)  # MUTANT-MBUDGET/'; then
  pt "M-BUDGET over_budget" 0 0 --good-has '^OB=[1-9]' --bad-has '^OB=0$' \
    -- "$ROOT/c18/budget.px" "$ROOT/c18/shared" none
fi

echo "== $pass passed · $fail failed =="
echo "== mut: $MUT_PASS passed · $MUT_FAIL failed =="
[ "$fail" -eq 0 ] && [ "$MUT_FAIL" -eq 0 ]
