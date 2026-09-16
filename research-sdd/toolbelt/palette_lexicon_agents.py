#!/usr/bin/env python3
"""palette-lexicon-agents — palette/lexicon/agent census for an N4 extracted module.

Reads palette entries (<p n= t= m=> elements), lexicon keys (detecting the
duplicate-bare-key hazard), and agent registrations (<agent> in module.xml)
from an extracted N4 module directory tree.

Input: a module directory with artifact subdirs, each containing:
    extracted/
        module.palette              XML: <bajaObjectGraph><p ...></bajaObjectGraph>
        *.lexicon                   Properties: key=value pairs (all files examined, scanned recursively)
        META-INF/
            module.xml              XML: <module><type><agent>...</agent></type></module>

SECRETS DISCIPLINE: emits key names (not values), counts, and structural metadata.
Lexicon values are never read past the first '=' separator.

Exit codes:
  0  complete — module dir found and scanned; artifacts_scanned=0 is valid (§7)
  1  parse error — an artifact file was found but malformed (status:failed JSON emitted)
  2  I/O error  — absent, not-a-directory, or symlink input/output; no JSON emitted
"""

import argparse
import errno
import json
import os
import stat as _stat
import sys
import xml.etree.ElementTree as ET

SCHEMA = "palette-lexicon.v1"

_MAX_PALETTE_BYTES    = 16 * 1024 * 1024   # 16 MiB per module.palette
_MAX_LEXICON_BYTES    = 4 * 1024 * 1024    # 4 MiB per .lexicon file
_MAX_MODULE_XML_BYTES = 1 * 1024 * 1024    # 1 MiB per module.xml
_MAX_ARTIFACTS        = 500                # max artifact subdirs per module

_O_NOFOLLOW = getattr(os, "O_NOFOLLOW", 0)
_O_NONBLOCK = getattr(os, "O_NONBLOCK", 0)
_O_CLOEXEC  = getattr(os, "O_CLOEXEC",  0)


# ---------------------------------------------------------------------------
# I/O helpers
# ---------------------------------------------------------------------------

def _open_wo_new(path):
    """Open path write-only for a new file; refuse symlinks and pre-existing files.

    O_CREAT|O_EXCL refuses pre-existing files; O_NOFOLLOW refuses symlinks.
    """
    return os.open(
        str(path),
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | _O_NOFOLLOW | _O_CLOEXEC,
        0o600,
    )


def _write_json(path, data):
    """Write *data* as key-sorted JSON to *path*, refusing symlinks (O_NOFOLLOW)."""
    content = (json.dumps(data, indent=2, sort_keys=True) + "\n").encode("utf-8")
    fd = _open_wo_new(path)
    try:
        os.write(fd, content)
    finally:
        os.close(fd)


def _read_file_bounded(path, max_bytes):
    """Read a regular file up to max_bytes bytes; return (bytes_or_None, truncated_bool).

    Returns (None, False) when the file is absent, unreadable, a symlink, or
    a non-regular file. O_NOFOLLOW rejects symlinks; O_NONBLOCK prevents blocking
    on FIFOs. Does NOT use stat().st_size as the bound (forged-header defence).
    """
    try:
        fd = os.open(str(path), os.O_RDONLY | _O_NOFOLLOW | _O_NONBLOCK)
    except OSError:
        return None, False
    try:
        st = os.fstat(fd)
        if not _stat.S_ISREG(st.st_mode):
            return None, False
        chunks = []
        total = 0
        while True:
            want = min(65536, max_bytes + 1 - total)
            if want <= 0:
                break
            chunk = os.read(fd, want)
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
        data = b"".join(chunks)
        truncated = total > max_bytes
        if truncated:
            data = data[:max_bytes]
        return data, truncated
    except OSError:
        return None, False
    finally:
        try:
            os.close(fd)
        except OSError:
            pass


def _inside_root(root, subpath):
    """Return True iff subpath resolves via realpath inside root (containment guard)."""
    try:
        real_root = os.path.realpath(root)
        real_sub  = os.path.realpath(subpath)
    except OSError:
        return False
    return real_sub == real_root or real_sub.startswith(real_root + os.sep)


