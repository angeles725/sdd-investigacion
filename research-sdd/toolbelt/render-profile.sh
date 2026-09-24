#!/usr/bin/env bash
# render-profile.sh — install-time slot renderer for research-sdd shared
# doctrine sources (kit issue #993, WU1: per-model-family prompt profiles).
#
# Shared sources (SKILL.md, PROMPT-LOOP.md) mark swappable text as
# `<!-- slot:<id> -->...claude text...<!-- /slot -->`. METHODOLOGY.md never
# carries slots (enforced below — exit 2 if it ever does). render-profile.sh
# substitutes each marked span at INSTALL time — there is no runtime
# indirection; a rendered file is ordinary prose.
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
#                         rendered output. Profile names must match
#                         `^[a-z0-9_-]+$` (rejects path traversal / case
#                         tricks before the name is ever used to build a
#                         filesystem path).
#
# The profile file holds ONLY `## slot:<id>` sections with non-empty bodies;
# any non-blank line outside a slot section, or an empty body, is a hard
# error (propose-never-apply doctrine extended to renders: a malformed
# profile must never render).
#
# Kit-path note (round-2 review correction — this claim was overstated in
# the first version): SKILL.md references PROMPT-LOOP.md only through the
# dynamically-resolved `$KIT/PROMPT-LOOP.md` form (see SKILL.md's "Resolving
# the kit path" section), so render-profile.sh does not need to rewrite that
# reference textually. It DOES preserve the source kit's relative layout
# (skills/research-sdd/SKILL.md two levels below PROMPT-LOOP.md) in the
# output, by construction — every rendered path is built from the same
# SKILL_REL/LOOP_REL/METH_REL constants as the source paths. That layout
# preservation is necessary but NOT sufficient for `$KIT/PROMPT-LOOP.md` to
# actually resolve for an agent reading the rendered SKILL.md: SKILL.md's
# own kit-path resolution order (launcher `Kit path:` line -> the
# `$RESEARCH_SDD_KIT` env var -> an `fd METHODOLOGY.md` filesystem search)
# has no reason to look inside a render's outdir unless something points it
# there. Making that happen is the installer's responsibility (kit issue
# #993 WU2: set `Kit path:` / `$RESEARCH_SDD_KIT` to the render output),
# not this renderer's.
#
# Safety: refuses (exit 2) to render into an outdir that equals, is inside,
# or contains KIT_DIR — rendering "general" onto the kit's own directory
# would strip the kit's own markers in place.
#
# Exit codes: 0 = rendered; 2 = validation error (bad argument count,
# invalid profile name, unknown profile, METHODOLOGY.md carrying a slot
# marker, an outdir/kit-dir containment conflict, orphan slot id, missing
# profile section, empty slot body, nested/unbalanced marker, a
# non-canonical-case marker, free text in the profile file, zero markers
# found while the profile declares slots, a missing source/argument, or an
# I/O error reading a source or profile file).
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

if ! [[ "$PROFILE" =~ ^[a-z0-9_-]+$ ]]; then
  echo "FATAL: render-profile.sh — invalid profile name '$PROFILE' (must match ^[a-z0-9_-]+\$)" >&2
  exit 2
fi

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

# METHODOLOGY.md must never carry a slot marker, for any profile (checked
# here, once, before either branch, so even a plain "claude" copy catches
# drift immediately rather than only when someone happens to render a
# non-claude profile). Case-insensitive on purpose: a wrong-case marker
# there is exactly as much a doctrine violation as a correctly-cased one.
if grep -qiE '<!--[[:space:]]*/?[[:space:]]*slot' "$METH_SRC"; then
  echo "FATAL: render-profile.sh — METHODOLOGY.md must never carry slot markers (found a slot-marker-shaped HTML comment in $METH_SRC)" >&2
  exit 2
fi

