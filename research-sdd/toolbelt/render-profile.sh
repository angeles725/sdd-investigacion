#!/usr/bin/env bash
# render-profile.sh — install-time slot renderer for research-sdd shared
# doctrine sources (kit issue #993, WU1: per-model-family prompt profiles).
#
# Shared sources (SKILL.md, PROMPT-LOOP.md) mark swappable text as
# `<!-- slot:<id> -->...claude text...<!-- /slot -->`. METHODOLOGY.md never
# carries slots. render-profile.sh substitutes each marked span at INSTALL
# time — there is no runtime indirection; a rendered file is ordinary prose.
#
# Usage:
#   render-profile.sh <profile> <outdir>
#
#   profile "claude"   — sources are copied byte-identical (markers remain;
#                         they are HTML comments, invisible to readers).
#   any other profile  — every `<!-- slot:<id> -->...<!-- /slot -->` span is
#                         replaced by that id's body, read from
#                         research-sdd/profiles/<profile>.slots.md, and the
#                         marker comments themselves are stripped from the
#                         rendered output.
#
# The profile file holds ONLY `## slot:<id>` sections with bodies; any
# non-blank line outside a slot section is a hard error (propose-never-apply
# doctrine extended to renders: a malformed profile must never render).
#
# Kit-path invariant (documented, not just asserted): SKILL.md references
# PROMPT-LOOP.md only through the dynamically-resolved `$KIT/PROMPT-LOOP.md`
# form (see SKILL.md's "Resolving the kit path" section) — never a hardcoded
# relative link. render-profile.sh therefore does not need to rewrite that
# reference; it only needs to preserve the SAME relative layout between the
# rendered SKILL.md and the rendered PROMPT-LOOP.md that the source kit uses
# (skills/research-sdd/SKILL.md two levels below PROMPT-LOOP.md), so that a
# `$KIT` search rooted at the render output finds both files exactly as it
# would in the real kit. This is verified below, not merely assumed.
#
# Exit codes: 0 = rendered; 2 = validation error (unknown profile, orphan
# slot id, missing profile section, nested/unbalanced marker, free text in
# the profile file, zero markers found while the profile declares slots, or
# a missing source/argument).
#
# RSDD_KIT_DIR overrides kit-directory resolution (tests point this at a
# fixture tree so the REAL renderer runs unmodified against mutant sources).

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIT_DIR="${RSDD_KIT_DIR:-$(cd "$HERE/.." && pwd)}"

usage() {
  echo "usage: render-profile.sh <profile> <outdir>" >&2
}

if [ "$#" -ne 2 ]; then
  usage
  echo "FATAL: render-profile.sh — exactly 2 arguments required (got $#)" >&2
  exit 2
fi

PROFILE="$1"
OUTDIR="$2"

SKILL_REL="skills/research-sdd/SKILL.md"
LOOP_REL="PROMPT-LOOP.md"
METH_REL="METHODOLOGY.md"

SKILL_SRC="$KIT_DIR/$SKILL_REL"
LOOP_SRC="$KIT_DIR/$LOOP_REL"
METH_SRC="$KIT_DIR/$METH_REL"

for f in "$SKILL_SRC" "$LOOP_SRC" "$METH_SRC"; do
  [ -f "$f" ] || { echo "FATAL: render-profile.sh — source file not found: $f" >&2; exit 2; }
done

command -v python3 >/dev/null || { echo "FATAL: render-profile.sh requires python3" >&2; exit 2; }

install_rel() {
  local src="$1" rel="$2" outdir="$3"
  local destdir
  destdir="$(dirname "$outdir/$rel")"
  mkdir -p "$destdir" || { echo "FATAL: render-profile.sh — cannot create $destdir" >&2; exit 2; }
  cp "$src" "$outdir/$rel" || { echo "FATAL: render-profile.sh — copy failed: $src -> $outdir/$rel" >&2; exit 2; }
}

# ---------------------------------------------------------------------------
# profile "claude" — byte-identical copy, no profile file needed, no
# marker parsing at all.
# ---------------------------------------------------------------------------
if [ "$PROFILE" = "claude" ]; then
  install_rel "$SKILL_SRC" "$SKILL_REL" "$OUTDIR"
  install_rel "$LOOP_SRC" "$LOOP_REL" "$OUTDIR"
  install_rel "$METH_SRC" "$METH_REL" "$OUTDIR"
  echo "render-profile: profile='claude' — 3 file(s) copied byte-identical to $OUTDIR"
  exit 0
fi

# ---------------------------------------------------------------------------
# Any other profile — needs research-sdd/profiles/<profile>.slots.md.
# ---------------------------------------------------------------------------
PROFILE_FILE="$KIT_DIR/profiles/${PROFILE}.slots.md"
if [ ! -f "$PROFILE_FILE" ]; then
  echo "FATAL: unknown profile '$PROFILE' (no $PROFILE_FILE)" >&2
  exit 2
fi

mkdir -p "$OUTDIR" || { echo "FATAL: render-profile.sh — cannot create outdir: $OUTDIR" >&2; exit 2; }

python3 - "$PROFILE" "$OUTDIR" "$SKILL_SRC" "$SKILL_REL" "$LOOP_SRC" "$LOOP_REL" "$METH_SRC" "$METH_REL" "$PROFILE_FILE" <<'PYEOF'
import os
import re
import sys

