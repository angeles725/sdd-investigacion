#!/usr/bin/env python3
"""Niagara N4 station module dependency checker.

Reads a config.bog (ZIP-compressed file.xml or bare plaintext XML) and a
Niagara install root, resolves module aliases and type references from the
station, and reports which module parts are present or missing in the install's
modules/ directory.

SECRETS DISCIPLINE: emits module names, part names, and installed_parts lists
only.  Never emits versions, vendor strings, JAR paths, slot values, credential
fields, or key material.  A config.bog may hold credentials; only structural
module topology is published.

ZIP inflation is bounded at _MAX_BOG_INFLATE via a length-bounded read:
    with zf.open("file.xml") as f:
        data = f.read(_MAX_BOG_INFLATE + 1)
NEVER use zipfile.getinfo().file_size as the bound — a forged central-directory
header defeats it.  The read is guarded with except Exception to catch all
entry-level failures: corrupted deflate (zlib.error), CRC mismatch (BadZipFile),
encrypted entry (RuntimeError), unsupported compression (NotImplementedError).
Without this guard these exceptions escape as tracebacks with no JSON output,
contradicting the documented "exit 1 → status:failed JSON" contract.

Exit codes:
  0  complete — bog parsed and module check ran; missing_parts may be empty
                (zero missing is valid and proves the instrument looked when
                jars_scanned is also present); modules_referenced=0 for an
                empty station is also exit 0 (§7 anti-silent-zero)
  1  parse error — file exists but bog is malformed, unreadable, or exceeds the
                   inflate cap; status:failed JSON emitted
  2  I/O error  — absent, not-a-regular-file, or symlink input/output; absent,
                   not-a-directory, or symlink install root; no JSON emitted
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

SCHEMA = "station-modules.v1"

_MAX_BOG_INFLATE = 32 * 1024 * 1024  # 32 MiB — ZIP file.xml inflate cap
_MAX_JARS = 2000                      # max JARs to scan in modules/
_MAX_MODULE_XML = 64 * 1024           # 64 KiB — per-JAR module.xml cap

_O_NOFOLLOW = getattr(os, "O_NOFOLLOW", 0)
_O_NONBLOCK = getattr(os, "O_NONBLOCK", 0)
_O_CLOEXEC  = getattr(os, "O_CLOEXEC", 0)

# Sentinel returned by _read_module_xml when the module.xml entry exceeds
# _MAX_MODULE_XML.  Distinct from None (other error/absent) so callers can
# count oversized skips without a separate probe.
_OVERSIZED = object()


# ---------------------------------------------------------------------------
# I/O helpers
# ---------------------------------------------------------------------------

def _open_ro(path):
    """Open path read-only, rejecting symlinks via O_NOFOLLOW.

    O_NONBLOCK is also set so that opening a non-regular file (e.g. a FIFO)
    does not block; the S_ISREG check in cmd_check rejects it immediately after.
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

    Uses O_CREAT|O_EXCL|O_NOFOLLOW so a pre-existing symlink or regular file
    at *path* causes the open to fail (ELOOP / EEXIST -> OSError -> exit 2).
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
    content = (json.dumps(data, indent=2, sort_keys=True) + "\n").encode("utf-8")
    fd = _open_wo_new(path)
    try:
        os.write(fd, content)
    finally:
        os.close(fd)


# ---------------------------------------------------------------------------
# BOG reader
# ---------------------------------------------------------------------------