# Refuse to render into (or over) the kit's own source tree. realpath -m
# semantics via python3 (already a hard requirement) so this works even
# when OUTDIR does not exist yet.
OUTDIR_REAL="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$OUTDIR")"
KIT_REAL="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$KIT_DIR")"
if [ "$OUTDIR_REAL" = "$KIT_REAL" ]; then
  echo "FATAL: render-profile.sh — outdir equals the kit directory ($OUTDIR_REAL); refusing to render into the kit's own source tree" >&2
  exit 2
fi
case "$OUTDIR_REAL" in
  "$KIT_REAL"/*)
    echo "FATAL: render-profile.sh — outdir is inside the kit directory ($OUTDIR_REAL under $KIT_REAL); refusing to render into the kit's own source tree" >&2
    exit 2
    ;;
esac
case "$KIT_REAL" in
  "$OUTDIR_REAL"/*)
    echo "FATAL: render-profile.sh — outdir ($OUTDIR_REAL) contains the kit directory ($KIT_REAL); refusing to render into an ancestor of the kit's own source tree" >&2
    exit 2
    ;;
esac

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

# Marker syntax is deliberately case-SENSITIVE and exact: only these two
# forms are ever recognized as live markers.
TOKEN_RE = re.compile(r'<!--\s*slot:([A-Za-z0-9_-]+)\s*-->|<!--\s*/slot\s*-->')
HEADER_RE = re.compile(r'^##\s+slot:([A-Za-z0-9_-]+)\s*$')

# Case-insensitive "looks like a slot marker" scan (see check_marker_case
# below) — deliberately looser than TOKEN_RE so it also catches malformed-
# but-almost-right forms, not just wrong case.
LOOSE_MARKER_RE = re.compile(r'<!--\s*/?\s*slot(:[A-Za-z0-9_-]*)?\s*-->', re.IGNORECASE)


def fatal(msg):
    sys.stderr.write("FATAL: " + msg + "\n")
    sys.exit(2)


def read_text(path, what):
    """Centralized I/O-error handling: any OSError (permission, race,
    dangling symlink, ...) or UTF-8 decode failure becomes one clean FATAL
    exit-2 line here, never an uncaught traceback further down."""
    try:
        with open(path, encoding='utf-8') as fh:
            return fh.read()
    except OSError as e:
        fatal(f"cannot read {what} ({path!r}): {e.strerror or e}")
    except UnicodeDecodeError as e:
        fatal(f"cannot decode {what} ({path!r}) as UTF-8: {e}")


def _finalize_slot(slot_id, body_lines, header_line, path, slots):
    body = '\n'.join(body_lines).strip('\n')
    if not body.strip():  # GUARD-EMPTYBODY
        fatal(f"profile file {path!r} declares slot:{slot_id} with an empty body (header at line {header_line})")
    slots[slot_id] = body


def parse_profile_file(path):
    """## slot:<id> sections only, each with a non-empty body. Any non-blank
    line outside a slot section is a hard error (free text).

    A MISSING path returns {} rather than erroring (GUARD-MISSING-PROFILE
    below) — this is defensive-only, never exercised in normal operation:
    the bash wrapper's unknown-profile guard is the real enforcement point
    and always runs first, before python is ever invoked, for a genuinely
    unknown profile. The fallback exists so a mutation test can disable
    JUST that bash guard and observe a genuine (if wrong) render, instead
    of an unrelated Python crash masquerading as proof the guard mattered
    (kit CLAUDE.md #943 / issue-tracked: a crash must never count as a
    mutation-test bite)."""
    if not os.path.isfile(path):  # GUARD-MISSING-PROFILE (defensive only)
        return {}
    text = read_text(path, "profile file")
    lines = text.split('\n')
    slots = {}
    current_id = None
    current_header_line = 0
    current_body = []
    saw_any_header = False
    for i, line in enumerate(lines):
        m = HEADER_RE.match(line)
        if m:
            if current_id is not None:
                _finalize_slot(current_id, current_body, current_header_line, path, slots)
            current_id = m.group(1)
            current_header_line = i + 1
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
        _finalize_slot(current_id, current_body, current_header_line, path, slots)
    if not saw_any_header:
        fatal(f"profile file {path!r} has zero '## slot:<id>' sections")
    return slots