def _find_lexicon_files(ext_dir, module_root, onerror=None):
    """Find all *.lexicon files recursively under ext_dir (non-symlink regular files, containment-safe).

    Walks the directory tree using os.walk with followlinks=False so symlink
    directories are not descended. Returns a sorted list of absolute paths.

    onerror: optional callback passed to os.walk; called with an OSError when a
    subdirectory cannot be listed (absent-not-traversable, §7).
    """
    results = []
    for dirpath, dirnames, filenames in os.walk(
        ext_dir, topdown=True, followlinks=False, onerror=onerror
    ):
        if not _inside_root(module_root, dirpath):
            dirnames[:] = []  # prune entire subtree
            continue
        dirnames.sort()  # deterministic traversal order
        for name in sorted(filenames):
            if not name.endswith(".lexicon"):
                continue
            path = os.path.join(dirpath, name)
            if not _inside_root(module_root, path):
                continue
            try:
                lstat = os.lstat(path)
            except OSError:
                continue
            if _stat.S_ISLNK(lstat.st_mode) or not _stat.S_ISREG(lstat.st_mode):
                continue
            results.append(path)
    return results


# ---------------------------------------------------------------------------
# Pure parse helpers
# ---------------------------------------------------------------------------

def parse_palette(text):
    """Parse module.palette XML; return (p_slots_list, error_or_None).

    Collects ALL <p> elements (via root.iter) that have at least one of
    n/t/m attributes — including the root container and all descendants.
    This counts property slots in the palette graph, not just top-level
    entries (consistent with source-tool behavior).
    """
    if not text:
        return [], None
    try:
        root = ET.fromstring(text)
    except ET.ParseError as exc:
        return [], f"XML parse error: {exc}"
    except MemoryError:
        return [], "MemoryError: XML tree exceeded available memory during parse"
    entries = []
    for elem in root.iter("p"):
        entry = {}
        for attr in ("n", "t", "m"):
            if attr in elem.attrib:
                entry[attr] = elem.attrib[attr]
        if entry:
            entries.append(entry)
    return entries, None


def parse_lexicon(text):
    """Parse a .lexicon (Java .properties) text.

    Returns (keys_examined, duplicate_bare_keys_dict, error_or_None).

    keys_examined: total count of valid key=value lines (blank/comment lines excluded).
    This field proves the parser looked at the lexicon content (§7 anti-silent-zero).

    duplicate_bare_keys_dict: {key_name: occurrence_count} for keys occurring
    more than once (duplicate-bare-key hazard). Only key NAMES are retained;
    values are never read past the '=' separator (secrets discipline).

    NOTE: only '=' separator is recognized (standard form in this corpus).
    Backslash-continuation lines are not supported (non-goal).
    """
    if not text:
        return 0, {}, None
    counts = {}
    keys_examined = 0
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if "=" not in stripped:
            continue
        key = stripped.split("=", 1)[0].strip()
        if not key:
            continue
        keys_examined += 1
        counts[key] = counts.get(key, 0) + 1
    dups = {k: v for k, v in counts.items() if v > 1}
    return keys_examined, dups, None


def parse_agents(xml_text):
    """Parse <agent> registrations from module.xml text.

    Returns (agents_list, error_or_None).
    agents_list: [{type_name, type_class, on_types}...]
    """
    if not xml_text:
        return [], None
    try:
        root = ET.fromstring(xml_text)
    except ET.ParseError as exc:
        return [], f"module.xml parse error: {exc}"
    except MemoryError:
        return [], "MemoryError: module.xml tree exceeded available memory during parse"
    agents = []
    for type_elem in root.iter("type"):
        for agent_elem in type_elem.findall("agent"):
            on_types = [on.attrib.get("type", "") for on in agent_elem.findall("on")]
            agents.append({
                "on_types": on_types,
                "type_class": type_elem.attrib.get("class", ""),
                "type_name": type_elem.attrib.get("name", ""),
            })
    return agents, None


# ---------------------------------------------------------------------------
# Artifact discovery and collection
# ---------------------------------------------------------------------------

def _find_artifacts(module_root):
    """List artifact subdirs inside module_root.

    An artifact dir qualifies when it is a non-symlink directory that contains
    an `extracted/` sub-directory (non-symlink). Symlink artifact dirs are skipped
    (containment guard). Returns sorted list of artifact names.
    """
    try:
        entries = sorted(os.listdir(module_root))
    except OSError:
        return []
    results = []
    for name in entries:
        art_dir = os.path.join(module_root, name)
        # Containment: skip anything that resolves outside the module root.
        if not _inside_root(module_root, art_dir):
            continue
        try:
            lstat_art = os.lstat(art_dir)
        except OSError:
            continue
        # Skip symlinks and non-directories.
        if _stat.S_ISLNK(lstat_art.st_mode) or not _stat.S_ISDIR(lstat_art.st_mode):
            continue
        # An artifact needs an extracted/ subdir to be actionable.
        ext_dir = os.path.join(art_dir, "extracted")
        if not _inside_root(module_root, ext_dir):
            continue
        try:
            lstat_ext = os.lstat(ext_dir)
        except OSError:
            lstat_ext = None
        has_extracted = (
            lstat_ext is not None
            and not _stat.S_ISLNK(lstat_ext.st_mode)
            and _stat.S_ISDIR(lstat_ext.st_mode)
        )
        if has_extracted:
            results.append(name)
    return results