def _read_bog_fd(fd):
    """Read bog content from an already-open file descriptor.

    Returns (lines, format_str, error_str_or_None, truncated_bool).
    format_str: 'zip-xml' | 'plaintext-xml' | 'unknown'
    """
    # Peek at the first two bytes to detect ZIP magic (PK)
    os.lseek(fd, 0, os.SEEK_SET)
    header = os.read(fd, 4)
    os.lseek(fd, 0, os.SEEK_SET)

    is_zip = len(header) >= 2 and header[:2] == b"PK"

    if is_zip:
        # Read the whole file into a buffer for zipfile
        import io as _io
        raw = b""
        while True:
            chunk = os.read(fd, 65536)
            if not chunk:
                break
            raw += chunk

        try:
            zf = zipfile.ZipFile(_io.BytesIO(raw))
        except zipfile.BadZipFile as exc:
            return [], "unknown", f"not a valid ZIP: {exc}", False

        names = zf.namelist()
        xml_name = "file.xml" if "file.xml" in names else next(
            (n for n in names if n.endswith("file.xml")), None
        )
        if xml_name is None:
            zf.close()
            return [], "unknown", "ZIP contains no file.xml entry", False

        # LENGTH-BOUNDED read: never trust getinfo().file_size (zip-bomb DoS).
        # Wrap zf.open() + f.read() in except Exception to catch all entry-level
        # failures: corrupted deflate (zlib.error), CRC mismatch (BadZipFile),
        # encrypted entry (RuntimeError), unsupported compression (NotImplementedError).
        try:
            with zf.open(xml_name) as f:
                data = f.read(_MAX_BOG_INFLATE + 1)
            zf.close()
        except Exception as exc:
            try:
                zf.close()
            except Exception:
                pass
            return [], "zip-xml", f"ZIP entry read error: {exc}", False

        if len(data) > _MAX_BOG_INFLATE:
            return [], "zip-xml", (
                f"bog XML exceeded inflate cap ({_MAX_BOG_INFLATE} bytes); "
                "file.xml was not parsed"
            ), True

        try:
            text = data.decode("utf-8", errors="replace")
        except Exception as exc:
            return [], "zip-xml", f"UTF-8 decode error: {exc}", False

        return text.splitlines(), "zip-xml", None, False

    else:
        # Plaintext: LENGTH-BOUNDED read (same zip-bomb defence as ZIP path).
        # Never trust the file size reported by stat — read at most cap+1 bytes
        # so we can distinguish "exactly at cap" from "exceeds cap".
        os.lseek(fd, 0, os.SEEK_SET)
        raw = b""
        while True:
            chunk = os.read(fd, 65536)
            if not chunk:
                break
            raw += chunk
            if len(raw) > _MAX_BOG_INFLATE:
                return [], "unknown", (
                    f"plaintext bog exceeded read cap ({_MAX_BOG_INFLATE} bytes); "
                    "file was not parsed"
                ), True

        try:
            text = raw.decode("utf-8", errors="replace")
        except Exception as exc:
            return [], "unknown", f"decode error: {exc}", False

        stripped = text.lstrip()
        if not stripped.startswith("<"):
            return [], "unknown", "content is neither a ZIP nor XML", False

        return text.splitlines(), "plaintext-xml", None, False


# ---------------------------------------------------------------------------
# Station XML parser
# ---------------------------------------------------------------------------

def _parse_station_refs(lines):
    """Parse module aliases and type references from bog XML lines.

    Returns (alias_map, module_types, unresolved_aliases) where:
    - alias_map: {alias -> module_name}
    - module_types: {module_name -> set(TypeName)}
    - unresolved_aliases: count of t= references whose alias was not declared in m=

    Module alias declarations appear as m='a=mod b=baja' attributes.
    Type references appear as t='alias:TypeName' attributes.

    The alias in t= may contain hyphens (e.g. 'honbac-util:Type') — the regex
    accepts any non-whitespace/quote/=/: sequence, matching what the m= parser
    accepts after split('=', 1).
    """
    alias_map = {}
    module_types = {}
    text = "\n".join(lines)

    # Module alias declarations: m="a=mod b=baja" or m='a=mod b=baja'
    for m_match in re.finditer(r'\bm=["\']([^"\']+)["\']', text):
        for part in m_match.group(1).split():
            if "=" in part:
                alias, mod = part.split("=", 1)
                alias_map[alias] = mod

    # Type references: t="alias:TypeName" or t='alias:TypeName'
    # alias may contain hyphens (e.g. honbac-util); accept any non-ws/quote/=/: char.
    unresolved_aliases = 0
    for t_match in re.finditer(r'\bt=["\']([^\s"\'=:]+):([A-Za-z0-9_]+)["\']', text):
        alias = t_match.group(1)
        typename = t_match.group(2)
        mod = alias_map.get(alias)
        if mod:
            module_types.setdefault(mod, set()).add(typename)
        else:
            unresolved_aliases += 1

    # Ensure all aliased modules appear in module_types (even without concrete types)
    for mod in set(alias_map.values()):
        module_types.setdefault(mod, set())

    return alias_map, module_types, unresolved_aliases