def check_marker_case(text, filename):
    """Any HTML comment that looks like a slot marker case-insensitively
    but is not EXACTLY the canonical lowercase form is rejected loudly here,
    rather than silently passing through as inert-looking but wrong prose
    into a rendered file — the false-negative direction of the kit's
    anti-silent-zero doctrine (CLAUDE.md #7): a near-miss marker nobody
    notices is worse than one that fails the build.

    Fence-awareness (documented limit, not implemented): this scan, like
    TOKEN_RE and find_spans below, is NOT code-fence-aware — unlike
    hotcore-budget.test.sh's mask_code_fences, render-profile.sh has no
    concept of a fenced code block. A real marker written as literal prose
    example text inside a ``` fence in SKILL.md or PROMPT-LOOP.md would be
    substituted (or, if near-miss-cased, would trip this very check)
    exactly like a live marker. Today neither source file contains a fenced
    example of marker syntax, so this is a latent limitation, not an active
    bug; if that ever changes, prefer describing marker syntax in prose
    without the literal `<!--`/`-->` delimiters over teaching this renderer
    to parse fences."""
    for m in LOOSE_MARKER_RE.finditer(text):
        span_text = m.group(0)
        if not TOKEN_RE.fullmatch(span_text):  # GUARD-MARKERCASE
            fatal(f"non-canonical slot marker in {filename} at offset {m.start()}: {span_text!r} "
                  f"(marker syntax is case-sensitive and exact: use '<!-- slot:<id> -->' / '<!-- /slot -->')")


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
    text = read_text(path, f"source file ({rel})")
    check_marker_case(text, rel)
    spans = find_spans(text, rel)
    if not spans:
        return text
    out = []
    last = 0
    for ostart, oend, sid in spans:
        if sid not in profile_slots:  # GUARD-MISSING
            fatal(f"marker slot:{sid} in {rel} has no matching profile slot section (missing)")
        body = profile_slots.get(sid, '')
        encountered.add(sid)
        out.append(text[last:ostart])
        out.append(body)
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

# GUARD-ZERO is a strict mathematical SUBSET of GUARD-ORPHAN, not an
# independently-triggerable condition: "encountered is empty while declared
# is non-empty" implies "orphans == declared" (every declared id is
# trivially unmatched when NOTHING was matched anywhere), so GUARD-ZERO can
# only ever be reached through the `if orphans:` branch already being true.
# It exists purely to give the all-or-nothing case ("nothing in any source
# ever matched any declared slot") a more specific, actionable message than
# the general orphan listing — not as a second, separately-disablable
# safety check. Disabling GUARD-ZERO alone, leaving GUARD-ORPHAN intact,
# therefore can never produce a passing render on its own: the outer orphan
# check still refuses (with the less-specific message). A mutation test
# that wants an observable "wrong render" here has to disable both
# conditions together, as one unit — see render-profile.test.sh's
# teeth-zero-and-orphan for that combined proof.
if orphans:  # GUARD-ORPHAN
    if not encountered:  # GUARD-ZERO (documented subset of GUARD-ORPHAN, see above)
        fatal(f"zero slot markers found in sources (profile '{profile}' declares "
              f"{len(declared)} slot id(s): {', '.join(sorted(declared))})")
    fatal(f"orphan slot id(s) in profile '{profile}' (no marker found in sources): "
          f"{', '.join(sorted(orphans))}")

for rel, content in rendered.items():
    dest = os.path.join(outdir, rel)
    try:
        os.makedirs(os.path.dirname(dest) or '.', exist_ok=True)
        with open(dest, 'w', encoding='utf-8') as fh:
            fh.write(content)
    except OSError as e:
        fatal(f"cannot write rendered output ({dest!r}): {e.strerror or e}")

print(f"render-profile: profile='{profile}' - {len(SOURCES)} file(s) rendered, "
      f"{len(encountered)} slot substitution(s) ({', '.join(sorted(encountered))}) to {outdir}")
PYEOF
exit $?