def _collect_artifact(module_root, artifact_name, errors):
    """Collect palette + lexicon + agents for one artifact directory.

    Appends error strings to *errors* on XML parse failures.
    Returns a per-artifact evidence dict.
    """
    art_dir = os.path.join(module_root, artifact_name)
    ext_dir = os.path.join(art_dir, "extracted")

    # --- palette (module.palette) ---
    palette_entries = []
    palette_present = False
    palette_path = os.path.join(ext_dir, "module.palette")
    if _inside_root(module_root, palette_path):
        raw, truncated = _read_file_bounded(palette_path, _MAX_PALETTE_BYTES)
        if raw is not None:
            palette_present = True
            text = raw.decode("utf-8", errors="replace")
            entries, err = parse_palette(text)
            if err:
                errors.append(f"{artifact_name}/module.palette: {err}")
            else:
                palette_entries = entries
            if truncated:
                errors.append(
                    f"{artifact_name}/module.palette: "
                    f"truncated at {_MAX_PALETTE_BYTES} bytes — XML parse failed"
                )

    # --- lexicon (all *.lexicon files under extracted/, recursively) ---
    # Duplicate detection is PER FILE: a key repeated within ONE lexicon file is a
    # hazard; the same key in two different files is NOT (each .lexicon is a separate
    # namespace, e.g. baja.lexicon vs alarm.lexicon in language-pack modules).
    # Keys are paths RELATIVE TO extracted/ so same-basename files in different
    # subdirs (e.g. fr/baja.lexicon vs fr_CA/baja.lexicon) remain distinct (§7).
    def _walk_onerror(exc):
        try:
            rel = os.path.relpath(str(exc.filename), ext_dir) if exc.filename else "unknown"
        except ValueError:
            rel = str(exc.filename) if exc.filename else "unknown"
        errors.append(f"{artifact_name}/{rel}: unreadable directory (os.walk onerror)")

    lexicon_files = _find_lexicon_files(ext_dir, module_root, onerror=_walk_onerror)
    lexicon_files_seen = len(lexicon_files)
    per_file_dups = {}
    keys_examined = 0
    for lex_path in lexicon_files:
        lex_relpath = os.path.relpath(lex_path, ext_dir)
        raw, truncated = _read_file_bounded(lex_path, _MAX_LEXICON_BYTES)
        if raw is None:
            errors.append(f"{artifact_name}/{lex_relpath}: lexicon file unreadable")
            continue
        # utf-8-sig codec strips a leading UTF-8 BOM (0xEF BB BF) before parsing
        text = raw.decode("utf-8-sig", errors="replace")
        fkex, fdups, ferr = parse_lexicon(text)
        keys_examined += fkex
        if fdups:
            per_file_dups[lex_relpath] = fdups
        if ferr:
            errors.append(f"{artifact_name}/{lex_relpath}: {ferr}")
        if truncated:
            errors.append(
                f"{artifact_name}/{lex_relpath}: "
                f"truncated at {_MAX_LEXICON_BYTES} bytes"
            )
    dup_keys = per_file_dups
    dup_count = sum(len(v) for v in dup_keys.values())

    # --- agents (META-INF/module.xml) ---
    agents = []
    module_xml_present = False
    meta_dir = os.path.join(ext_dir, "META-INF")
    xml_path = os.path.join(meta_dir, "module.xml")
    if _inside_root(module_root, xml_path):
        raw, truncated = _read_file_bounded(xml_path, _MAX_MODULE_XML_BYTES)
        if raw is not None:
            module_xml_present = True
            text = raw.decode("utf-8", errors="replace")
            parsed_agents, err = parse_agents(text)
            if err:
                errors.append(f"{artifact_name}/META-INF/module.xml: {err}")
            else:
                agents = parsed_agents
            if truncated:
                errors.append(
                    f"{artifact_name}/META-INF/module.xml: "
                    f"truncated at {_MAX_MODULE_XML_BYTES} bytes"
                )

    return {
        "agents": agents,
        "agents_count": len(agents),
        "artifact": artifact_name,
        "duplicate_bare_keys": dup_keys,
        "duplicate_bare_keys_count": dup_count,
        "keys_examined": keys_examined,
        "lexicon_files_seen": lexicon_files_seen,
        "lexicon_keys": keys_examined,
        "module_xml_present": module_xml_present,
        "palette_count": len(palette_entries),
        "palette_present": palette_present,
    }


