#!/usr/bin/env python3
"""px-render — render a Niagara N4 Px (.px) as a self-contained HTML page.

A Px is Niagara Presentation XML: a CanvasPane (viewSize="W,H") holding
widgets positioned absolutely by layout="x,y,w,h".  Emits a self-contained
HTML page reproducing the screen, embedding referenced images as data: URIs.
Output is HTML to stdout or --out FILE.

SECURITY
  Every resolved asset path is realpath-contained under its allowed root.
  A ref like file:^../../etc/passwd is REFUSED (blocked, never embedded).
  Input opened with O_NOFOLLOW (symlink input -> exit 2).
  Output opened with O_CREAT|O_EXCL|O_NOFOLLOW (refuses pre-existing and
  symlink targets -> exit 2).
  Font family and size are sanitized before interpolation into style attributes
  (XSS guard).

IMAGE ORD FORMS
  file:^<rel>          resolves against the station's shared/ root.
                       --shared is REQUIRED; without it and without a
                       shared/-named ancestor the ref is skipped (not an error).
  module://<mod>/<rel> resolves against the organized/ corpus root

SHARED ROOT AUTO-DETECTION
  Walks up from the .px file's directory looking for a directory whose
  basename is exactly "shared".  If none is found and --shared is not given,
  file:^ assets are NOT embedded (counted as assets_needs_shared=N).

EXIT CODES
  0  rendered OK
  1  parse error / no CanvasPane / MemoryError during parse
  2  absent / unreadable / symlink / non-regular input; output guard failure

STDERR SUMMARY (always emitted after a successful render)
  px-render: widgets_rendered=N assets_embedded=N assets_missing=N
             assets_blocked=N assets_needs_shared=N assets_oversized=N
             assets_embed_bytes=N [skipped_by_tag={tag:N,...}]
             [skipped_no_layout=N] [truncated=true] shared=<root|none>

WIDGET COVERAGE (handles these CanvasPane child tags)
  Label, BoundLabel, Picture, ImageButton, BackButton
  All other tags are skipped and counted per-tag in the stderr summary.

  Coverage note from a 416-file corpus (414 parseable):
    Handled  -- Label:12599, BoundLabel:6051, Picture:2832, ImageButton:1750,
               BackButton:114  (~85% of total widget instances)
    Skipped  -- GenericFieldEditor:1908, CheckBox:509, EnumDropDown:320,
               Button:247, BorderPane:246, ...
    The skipped_by_tag field in the stderr summary reports any unhandled tags
    present in the rendered Px, so a partly-covered screen is visible.

KNOWN LIMITATION
  Nested CanvasPane elements (e.g. embedded sub-canvas widgets) are not
  recursively rendered; only the outermost CanvasPane is used.

DEMO STATE
  Widget bindings have no live station; ValueBinding ON/OFF state is derived
  deterministically from the relay ord (--on-ratio, --seed).  The output is
  clearly labeled MOCK and "demo state, not a live station" -- never presented
  as live data.
"""

import argparse
import base64
import hashlib
import html
import os
import re
import stat as _stat
import sys
import xml.etree.ElementTree as ET

# ---------------------------------------------------------------------------
# Caps
# ---------------------------------------------------------------------------
_MAX_PX_BYTES        = 16 * 1024 * 1024   # 16 MiB .px read cap
_MAX_ASSET_BYTES     =  8 * 1024 * 1024   #  8 MiB per embedded image
_MAX_EMBED_TOTAL     = 32 * 1024 * 1024   # 32 MiB total embedded asset bytes
_MAX_WIDGETS         =  4_000             # widget render cap

# ---------------------------------------------------------------------------
# Open-flag bundles (named constants so mutation tests can target them
# with a single-line sed substitution without breaking surrounding syntax).
# ---------------------------------------------------------------------------
_O_NOFOLLOW = getattr(os, "O_NOFOLLOW", 0)
_O_NONBLOCK = getattr(os, "O_NONBLOCK", 0)
_O_CLOEXEC  = getattr(os, "O_CLOEXEC",  0)

_IN_FLAGS = os.O_RDONLY | _O_NOFOLLOW | _O_NONBLOCK | _O_CLOEXEC
_OUT_FLAGS = os.O_WRONLY | os.O_CREAT | os.O_EXCL | _O_NOFOLLOW | _O_CLOEXEC

