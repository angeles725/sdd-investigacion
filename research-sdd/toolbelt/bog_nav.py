#!/usr/bin/env python3
"""Niagara N4 config.bog structural evidence extractor.

Reads a Niagara N4 station config.bog (a ZIP containing file.xml, or bare
plaintext XML) and emits key-sorted JSON evidence: component tree structure
(paths, types, handles), link list (sourceOrd h:xxxx handles resolved to
component paths), and module prefix-map.

SECRETS DISCIPLINE: emits component paths, types, handles, and link topology
only.  Never emits slot values, credential fields, or key material in
cleartext.  A config.bog may hold credentials; only structure is published.

ZIP inflation is bounded at 32 MiB via a LENGTH-BOUNDED read:
    with z.open("file.xml") as f:
        data = f.read(_MAX_BOG_INFLATE + 1)
    if len(data) > _MAX_BOG_INFLATE: ...
NEVER use zipfile.getinfo().file_size as the bound — a forged central-directory
header defeats it.  This pattern matches the PR5 lesson applied to
niagara_security_audit.py.

Exit codes:
  0  complete — bog parsed, evidence emitted (components=0 for an empty bog)
  1  parse error — file exists but content is malformed or cap exceeded;
                   status:failed JSON emitted
  2  I/O error  — absent, not-a-regular-file, or symlink input/output;
                   no JSON emitted
"""

import argparse
import errno
import hashlib
import json
import os
import re
import stat as _stat
import sys
import zipfile

SCHEMA = "bog-nav.v1"

_MAX_BOG_INFLATE = 32 * 1024 * 1024   # 32 MiB — ZIP file.xml inflate cap
_MAX_COMPONENTS  = 50_000             # component list cap (truncation visible)
_MAX_LINKS       = 20_000             # link list cap (truncation visible)

_O_NOFOLLOW  = getattr(os, 'O_NOFOLLOW', 0)
_O_NONBLOCK  = getattr(os, 'O_NONBLOCK', 0)
_O_CLOEXEC   = getattr(os, 'O_CLOEXEC', 0)


# ---------------------------------------------------------------------------
# I/O helpers
# ---------------------------------------------------------------------------

def _open_ro(path):
    """Open path read-only, rejecting symlinks via O_NOFOLLOW.

    O_NONBLOCK is also set so that opening a non-regular file (e.g. a FIFO)
    does not block; the S_ISREG check in cmd_extract rejects it immediately after.
    For regular files O_NONBLOCK has no effect on read() behaviour.
    """
    try:
        return os.open(str(path), os.O_RDONLY | _O_NOFOLLOW | _O_NONBLOCK)
    except OSError as exc:
        if exc.errno == errno.ELOOP:
            raise OSError(errno.ELOOP, "is a symbolic link (rejected)", str(path)) from exc
        raise


def _open_wo_new(path):
    """Open path write-only for a new file; refuse symlinks and pre-existing files.

    Uses O_CREAT|O_EXCL|O_NOFOLLOW so a pre-existing symlink or regular file at
    *path* causes the open to fail (ELOOP / EEXIST → OSError → exit 2).
    """
    return os.open(
        str(path),
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | _O_NOFOLLOW | _O_CLOEXEC,
        0o600,
    )


def _sha256_fd(fd):
    h = hashlib.sha256()
    os.lseek(fd, 0, os.SEEK_SET)
    while True:
        chunk = os.read(fd, 65536)
        if not chunk:
            break
        h.update(chunk)
    return h.hexdigest()


def _write_json(path, data):
    """Write *data* as key-sorted JSON to *path*, refusing symlinks (O_NOFOLLOW)."""
    content = (json.dumps(data, indent=2, sort_keys=True) + '\n').encode('utf-8')
    fd = _open_wo_new(path)
    try:
        os.write(fd, content)
    finally:
        os.close(fd)


# ---------------------------------------------------------------------------
# BOG-XML parser (structure only — no slot values)
# ---------------------------------------------------------------------------

_TAG_RE = re.compile(r'<(/?)([A-Za-z]\w*)\b([^>]*?)(/?)>')


def _ga(text, name):
    """Get attribute value: single-quoted first, then double-quoted."""
    m = re.search(rf"\b{re.escape(name)}='([^']*)'", text)
    if m:
        return m.group(1)
    m = re.search(rf'\b{re.escape(name)}="([^"]*)"', text)
    return m.group(1) if m else None