# ---------------------------------------------------------------------------
# Main command
# ---------------------------------------------------------------------------

def cmd_scan(args):
    """Scan a module directory for palette/lexicon/agent data. Returns exit code."""
    module_dir = args.input.rstrip(os.sep) or os.sep

    # --- Input validation: must be a non-symlink directory ---
    try:
        lstat_in = os.lstat(module_dir)
    except OSError:
        sys.stderr.write(
            f"palette-lexicon-agents: input not found: {module_dir!r}\n"
        )
        return 2

    if _stat.S_ISLNK(lstat_in.st_mode):
        sys.stderr.write(
            f"palette-lexicon-agents: input is a symbolic link (rejected): "
            f"{module_dir!r}\n"
        )
        return 2

    if not os.path.isdir(module_dir):
        sys.stderr.write(
            f"palette-lexicon-agents: input is not a directory: {module_dir!r}\n"
        )
        return 2

    # --- Discover and cap artifact subdirs ---
    artifact_names = _find_artifacts(module_dir)
    truncated = len(artifact_names) > _MAX_ARTIFACTS
    if truncated:
        artifact_names = artifact_names[:_MAX_ARTIFACTS]

    # --- Collect data from each artifact ---
    errors = []
    artifacts = []
    for name in artifact_names:
        art_data = _collect_artifact(module_dir, name, errors)
        artifacts.append(art_data)

    parse_failed = bool(errors)
    status = "failed" if parse_failed else "complete"

    total_palette   = sum(a["palette_count"] for a in artifacts)
    total_lex       = sum(a["lexicon_keys"] for a in artifacts)
    total_keys_exam = sum(a["keys_examined"] for a in artifacts)
    total_dup       = sum(a["duplicate_bare_keys_count"] for a in artifacts)
    total_agents    = sum(a["agents_count"] for a in artifacts)

    result = {
        "artifacts": artifacts,
        "errors": errors,
        "limitations": [
            f"module.palette read capped at {_MAX_PALETTE_BYTES} bytes;"
            f" a pathological XML tree can still exceed available memory during parse;"
            f" MemoryError is caught and reported as status:failed.",
            f".lexicon read capped at {_MAX_LEXICON_BYTES} bytes per file.",
            f"module.xml read capped at {_MAX_MODULE_XML_BYTES} bytes.",
            f"Artifact subdirs capped at {_MAX_ARTIFACTS} per module.",
            "Lexicon values are never read or emitted (secrets discipline).",
            "Only '=' key separator recognized; backslash-continuation not supported.",
            "JAR fallback (absent extracted/) is not supported.",
            "*.lexicon files scanned recursively under extracted/ (symlinks not followed).",
            "Duplicate detection is per-file: a key appearing once per file is not flagged"
            " even if it appears in multiple .lexicon files (each file is a separate namespace).",
        ],
        "schema": SCHEMA,
        "status": status,
        "summary": {
            "agents": total_agents,
            "artifacts_scanned": len(artifacts),
            "duplicate_bare_keys": total_dup,
            "keys_examined": total_keys_exam,
            "lexicon_keys": total_lex,
            "palette_entries": total_palette,
        },
        "truncated": truncated,
    }

    try:
        _write_json(args.output, result)
    except OSError as exc:
        sys.stderr.write(
            f"palette-lexicon-agents: output {args.output}: {exc.strerror}\n"
        )
        return 2

    return 1 if parse_failed else 0


# ---------------------------------------------------------------------------
# Argument parser
# ---------------------------------------------------------------------------

def _build_parser():
    p = argparse.ArgumentParser(
        prog="palette-lexicon-agents",
        description=(
            "Palette/lexicon/agent census for an N4 extracted module directory. "
            "Read-only: scans palette entries, lexicon keys (duplicate-bare-key "
            "hazard), and agent registrations. "
            "Emits key names and counts only; lexicon values are never read or emitted."
        ),
    )
    p.add_argument(
        "--input", required=True, metavar="MODULE_DIR",
        help="N4 module directory (non-symlink, with artifact subdirs containing extracted/)",
    )
    p.add_argument(
        "--output", required=True, metavar="JSON",
        help="output JSON evidence file (must not already exist)",
    )
    return p


def main():
    args = _build_parser().parse_args()
    sys.exit(cmd_scan(args))


if __name__ == "__main__":
    if sys.version_info[0] < 3:
        sys.stderr.write("palette-lexicon-agents: requires python3\n")
        sys.exit(2)
    main()