# ---------------------------------------------------------------------------
# XSS guards for font attribute values.
# Each is a named lambda so a single sed line can remove the sanitization
# (mutation target for test M5).
# ---------------------------------------------------------------------------
_FAM_SAFE = lambda fam: re.sub(r'[^A-Za-z0-9 _-]', '', fam) or 'Arial'
_SZ_SAFE  = lambda sz:  re.sub(r'[^0-9]', '', sz)  or '13'

# ---------------------------------------------------------------------------
# MIME map for asset embedding
# ---------------------------------------------------------------------------
_MIME = {
    "svg":  "image/svg+xml",
    "jpg":  "image/jpeg",
    "jpeg": "image/jpeg",
    "gif":  "image/gif",
    "png":  "image/png",
}

# Widget tags this renderer handles; others are counted but not rendered.
_HANDLED_TAGS = frozenset({"Label", "BoundLabel", "Picture", "ImageButton", "BackButton"})


# ---------------------------------------------------------------------------
# I/O helpers
# ---------------------------------------------------------------------------

def _read_input_bounded(path, cap):
    """Open path with _IN_FLAGS; validate S_ISREG; read at most cap+1 bytes.

    O_NOFOLLOW: reject symlinks (ELOOP).
    O_NONBLOCK: do not block on FIFOs/devices.
    fstat S_ISREG: reject non-regular files after open.
    Raises OSError on any I/O violation.
    """
    fd = None
    try:
        fd = os.open(path, _IN_FLAGS)
        st = os.fstat(fd)
        if not _stat.S_ISREG(st.st_mode):
            raise OSError("not a regular file (FIFO or device): %s" % path)
        data = os.read(fd, cap + 1)
    finally:
        if fd is not None:
            try:
                os.close(fd)
            except OSError:
                pass
    return data


def _open_output_new(path):
    """Open path write-only for a new file; refuse symlinks and pre-existing.

    O_CREAT|O_EXCL: refuse pre-existing files.
    O_NOFOLLOW: refuse symlinks.
    Returns an open file descriptor.
    """
    return os.open(path, _OUT_FLAGS, 0o600)


# ---------------------------------------------------------------------------
# Shared-root resolution
# ---------------------------------------------------------------------------

def find_shared(px_path, override=None):
    """Locate the station shared/ root used to resolve file:^ image ords.

    Walk up from the .px file's directory looking for a directory whose
    basename is exactly 'shared'.  Returns its realpath, or None if not found.

    With no --shared and no shared/-named ancestor, callers must NOT embed
    any file:^ asset (fail closed; count as assets_needs_shared).
    """
    if override:
        return os.path.realpath(override)
    d = os.path.dirname(os.path.abspath(px_path))
    for _ in range(8):
        if os.path.basename(d) == "shared" and os.path.isdir(d):
            return os.path.realpath(d)
        parent = os.path.dirname(d)
        if parent == d:
            break
        d = parent
    # No directory named "shared" found walking up; fail closed.
    return None  # find_shared-no-ancestor


# ---------------------------------------------------------------------------
# Asset resolution with realpath containment
# ---------------------------------------------------------------------------