class _Comp:
    """Minimal component record: structure only, no slot values."""
    __slots__ = ('name', 'handle', 'type_', 'pfx', 'module', 'path', 'parent_h')

    def __init__(self, name, handle, type_, pfx, module, path, parent_h):
        self.name = name
        self.handle = handle
        self.type_ = type_
        self.pfx = pfx
        self.module = module
        self.path = path
        self.parent_h = parent_h


def _parse_bog_xml(lines):
    """Parse BOG-XML lines; return (prefix_map, handle_map, link_list).

    Structure-only parse: component paths, types, handles.
    Slot values are intentionally skipped (secrets discipline).
    """
    prefix_map = {}
    handle_map = {}
    link_list = []
    stack = []
    in_link = False
    link_buf = {}

    def nearest_comp():
        for fr in reversed(stack):
            if fr['type'] == 'comp':
                return fr['comp']
        return None

    for raw in lines:
        line = raw.rstrip()
        if not line.strip():
            continue
        for m in _TAG_RE.finditer(line):
            is_closing = bool(m.group(1))
            tag_name = m.group(2)
            is_self_cls = bool(m.group(4)) or m.group(0).endswith('/>')
            full = m.group(0)

            if is_closing:
                if tag_name in ('p', 'a') and stack:
                    popped = stack.pop()
                    if popped['type'] == 'link':
                        link_list.append(dict(link_buf))
                        in_link = False
                        link_buf = {}
                continue

            if tag_name == 'a':
                # Action element: structure not needed, but a non-self-closing
                # <a>...</a> MUST push a placeholder frame so </a> pops it
                # instead of the enclosing component frame.  Without the push,
                # </a> pops a component from the stack and corrupts the path
                # context for all subsequent siblings.
                if not is_self_cls:
                    parent = stack[-1] if stack else {}
                    ppath = parent.get('path', '')
                    stack.append({'type': 'action', 'handle': None,
                                  'path': ppath, 'comp': None})
                continue

            if tag_name != 'p':
                continue

            n = _ga(full, 'n') or ''
            h = _ga(full, 'h')
            t = _ga(full, 't') or ''
            v = _ga(full, 'v')
            m_attr = _ga(full, 'm') or ''

            # Module prefix declarations
            if m_attr:
                for part in m_attr.split():
                    if '=' in part:
                        pk, mv = part.split('=', 1)
                        prefix_map[pk] = mv

            if in_link:
                if is_self_cls:
                    if n == 'sourceOrd' and v and v.startswith('h:'):
                        link_buf['src_h'] = v[2:]
                    elif n == 'sourceSlotName' and v:
                        link_buf['src_slot'] = v
                    elif n == 'targetSlotName' and v:
                        link_buf['tgt_slot'] = v
                continue

            if t == 'b:Link' and not is_self_cls:
                comp = nearest_comp()
                in_link = True
                link_buf = {
                    'container_h': comp.handle if comp else None,
                    'container_path': comp.path if comp else '',
                    'link_name': n,
                    'src_h': None, 'src_slot': None, 'tgt_slot': None,
                }
                parent = stack[-1] if stack else {}
                stack.append({'type': 'link', 'handle': None,
                              'path': parent.get('path', ''), 'comp': None})
                continue

            if h is not None and is_self_cls:
                # Self-closing component (<p n='X' h='N' t='...'/>): record it
                # but do NOT push onto the stack — it has no open/close pair.
                # Niagara writes many leaf components as self-closing; missing
                # this branch silently under-counts components.
                pfx = t.split(':')[0] if ':' in t else ''
                module = prefix_map.get(pfx, '')
                parent = stack[-1] if stack else None
                parent_path = parent['path'] if parent else ''
                parent_comp = nearest_comp()
                parent_h = parent_comp.handle if parent_comp else None
                path = (parent_path + '/' + n).lstrip('/')
                comp = _Comp(n, h, t, pfx, module, path, parent_h)
                handle_map[h] = comp
                continue

            if h is not None and not is_self_cls:
                pfx = t.split(':')[0] if ':' in t else ''
                module = prefix_map.get(pfx, '')
                parent = stack[-1] if stack else None
                parent_path = parent['path'] if parent else ''
                parent_comp = nearest_comp()
                parent_h = parent_comp.handle if parent_comp else None
                path = (parent_path + '/' + n).lstrip('/')

                comp = _Comp(n, h, t, pfx, module, path, parent_h)
                handle_map[h] = comp
                stack.append({'type': 'comp', 'handle': h, 'path': path, 'comp': comp})
                continue

            # All other elements (slots, actions, fallback, etc.) are skipped —
            # secrets discipline: never capture slot values.
            if not is_self_cls and h is None:
                parent = stack[-1] if stack else {}
                ppath = parent.get('path', '')
                stack.append({'type': 'other', 'handle': None,
                              'path': (ppath + '/' + n).lstrip('/') if n else ppath,
                              'comp': None})

    return prefix_map, handle_map, link_list