# ---------------------------------------------------------------------------
# Install index
# ---------------------------------------------------------------------------

def _ga_xml(attrs_str, name):
    """Get attribute value from an XML attribute string."""
    m = re.search(rf'\b{re.escape(name)}=["\']([^"\']*)["\']', attrs_str)
    return m.group(1) if m else ""


def _read_module_xml(jar_path):
    """Read META-INF/module.xml from a module JAR.

    Returns a dict with part/moduleName/profile/types/deps on success,
    _OVERSIZED when the module.xml entry exceeds _MAX_MODULE_XML (64 KiB),
    or None on any other error or if the entry is absent.

    Callers should check `is _OVERSIZED` to count visible skips (§7).
    """
    try:
        with zipfile.ZipFile(jar_path) as z:
            if "META-INF/module.xml" not in z.namelist():
                return None
            # LENGTH-BOUNDED read (same zip-bomb defence as bog reader)
            with z.open("META-INF/module.xml") as f:
                data = f.read(_MAX_MODULE_XML + 1)
            if len(data) > _MAX_MODULE_XML:
                return _OVERSIZED  # visible to caller — counted, not silently dropped
            xml = data.decode("utf-8", errors="replace")
    except Exception:
        return None

    root_m = re.search(r"<module\b([^>]*)", xml)
    if not root_m:
        return None
    attrs = root_m.group(1)

    types = set(re.findall(r'<type\b[^>]*\bname=["\']([^"\']*)["\']', xml))
    deps = re.findall(r'<dependency\b[^>]*\bname=["\']([^"\']*)["\']', xml)

    return {
        "deps": deps,
        "moduleName": _ga_xml(attrs, "moduleName"),
        "part": _ga_xml(attrs, "name"),
        "profile": _ga_xml(attrs, "runtimeProfile"),
        "types": types,
        "vendor": _ga_xml(attrs, "vendor"),
        "version": _ga_xml(attrs, "vendorVersion"),
    }


def _inside_root(root, subpath):
    """Return True iff subpath resolves via realpath inside root (containment guard)."""
    try:
        real_root = os.path.realpath(root)
        real_sub  = os.path.realpath(subpath)
    except OSError:
        return False
    return real_sub == real_root or real_sub.startswith(real_root + os.sep)


def _index_install(install_root):
    """Walk install_root/modules/ and build a module-parts index.

    Returns (parts, jars_scanned, jars_total, truncated, error_or_None, jars_skipped_oversized).
    parts: {partName -> meta_dict}
    error_or_None: None on success; a descriptive string on failure (absent,
      unreadable, or containment-escaped modules/ dir).  On error, parts={},
      all counts are 0, and the caller MUST NOT treat the result as a valid
      (possibly empty) install — doing so would produce a false "all missing" report.
    jars_skipped_oversized: count of JARs whose module.xml exceeded _MAX_MODULE_XML.

    Bounded at _MAX_JARS; truncation is always visible in the return values.
    Symlinks inside modules/ that escape the install root are skipped.
    """
    modules_dir = os.path.join(install_root, "modules")

    # Containment: reject if modules/ resolves outside install root.
    # This covers symlink-escaped paths; return a typed error so the caller
    # does NOT fall through to a "0 jars scanned → all modules missing" report.
    if not _inside_root(install_root, modules_dir):
        return {}, 0, 0, False, (
            f"modules/ dir resolves outside install root (symlink escape): "
            f"{modules_dir!r}"
        ), 0

    # Probe modules/ before listdir to produce a typed error on absent/unreadable dir.
    try:
        mstat = os.lstat(modules_dir)
    except OSError as exc:
        if exc.errno == errno.ENOENT:
            return {}, 0, 0, False, (
                f"modules/ directory not found in install root: {modules_dir!r}"
            ), 0
        return {}, 0, 0, False, (
            f"modules/ directory inaccessible: {exc.strerror}: {modules_dir!r}"
        ), 0

    if _stat.S_ISLNK(mstat.st_mode):
        return {}, 0, 0, False, (
            f"modules/ is a symbolic link (rejected): {modules_dir!r}"
        ), 0

    if not _stat.S_ISDIR(mstat.st_mode):
        return {}, 0, 0, False, (
            f"modules/ is not a directory: {modules_dir!r}"
        ), 0

    try:
        entries = sorted(os.listdir(modules_dir))
    except OSError as exc:
        return {}, 0, 0, False, (
            f"modules/ directory unreadable: {exc.strerror}: {modules_dir!r}"
        ), 0

    jar_entries = [e for e in entries if e.endswith(".jar")]
    jars_total = len(jar_entries)
    parts = {}
    jars_scanned = 0
    jars_skipped_oversized = 0
    truncated = False

    for fname in jar_entries:
        if jars_scanned >= _MAX_JARS:
            truncated = True
            break
        fpath = os.path.join(modules_dir, fname)

        # Containment: skip jars outside install root
        if not _inside_root(install_root, fpath):
            continue

        try:
            linfo = os.lstat(fpath)
        except OSError:
            continue
        if _stat.S_ISLNK(linfo.st_mode):
            continue
        if not _stat.S_ISREG(linfo.st_mode):
            continue

        meta = _read_module_xml(fpath)
        jars_scanned += 1
        if meta is _OVERSIZED:
            jars_skipped_oversized += 1  # visible, not silently dropped (§7)
        elif meta and meta["part"]:
            meta["jar"] = fname  # relative name only (secrets discipline: no abs paths)
            parts[meta["part"]] = meta

    return parts, jars_scanned, jars_total, truncated, None, jars_skipped_oversized