class Assets:
    """Resolve and embed Px image ords with containment enforcement and read cap.

    Invariants:
      - Every resolved path is realpath-contained under its allowed root before
        any read attempt.  Paths escaping the root are recorded as blocked.
      - Asset files are opened with O_NOFOLLOW (symlinks inside the root
        are refused and counted as missing, not blocked).
      - Images exceeding _MAX_ASSET_BYTES are skipped and counted as oversized.
      - Total embedded bytes are capped at _MAX_EMBED_TOTAL.
      - Each unique asset URI is stored once; widgets reference it by CSS class
        index (deduplication guard against output amplification).
    """

    def __init__(self, shared, organized=None):
        self.shared = os.path.realpath(shared) if shared else ""
        organized_default = os.path.join(
            os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
            "organized",
        )
        self.organized = (
            os.path.realpath(organized) if organized
            else os.path.realpath(organized_default)
        )
        self._cache      = {}   # realpath -> data URI (unique URIs only)
        self._cls_idx    = {}   # realpath -> CSS class index
        self._ref_to_key = {}   # ref -> realpath (populated by datauri)
        self.missing     = []
        self.blocked     = []
        self.oversized   = []   # refs exceeding per-image cap
        self.over_budget = []   # refs refused by total embed cap
        self.needs_shared = []  # file:^ refs skipped because shared is None
        self._embed_bytes = 0   # total raw decoded bytes embedded

    # -- containment check --------------------------------------------------

    def _is_contained(self, path, root):
        """True iff realpath(path) is at or under realpath(root)."""
        if not root:
            return False
        try:
            real = os.path.realpath(path)
            real_root = os.path.realpath(root)
            return real == real_root or real.startswith(real_root + os.sep)
        except (OSError, ValueError):
            return False

    # -- module:// candidate paths ------------------------------------------

    def _module_candidates(self, mod, rel):
        if self.shared:
            yield os.path.join(self.shared, "px", mod, rel)
        if self.organized:
            for kind in ("wb", "rt", "ux"):
                yield os.path.join(
                    self.organized, mod, "%s-%s" % (mod, kind), "extracted", rel
                )
            import glob as _glob
            for p in _glob.glob(
                os.path.join(self.organized, mod, "*", "extracted",
                             _glob.escape(rel))
            ):
                yield p

    # -- resolve ord to path ------------------------------------------------

    def resolve(self, ref):
        """Resolve a Px image ord to (path, status).

        status is 'ok', 'missing', 'blocked', or 'needs_shared'.
        """
        if not ref:
            return None, "missing"

        if ref.startswith("file:^"):
            if not self.shared:
                return None, "needs_shared"
            rel = ref[len("file:^"):]
            candidate = os.path.join(self.shared, rel)
            # Containment check BEFORE existence check (avoids TOCTOU on
            # path-traversal attempts; also works for non-existent paths).
            if not self._is_contained(candidate, self.shared):
                return None, "blocked"
            if not os.path.isfile(candidate):
                return None, "missing"
            return candidate, "ok"

        if ref.startswith("module://"):
            path = ref[len("module://"):]
            seg = path.split("/", 1)
            if len(seg) != 2:
                return None, "missing"
            mod, rel = seg
            for candidate in self._module_candidates(mod, rel):
                if not os.path.isfile(candidate):
                    continue
                if not (self._is_contained(candidate, self.shared)
                        or self._is_contained(candidate, self.organized)):
                    return None, "blocked"
                return candidate, "ok"
            return None, "missing"

        return None, "missing"

    # -- read, base64-encode, and register asset ----------------------------

    def datauri(self, ref):
        """Return a data: URI for the asset, or None if unavailable."""
        path, status = self.resolve(ref)
        if status == "needs_shared":
            self.needs_shared.append(ref)
            return None
        if status == "blocked":
            self.blocked.append(ref)
            return None
        if path is None:
            self.missing.append(ref)
            return None

        real_key = os.path.realpath(path)
        self._ref_to_key[ref] = real_key
        if real_key in self._cache:
            return self._cache[real_key]

        # Open with O_NOFOLLOW: refuse symlinks even inside the shared root.
        try:
            fd = os.open(path, os.O_RDONLY | _O_NOFOLLOW | _O_CLOEXEC)
            try:
                data = os.read(fd, _MAX_ASSET_BYTES + 1)
            finally:
                os.close(fd)
        except OSError:
            self.missing.append(ref)
            return None

        # Per-image cap: refuse files exceeding the per-asset limit.
        if len(data) > _MAX_ASSET_BYTES:
            self.oversized.append(ref)
            return None

        # Total embed cap: check AFTER reading the actual byte count.
        if self._embed_bytes + len(data) > _MAX_EMBED_TOTAL:
            self.over_budget.append(ref)
            return None

        ext = path.rsplit(".", 1)[-1].lower() if "." in path else ""
        mime = _MIME.get(ext, "image/png")
        uri = "data:%s;base64,%s" % (mime, base64.b64encode(data).decode())
        self._cache[real_key] = uri
        self._embed_bytes += len(data)
        return uri

    def css_class(self, ref):
        """Return CSS class index for ref (assigning if new), or None if unavailable."""
        uri = self.datauri(ref)
        if uri is None:
            return None
        real_key = self._ref_to_key.get(ref, ref)
        if real_key not in self._cls_idx:   # dedup guard — M-AMP target
            self._cls_idx[real_key] = len(self._cls_idx)
        return self._cls_idx[real_key]

    def css_block(self):
        """Return a <style> block emitting each asset URI exactly once."""
        lines = []
        for real_key, idx in self._cls_idx.items():
            uri = self._cache.get(real_key, "")
            lines.append(
                ".ax%d{background-image:url('%s');"
                "background-size:contain;background-repeat:no-repeat;"
                "background-position:center}" % (idx, uri)
            )
        return "\n".join(lines)