def _build_link_row(lk, handle_map):
    """Resolve a link record to a human-readable row."""
    src = handle_map.get(lk.get('src_h'))
    src_path = src.path if src else (
        'h:' + lk['src_h'] if lk.get('src_h') else '?'
    )
    return {
        'link_name': lk.get('link_name'),
        'source': f"{src_path}.{lk.get('src_slot')}",
        'src_resolved': src is not None,
        'target': f"{lk.get('container_path')}.{lk.get('tgt_slot')}",
    }


# ---------------------------------------------------------------------------
# BOG reader
# ---------------------------------------------------------------------------

def _read_bog_lines(fd, size_bytes):
    """Read lines from a .bog file descriptor.

    Returns (lines, format_str, error_str | None, truncated_bool).
    format_str: 'zip-xml' | 'plaintext-xml' | 'unknown'
    """
    # Peek at the first bytes to detect ZIP vs plaintext
    os.lseek(fd, 0, os.SEEK_SET)
    header = os.read(fd, 4)
    os.lseek(fd, 0, os.SEEK_SET)

    is_zip = (len(header) >= 4 and header[:2] == b'PK')

    if is_zip:
        # Re-read the whole file into a bytes buffer for zipfile
        os.lseek(fd, 0, os.SEEK_SET)
        raw_bytes = b''
        while True:
            chunk = os.read(fd, 65536)
            if not chunk:
                break
            raw_bytes += chunk

        import io as _io
        try:
            zf = zipfile.ZipFile(_io.BytesIO(raw_bytes))
        except zipfile.BadZipFile as exc:
            return [], 'unknown', f"not a valid ZIP: {exc}", False

        names = zf.namelist()
        xml_name = 'file.xml' if 'file.xml' in names else next(
            (n for n in names if n.endswith('file.xml')), None
        )
        if xml_name is None:
            zf.close()
            return [], 'unknown', "ZIP contains no file.xml entry", False

        # LENGTH-BOUNDED read: never trust getinfo().file_size (zip-bomb DoS).
        # Wrap zf.open() + f.read() in except Exception to catch all entry-level
        # failures: corrupted deflate (zlib.error), CRC mismatch (BadZipFile),
        # encrypted entry (RuntimeError), unsupported compression (NotImplementedError).
        # Without this guard these exceptions escape as tracebacks with no JSON,
        # contradicting the documented "exit 1 → status:failed JSON" contract.
        try:
            with zf.open(xml_name) as f:
                data = f.read(_MAX_BOG_INFLATE + 1)
            zf.close()
        except Exception as exc:
            try:
                zf.close()
            except Exception:
                pass
            return [], 'zip-xml', f"ZIP entry read error: {exc}", False

        if len(data) > _MAX_BOG_INFLATE:
            return [], 'zip-xml', (
                f"bog XML exceeded inflate cap ({_MAX_BOG_INFLATE} bytes); "
                "file.xml was not parsed"
            ), True

        try:
            text = data.decode('utf-8', errors='replace')
        except Exception as exc:
            return [], 'zip-xml', f"UTF-8 decode error: {exc}", False

        return text.splitlines(), 'zip-xml', None, False

    else:
        # Plaintext XML: read directly (already bounded by file system)
        os.lseek(fd, 0, os.SEEK_SET)
        raw = b''
        while True:
            chunk = os.read(fd, 65536)
            if not chunk:
                break
            raw += chunk

        try:
            text = raw.decode('utf-8', errors='replace')
        except Exception as exc:
            return [], 'unknown', f"plaintext decode error: {exc}", False

        # Minimal check: must look like XML (start with '<')
        stripped = text.lstrip()
        if not stripped.startswith('<'):
            return [], 'unknown', "content is neither a ZIP nor XML", False

        return text.splitlines(), 'plaintext-xml', None, False