# ---------------------------------------------------------------------------
# Main command
# ---------------------------------------------------------------------------

def cmd_check(args):
    """Check station module dependencies against a Niagara install. Returns exit code."""
    fd = None
    try:
        # --- Bog input validation ---
        try:
            fd = _open_ro(args.input)
        except OSError as exc:
            sys.stderr.write(f"station-modules: {args.input}: {exc.strerror}\n")
            return 2

        stat_result = os.fstat(fd)
        if not _stat.S_ISREG(stat_result.st_mode):
            sys.stderr.write(
                f"station-modules: {args.input}: not a regular file (rejected)\n"
            )
            return 2

        sha256 = _sha256_fd(fd)
        size_bytes = stat_result.st_size

        # --- Install root validation ---
        install_root = args.install
        # Strip trailing separator: os.lstat("link/") follows symlinks on POSIX
        install_root = install_root.rstrip(os.sep) or os.sep

        try:
            lstat_install = os.lstat(install_root)
        except OSError:
            sys.stderr.write(
                f"station-modules: install root not found: {install_root!r}\n"
            )
            return 2

        if _stat.S_ISLNK(lstat_install.st_mode):
            sys.stderr.write(
                f"station-modules: install root is a symbolic link (rejected): "
                f"{install_root!r}\n"
            )
            return 2

        if not _stat.S_ISDIR(os.stat(install_root).st_mode):
            sys.stderr.write(
                f"station-modules: install root is not a directory: {install_root!r}\n"
            )
            return 2

        # --- Read and parse bog ---
        lines, fmt, read_error, truncated = _read_bog_fd(fd)

        errors = []
        parse_failed = False
        modules = {}
        missing_parts = {}
        jars_scanned = 0
        jars_total = 0
        jars_skipped_oversized = 0
        install_truncated = False
        unresolved_aliases = 0
        total_types_unresolved = 0

        if read_error:
            errors.append(read_error)
            parse_failed = True
        else:
            try:
                _, module_types, unresolved_aliases = _parse_station_refs(lines)

                # Index the install; error_or_None distinguishes a broken install
                # path (absent/unreadable/escaped modules/ dir) from a genuinely
                # empty install — the caller MUST check before computing missing_parts.
                parts, jars_scanned, jars_total, install_truncated, install_error, \
                    jars_skipped_oversized = _index_install(install_root)

                if install_error:
                    # Typed install error: report it and stop.  Do NOT fall through
                    # to the module check — that would produce a false "all missing"
                    # report for every referenced module (§7 install-side blocker).
                    errors.append(install_error)
                    parse_failed = True
                else:
                    if install_truncated:
                        errors.append(
                            f"install scan truncated at {_MAX_JARS} JARs "
                            f"({jars_total} total)"
                        )
                        truncated = True

                    # Check each referenced module against installed parts.
                    # Two distinct findings — (A) module absent: no parts installed;
                    # (B) module present but a referenced type not found in any part.
                    # Finding B is NOT a missing part — the module IS installed;
                    # reporting it as missing would be a false alarm (FABLE review).
                    for mod in sorted(module_types):
                        inst = {p: parts[p] for p in parts if parts[p]["moduleName"] == mod}
                        types_ref = sorted(module_types[mod])
                        types_unresolved = []

                        if not inst:
                            # (A) Module not installed at all — report missing part.
                            if types_ref:
                                for tn in types_ref:
                                    missing_parts.setdefault(
                                        f"{mod}-rt",
                                        f"module {mod} not installed "
                                        f"(type {tn} referenced)",
                                    )
                            else:
                                missing_parts.setdefault(
                                    f"{mod}-rt",
                                    f"module {mod} referenced, no part installed",
                                )
                        else:
                            # (B) Module IS installed — check type resolution only.
                            # A type not found in any installed part is a version/
                            # profile mismatch, NOT an absent part.  Never hardcode
                            # '{mod}-rt' here; the module's parts are present.
                            for tn in types_ref:
                                provider = next(
                                    (p for p, meta in inst.items()
                                     if tn in meta["types"]),
                                    None,
                                )
                                if not provider:
                                    types_unresolved.append(tn)
                                    total_types_unresolved += 1

                        modules[mod] = {
                            "installed_parts": sorted(inst.keys()),
                            "types_referenced": types_ref,
                            "types_unresolved": types_unresolved,
                        }

            except Exception as exc:
                errors.append(f"parse error: {exc}")
                parse_failed = True

        status = "failed" if parse_failed else "complete"

        result = {
            "errors": errors,
            "input": {
                "format": fmt,
                "sha256": sha256,
                "size_bytes": size_bytes,
            },
            "install_root": install_root,
            "limitations": [
                f"Install JAR scan capped at {_MAX_JARS} entries.",
                "ZIP file.xml inflate capped at 32 MiB (zip-bomb protection).",
                "Plaintext bog read capped at 32 MiB (zip-bomb defence).",
                "Slot values are never emitted (secrets discipline).",
                "Fix operations are not performed (read-only tool).",
            ],
            "missing_parts": missing_parts,
            "modules": modules,
            "schema": SCHEMA,
            "status": status,
            "summary": {
                "jars_scanned": jars_scanned,
                "jars_skipped_oversized": jars_skipped_oversized,
                "jars_total": jars_total,
                "missing_parts": len(missing_parts),
                "modules_referenced": len(modules),
                "types_unresolved": total_types_unresolved,
                "unresolved_aliases": unresolved_aliases,
            },
            "truncated": truncated,
        }

        try:
            _write_json(args.output, result)
        except OSError as exc:
            sys.stderr.write(f"station-modules: output {args.output}: {exc.strerror}\n")
            return 2

        return 1 if parse_failed else 0

    except OSError as exc:
        sys.stderr.write(f"station-modules: I/O error: {exc}\n")
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
        prog="station-modules",
        description=(
            "Niagara N4 station module dependency checker. "
            "Read-only: resolves module aliases and type references from a "
            "config.bog and reports missing module-parts in the install."
        ),
    )
    p.add_argument(
        "--input", required=True, metavar="BOG",
        help="config.bog (ZIP-compressed file.xml) or bare XML file",
    )
    p.add_argument(
        "--install", required=True, metavar="ROOT",
        help="Niagara N4 install root directory (contains modules/)",
    )
    p.add_argument(
        "--output", required=True, metavar="JSON",
        help="output JSON evidence file (must not already exist)",
    )
    return p


def main():
    args = _build_parser().parse_args()
    sys.exit(cmd_check(args))


if __name__ == "__main__":
    if sys.version_info[0] < 3:
        sys.stderr.write("station-modules: requires python3\n")
        sys.exit(3)
    main()