# ---------------------------------------------------------------------------
# Parsing helpers
# ---------------------------------------------------------------------------

def parse_layout(s):
    """Parse layout="x,y,w,h" -> (x, y, w, h) floats or None."""
    if not s:
        return None
    try:
        x, y, w, h = (float(v) for v in s.split(","))
        return x, y, w, h
    except ValueError:
        return None


def parse_font(s):
    """Parse font string 'bold 26.0pt Arial' -> (weight, size_str, family_str).

    Defaults: weight='normal', size='13', family='Arial'.
    Returned size and family are RAW strings; callers must apply _SZ_SAFE and
    _FAM_SAFE before interpolating into HTML attributes.
    """
    if not s:
        return ("normal", "13", "Arial")
    weight = "normal"
    toks = s.split()
    if toks and toks[0] in ("bold", "italic"):
        weight = toks[0]
        toks = toks[1:]
    size, fam = "13", "Arial"
    for tk in toks:
        if "pt" in tk:
            size = tk.replace("pt", "").split(".")[0]
        else:
            fam = tk
    return (weight, size, fam)


def relay_num(ord_):
    """Extract relay index from an ord string; handles $5b/$5d escaping for [ ]."""
    if not ord_:
        return None
    d = ord_.replace("$5b", "[").replace("$5d", "]")
    m = re.search(r"\[(\d+)\]", d)
    return int(m.group(1)) if m else None


# ---------------------------------------------------------------------------
# Renderer
# ---------------------------------------------------------------------------