# ---------------------------------------------------------------------------
# Main command
# ---------------------------------------------------------------------------

def cmd_extract(args):
    """Parse a .bog file and emit key-sorted JSON evidence."""
    fd = None
    try:
        # --- input validation ---
        try:
            fd = _open_ro(args.input)
        except OSError as exc:
            sys.stderr.write(f"bog-nav: {args.input}: {exc.strerror}\n")
            return 2

        stat_result = os.fstat(fd)
        if not _stat.S_ISREG(stat_result.st_mode):
            sys.stderr.write(
                f"bog-nav: {args.input}: not a regular file (rejected)\n"
            )
            return 2

        sha256 = _sha256_fd(fd)
        size_bytes = stat_result.st_size

        # --- read and parse ---
        lines, fmt, read_error, truncated = _read_bog_lines(fd, size_bytes)

        errors = []
        components = []
        links = []
        prefix_map = {}
        comp_truncated = False
        link_truncated = False

        if read_error:
            errors.append(read_error)
        else:
            try:
                prefix_map, handle_map, link_list = _parse_bog_xml(lines)

                # Build component list (structure only — no slot values)
                all_comps = sorted(handle_map.values(), key=lambda c: c.path)
                if len(all_comps) > _MAX_COMPONENTS:
                    all_comps = all_comps[:_MAX_COMPONENTS]
                    comp_truncated = True
                    errors.append(
                        f"component list truncated at {_MAX_COMPONENTS} entries"
                    )

                for comp in all_comps:
                    components.append({
                        'handle': comp.handle,
                        'module': comp.module,
                        'path': comp.path,
                        'type': comp.type_,
                    })

                # Build link list
                all_links = [_build_link_row(lk, handle_map) for lk in link_list]
                if len(all_links) > _MAX_LINKS:
                    all_links = all_links[:_MAX_LINKS]
                    link_truncated = True
                    errors.append(
                        f"link list truncated at {_MAX_LINKS} entries"
                    )
                links = all_links

            except Exception as exc:
                errors.append(f"parse error: {exc}")

        truncated = truncated or comp_truncated or link_truncated
        # status:failed only for read errors or parse errors, not for truncation
        # (truncation is a visibility note, not a failure — §7 anti-silent-zero)
        _parse_failed = read_error or (errors and not (comp_truncated or link_truncated))
        status = 'failed' if _parse_failed else 'complete'
        # An empty bog (zero components, no errors) is still 'complete' — §7
        # distinguishes absent-input (exit 2) from empty-input (exit 0, 0 comps).

        result = {
            'components': components,
            'errors': errors,
            'input': {
                'format': fmt,
                'sha256': sha256,
                'size_bytes': size_bytes,
            },
            'limitations': [
                f"Component list capped at {_MAX_COMPONENTS} entries.",
                f"Link list capped at {_MAX_LINKS} entries.",
                "ZIP file.xml inflate capped at 32 MiB (zip-bomb protection).",
                "Slot values are never emitted (secrets discipline).",
            ],
            'links': links,
            'schema': SCHEMA,
            'status': status,
            'summary': {
                'components': len(components),
                'links': len(links),
                'prefixes': dict(sorted(prefix_map.items())),
            },
            'truncated': truncated,
        }

        try:
            _write_json(args.output, result)
        except OSError as exc:
            sys.stderr.write(f"bog-nav: output {args.output}: {exc.strerror}\n")
            return 2

        return 1 if _parse_failed else 0

    except OSError as exc:
        sys.stderr.write(f"bog-nav: I/O error: {exc}\n")
        return 2
    finally:
        if fd is not None:
            try:
                os.close(fd)
            except OSError:
                pass


# ---------------------------------------------------------------------------
# Argument parser
# ---------------------------------------------------------------------------

def _build_parser():
    p = argparse.ArgumentParser(
        prog='bog-nav',
        description='Niagara N4 config.bog structural evidence extractor.',
    )
    p.add_argument('--input', required=True, metavar='BOG',
                   help='config.bog (ZIP-compressed file.xml) or bare XML file')
    p.add_argument('--output', required=True, metavar='JSON',
                   help='output JSON evidence file path (must not already exist)')
    return p


def main():
    args = _build_parser().parse_args()
    sys.exit(cmd_extract(args))


if __name__ == '__main__':
    if sys.version_info[0] < 3:
        sys.stderr.write('bog-nav: requires python3\n')
        sys.exit(3)
    main()