profile, outdir, skill_src, skill_rel, loop_src, loop_rel, meth_src, meth_rel, profile_file = sys.argv[1:10]

SOURCES = [
    (skill_src, skill_rel),
    (loop_src, loop_rel),
    (meth_src, meth_rel),
]

TOKEN_RE = re.compile(r'<!--\s*slot:([A-Za-z0-9_-]+)\s*-->|<!--\s*/slot\s*-->')
HEADER_RE = re.compile(r'^##\s+slot:([A-Za-z0-9_-]+)\s*$')


def fatal(msg):
    sys.stderr.write("FATAL: " + msg + "\n")
    sys.exit(2)


def parse_profile_file(path):
    """## slot:<id> sections only. Any non-blank line outside a section is a
    hard error (free text). Returns {id: body}; body has its bounding blank
    lines stripped but internal formatting preserved verbatim."""
    text = open(path, encoding='utf-8').read()
    lines = text.split('\n')
    slots = {}
    current_id = None
    current_body = []
    saw_any_header = False
    for i, line in enumerate(lines):
        m = HEADER_RE.match(line)
        if m:
            if current_id is not None:
                slots[current_id] = '\n'.join(current_body).strip('\n')
            current_id = m.group(1)
            if current_id in slots:
                fatal(f"profile file {path!r} declares slot:{current_id} more than once (line {i + 1})")
            current_body = []
            saw_any_header = True
            continue
        if current_id is None:
            if line.strip() != '':  # GUARD-FREETEXT
                fatal(f"free text outside a slot section in {path!r} at line {i + 1}: {line!r}")
            continue
        current_body.append(line)
    if current_id is not None:
        slots[current_id] = '\n'.join(current_body).strip('\n')
    if not saw_any_header:
        fatal(f"profile file {path!r} has zero '## slot:<id>' sections")
    return slots


def find_spans(text, filename):
    """Balanced, non-nested (<!-- slot:id --> ... <!-- /slot -->) spans, in
    document order. Returns [(open_start, close_end, slot_id), ...]."""
    spans = []
    open_tok = None
    for tok in TOKEN_RE.finditer(text):
        if tok.group(1) is not None:
            if open_tok is not None:  # GUARD-NESTED
                fatal(f"nested slot marker in {filename} at offset {tok.start()} "
                      f"(already inside slot:{open_tok[1]})")
            open_tok = (tok.start(), tok.group(1), tok.end())
        else:
            if open_tok is None:  # GUARD-STRAYCLOSE
                fatal(f"unbalanced /slot marker in {filename} at offset {tok.start()} with no open slot")
            ostart, sid, _oend = open_tok
            spans.append((ostart, tok.end(), sid))
            open_tok = None
    if open_tok is not None:  # GUARD-UNCLOSED
        fatal(f"unclosed slot:{open_tok[1]} marker in {filename} (unbalanced — no matching /slot)")
    return spans


def render_file(path, rel, profile_slots, encountered):
    text = open(path, encoding='utf-8').read()
    spans = find_spans(text, rel)
    if not spans:
        return text
    out = []
    last = 0
    for ostart, oend, sid in spans:
        if sid not in profile_slots:  # GUARD-MISSING
            fatal(f"marker slot:{sid} in {rel} has no matching profile slot section (missing)")
        encountered.add(sid)
        out.append(text[last:ostart])
        out.append(profile_slots[sid])
        last = oend
    out.append(text[last:])
    return ''.join(out)


profile_slots = parse_profile_file(profile_file)
encountered = set()
rendered = {}
for src, rel in SOURCES:
    rendered[rel] = render_file(src, rel, profile_slots, encountered)

declared = set(profile_slots.keys())
orphans = declared - encountered
if orphans:  # GUARD-ORPHAN
    if not encountered:  # GUARD-ZERO
        fatal(f"zero slot markers found in sources (profile '{profile}' declares "
              f"{len(declared)} slot id(s): {', '.join(sorted(declared))})")
    fatal(f"orphan slot id(s) in profile '{profile}' (no marker found in sources): "
          f"{', '.join(sorted(orphans))}")

for rel, content in rendered.items():
    dest = os.path.join(outdir, rel)
    os.makedirs(os.path.dirname(dest) or '.', exist_ok=True)
    with open(dest, 'w', encoding='utf-8') as fh:
        fh.write(content)

# Kit-layout invariant (see the top-of-file comment): the rendered SKILL.md's
# relative path to the rendered PROMPT-LOOP.md must be unchanged from the
# source kit layout.
skill_out = os.path.join(outdir, skill_rel)
loop_out = os.path.join(outdir, loop_rel)
skill_to_loop = os.path.relpath(loop_out, os.path.dirname(skill_out))
src_skill_to_loop = os.path.relpath(loop_src, os.path.dirname(skill_src))
if skill_to_loop != src_skill_to_loop:
    fatal(f"kit layout drifted: rendered SKILL.md -> PROMPT-LOOP.md relative path is "
          f"{skill_to_loop!r}, source was {src_skill_to_loop!r}")

print(f"render-profile: profile='{profile}' - {len(SOURCES)} file(s) rendered, "
      f"{len(encountered)} slot substitution(s) ({', '.join(sorted(encountered))}) to {outdir}")
PYEOF
exit $?