def render(px_bytes, shared=None, on_ratio=0.7, seed=None,
           title=None, subtitle=None, organized=None, px_name="unknown"):
    """Render .px bytes to a self-contained HTML string.

    Returns (html_str, meta_dict) on success.
    Returns (None, None) when no CanvasPane is found.
    Raises ET.ParseError on malformed XML.
    Raises MemoryError when XML parse exceeds available memory.

    meta_dict keys:
      canvas             (width, height) ints
      widgets_rendered   count of rendered handled-tag widgets
      skipped_by_tag     {tag: count} for unhandled tags with a layout attr
      skipped_no_layout  count of widgets dropped for missing/malformed layout
      truncated          True when widget cap or total embed cap was hit
      assets_embedded    count of unique images embedded as data: URIs
      assets_embed_bytes total raw bytes embedded
      assets_missing     count of unresolvable or unreadable image refs
      assets_blocked     count of image refs refused by containment check
      assets_needs_shared count of file:^ refs skipped (no shared root)
      assets_oversized   count of images exceeding per-image cap
      assets_over_budget count of images refused by total embed cap
      shared_root        resolved shared/ root path or None
    """
    root_el = ET.fromstring(px_bytes)
    canvas = next((e for e in root_el.iter("CanvasPane")), None)
    if canvas is None:
        return None, None

    vs = canvas.get("viewSize", "1370.0,780.0")
    try:
        vw_s, vh_s = vs.split(",", 1)
        CW = int(float(vw_s))
        CH = int(float(vh_s))
        if not (0 < CW < 1_000_000) or not (0 < CH < 1_000_000):
            raise ValueError("viewSize out of range")
    except (ValueError, OverflowError) as e:
        raise ET.ParseError("malformed viewSize %r: %s" % (vs, e))

    A = Assets(shared or "", organized)
    tag_seed = seed or px_name
    truncated = False

    def relay_on(k):
        """Deterministic demo ON/OFF from relay index and seed."""
        if k is None:
            return True
        h = int(hashlib.md5(("%s:r%d" % (tag_seed, k)).encode()).hexdigest(), 16)
        return (h % 1000) / 1000.0 < on_ratio

    parts = []
    skipped_by_tag = {}
    skipped_no_layout = 0
    widgets_rendered = 0

    for e in canvas:
        # Widget cap
        if widgets_rendered >= _MAX_WIDGETS:
            truncated = True
            break

        lay = parse_layout(e.get("layout"))
        if not lay:
            skipped_no_layout += 1
            continue
        t = e.tag
        if t not in _HANDLED_TAGS:
            skipped_by_tag[t] = skipped_by_tag.get(t, 0) + 1
            continue

        x, y, w, h = lay
        base = (
            "position:absolute;left:%gpx;top:%gpx;width:%gpx;height:%gpx;"
            % (x, y, w, h)
        )

        if t == "Label":
            wt, sz_raw, fam_raw = parse_font(e.get("font"))
            sz  = _SZ_SAFE(sz_raw)
            fam = _FAM_SAFE(fam_raw)
            txt = html.unescape(e.get("text") or "")
            parts.append(
                '<div style="%sdisplay:flex;align-items:center;'
                'font-family:%s,Arial,sans-serif;font-weight:%s;font-size:%spx;'
                'color:#16233a;line-height:1.05;overflow:hidden;white-space:pre-wrap;">'
                "%s</div>"
                % (base, fam, wt, sz, html.escape(txt))
            )
            widgets_rendered += 1

        elif t == "Picture":
            img = e.get("image")
            vb = e.find("ValueBinding")
            ref = None
            if img:
                ref = img
            elif vb is not None:
                k = relay_num(vb.get("ord"))
                on = relay_on(k)
                kinds = [c.tag for c in vb]
                if "IBooleanToSimple" in kinds:
                    ib = vb.find("IBooleanToSimple")
                    tv = ib.find("Image[@name='trueValue']")
                    fv = ib.find("Image[@name='falseValue']")
                    if tv is not None and fv is not None:
                        ref = tv.get("value") if on else fv.get("value")
                elif "IStatusToSimple" in kinds:
                    st = vb.find("IStatusToSimple")
                    okref = st.find("Image[@name='ok']") if st is not None else None
                    if okref is not None and on:
                        ref = okref.get("value")
            if ref is not None:
                cls = A.css_class(ref)
                if cls is not None:
                    parts.append(
                        '<div class="ax%d" style="%s"></div>' % (cls, base)
                    )
                else:
                    parts.append(
                        '<div style="%sbackground:#e8ecf0;border:1px dashed #aab;" '
                        'title="image unavailable"></div>' % base
                    )
            else:
                parts.append(
                    '<div style="%sdisplay:grid;place-items:center;">'
                    '<span style="width:60%%;height:60%%;max-width:16px;'
                    "max-height:16px;border-radius:50%%;background:#9aa4ac;"
                    '"></span></div>' % base
                )
            widgets_rendered += 1

        elif t == "BoundLabel":
            vb = e.find("ValueBinding")
            blb = e.find("BoundLabelBinding")
            if vb is not None:
                k = relay_num(vb.get("ord"))
                on = relay_on(k)
                kinds = [c.tag for c in vb]
                ref = None
                if "IBooleanToSimple" in kinds:
                    ib = vb.find("IBooleanToSimple")
                    tv = ib.find("Image[@name='trueValue']")
                    fv = ib.find("Image[@name='falseValue']")
                    if tv is not None and fv is not None:
                        ref = tv.get("value") if on else fv.get("value")
                elif "IStatusToSimple" in kinds:
                    st = vb.find("IStatusToSimple")
                    okref = st.find("Image[@name='ok']") if st is not None else None
                    if okref is not None and on:
                        ref = okref.get("value")
                if ref is not None:
                    cls = A.css_class(ref)
                    if cls is not None:
                        parts.append(
                            '<div class="ax%d" style="%s"></div>' % (cls, base)
                        )
                    else:
                        parts.append(
                            '<div style="%sdisplay:grid;place-items:center;">'
                            '<span style="width:60%%;height:60%%;max-width:16px;'
                            "max-height:16px;border-radius:50%%;background:#9aa4ac;"
                            '"></span></div>' % base
                        )
                else:
                    parts.append(
                        '<div style="%sdisplay:grid;place-items:center;">'
                        '<span style="width:60%%;height:60%%;max-width:16px;'
                        "max-height:16px;border-radius:50%%;background:#9aa4ac;"
                        '"></span></div>' % base
                    )
                widgets_rendered += 1
            else:
                leaf = ""
                if blb is not None:
                    ordv = blb.get("ord", "")
                    leaf = ordv.rstrip("/").split("/")[-1].split(":")[-1]
                parts.append(
                    '<div style="%sdisplay:flex;align-items:center;'
                    "justify-content:center;font-family:Arial,sans-serif;"
                    "font-size:12px;color:#16233a;background:#eef1f5;"
                    "border:1px solid #cdd4de;border-radius:4px;"
                    'text-align:center;padding:2px;">%s</div>'
                    % (base, html.escape(leaf))
                )
                widgets_rendered += 1

        elif t == "ImageButton":
            txt = (e.get("text") or "").strip()
            if txt:
                parts.append(
                    '<div style="%sdisplay:flex;align-items:center;'
                    "justify-content:center;font-family:Arial,sans-serif;"
                    "font-size:11px;font-weight:600;color:#00123F;"
                    "background:#eef1f5;border:1px solid #cdd4de;"
                    'border-radius:4px;">%s</div>'
                    % (base, html.escape(txt))
                )
            else:
                parts.append('<div style="%s" title="control"></div>' % base)
            widgets_rendered += 1

        elif t == "BackButton":
            parts.append(
                '<div style="%sdisplay:grid;place-items:center;'
                'color:#00123F;font-size:20px;">&lsaquo;</div>' % base
            )
            widgets_rendered += 1

    body = "\n".join(parts)
    asset_css = A.css_block()
    name = px_name
    ttl = html.escape(title or ("Px replica: " + name))
    sub = html.escape(
        subtitle
        or (
            "MOCK — demo state, not a live station. "
            "Screen layout from Px file: " + name + "."
        )
    )
    out_html = (
        "<!DOCTYPE html>\n"
        '<html lang="en"><head>\n'
        '<meta charset="utf-8">\n'
        "<title>%s</title>\n"
        "<style>\n"
        ":root{color-scheme:light}\n"
        "body{margin:0;background:#0b1220;font-family:Arial,Helvetica,sans-serif;}\n"
        ".bar{background:#001D68;color:#fff;padding:10px 18px;font-size:13px;"
        "display:flex;gap:12px;align-items:center;}\n"
        ".bar b{font-weight:700}"
        ".bar .tag{margin-left:auto;font-size:11px;background:#76B900;"
        "color:#0c1207;font-weight:700;border-radius:4px;padding:3px 8px;}\n"
        ".note{background:#e9edf3;color:#3a4453;font-size:12px;padding:8px 18px;"
        "border-bottom:1px solid #d2d8e2;}\n"
        ".stage{width:100%%;overflow:auto;background:#f4f2ec;}\n"
        ".canvas{position:relative;width:%dpx;height:%dpx;"
        "transform-origin:top left;background:#fff;}\n"
        "%s\n"
        "</style>\n</head><body>\n"
        '<div class="bar"><b>Px replica</b> '
        "(Niagara Workbench Px Editor) "
        '<span class="tag">MOCK</span></div>\n'
        '<div class="note">%s</div>\n'
        '<div class="stage"><div class="canvas" id="cv">\n%s\n</div></div>\n'
        "<script>function fit(){"
        "var cv=document.getElementById('cv');"
        "var w=cv.parentElement.clientWidth;"
        "var s=Math.min(1,w/%d);"
        "cv.style.transform='scale('+s+')';"
        "cv.parentElement.style.height=(%d*s)+'px';}\n"
        "window.addEventListener('resize',fit);fit();</script>\n"
        "</body></html>\n"
        % (ttl, CW, CH, asset_css, sub, body, CW, CH)
    )
    truncated = truncated or bool(A.over_budget)
    meta = {
        "canvas":              (CW, CH),
        "widgets_rendered":    widgets_rendered,
        "skipped_by_tag":      skipped_by_tag,
        "skipped_no_layout":   skipped_no_layout,
        "truncated":           truncated,
        "assets_embedded":     len(A._cache),
        "assets_embed_bytes":  A._embed_bytes,
        "assets_missing":      len(A.missing),
        "assets_blocked":      len(A.blocked),
        "assets_needs_shared": len(A.needs_shared),
        "assets_oversized":    len(A.oversized),
        "assets_over_budget":  len(A.over_budget),
        "shared_root":         A.shared or None,
    }
    return out_html, meta


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(
        description="Render a Niagara N4 Px (.px) as a self-contained HTML page."
    )
    ap.add_argument("px", help="path to .px file")
    ap.add_argument("--shared",
                    help="station shared/ root for file:^ assets; "
                         "auto-detected when a 'shared'-named ancestor exists, "
                         "otherwise file:^ refs are skipped (assets_needs_shared)")
    ap.add_argument("--organized",
                    help="organized/ corpus root for module:// assets (repo default if omitted)")
    ap.add_argument("--out",
                    help="output .html path; default: write HTML to stdout")
    ap.add_argument("--on-ratio", type=float, default=0.7,
                    help="demo fraction of relays ON (0.0-1.0, default 0.7)")
    ap.add_argument("--seed",
                    help="demo-state seed tag (default: px basename without extension)")
    ap.add_argument("--title",
                    help="page <title> text (default: 'Px replica: <basename>')")
    ap.add_argument("--subtitle",
                    help="note line displayed under the header bar")
    args = ap.parse_args()

    # -- --shared validation -------------------------------------------------
    if args.shared is not None and not os.path.isdir(args.shared):
        print(
            "px-render: --shared is not an existing directory: %s" % args.shared,
            file=sys.stderr,
        )
        sys.exit(2)

    # -- Input guard ---------------------------------------------------------
    try:
        data = _read_input_bounded(args.px, _MAX_PX_BYTES)
    except OSError as e:
        print("px-render: input error: %s" % e, file=sys.stderr)
        sys.exit(2)

    if len(data) > _MAX_PX_BYTES:
        print(
            "px-render: input exceeds %d-byte cap: %s" % (_MAX_PX_BYTES, args.px),
            file=sys.stderr,
        )
        sys.exit(2)

    px_name = os.path.splitext(os.path.basename(args.px))[0]
    shared = find_shared(args.px, args.shared)

    # -- Parse and render ----------------------------------------------------
    try:
        out_html, meta = render(
            data,
            shared=shared,
            on_ratio=args.on_ratio,
            seed=args.seed,
            title=args.title,
            subtitle=args.subtitle,
            organized=args.organized,
            px_name=px_name,
        )
    except ET.ParseError as e:
        print("px-render: XML parse error: %s" % e, file=sys.stderr)
        sys.exit(1)
    except MemoryError:
        print(
            "px-render: memory error during XML parse (file may be too large)",
            file=sys.stderr,
        )
        sys.exit(1)

    if meta is None:
        print("px-render: no CanvasPane found in %s" % args.px, file=sys.stderr)
        sys.exit(1)

    # -- §7 partial-render summary to stderr (always; never silent) ----------
    shared_label = meta["shared_root"] if meta["shared_root"] else "none"
    summary_fields = [
        "widgets_rendered=%d"    % meta["widgets_rendered"],
        "assets_embedded=%d"     % meta["assets_embedded"],
        "assets_missing=%d"      % meta["assets_missing"],
        "assets_blocked=%d"      % meta["assets_blocked"],
        "assets_needs_shared=%d" % meta["assets_needs_shared"],
        "assets_oversized=%d"    % meta["assets_oversized"],
        "assets_over_budget=%d"  % meta["assets_over_budget"],
        "assets_embed_bytes=%d"  % meta["assets_embed_bytes"],
    ]
    if meta["skipped_by_tag"]:
        parts_s = ",".join(
            "%s:%d" % (k, v)
            for k, v in sorted(meta["skipped_by_tag"].items(), key=lambda kv: -kv[1])
        )
        summary_fields.append("skipped_by_tag={%s}" % parts_s)
    if meta["skipped_no_layout"]:
        summary_fields.append("skipped_no_layout=%d" % meta["skipped_no_layout"])
    if meta["truncated"]:
        summary_fields.append("truncated=true")
    summary_fields.append("shared=%s" % shared_label)

    # -- Output --------------------------------------------------------------
    encoded = out_html.encode("utf-8")
    if args.out:
        try:
            fd = _open_output_new(args.out)
        except OSError as e:
            print("px-render: output error: %s" % e, file=sys.stderr)
            sys.exit(2)
        try:
            n = os.write(fd, encoded)
            if n != len(encoded):
                raise OSError("short write: %d of %d bytes" % (n, len(encoded)))
        except OSError as e:
            os.close(fd)
            try:
                os.unlink(args.out)
            except OSError:
                pass
            print("px-render: write error: %s" % e, file=sys.stderr)
            sys.exit(2)
        os.close(fd)
    else:
        try:
            sys.stdout.buffer.write(encoded)
            sys.stdout.buffer.flush()
        except (BrokenPipeError, OSError):
            # Redirect stdout to /dev/null so Python's own flush-at-exit
            # does not override our exit code (CPython exits 120 when its
            # shutdown flush encounters an ignored exception).
            try:
                os.dup2(os.open(os.devnull, os.O_WRONLY), sys.stdout.fileno())
            except OSError:
                pass
            sys.exit(2)

    # Summary emitted AFTER successful write (MINOR-6)
    print("px-render: %s" % " ".join(summary_fields), file=sys.stderr)


if __name__ == "__main__":
    main()
