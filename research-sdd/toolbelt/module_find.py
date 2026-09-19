#!/usr/bin/env python3
"""module-find: read-only scanner for a Niagara N4 module Java source tree.

Walks a directory tree of .java source files and extracts @NiagaraProperty
and @NiagaraAction annotation declarations using a paren-balance join (handles
multi-line annotations that naive grep misses), plus class->superclass extends
relationships.

Both the bare form (@NiagaraProperty(...)) and the container form
(@NiagaraProperties({@NiagaraProperty(...), @NiagaraProperty(...)})) are
handled by splitting the balanced buffer into per-annotation fragments — one
record emitted per fragment.

Emits key-sorted JSON evidence (schema: module-find.v1).

Exit codes:
  0  complete  -- valid source root; scan ran (zero annotations is a valid result)
  1  walk error -- root accessible but an internal scan failure occurred;
                   status:failed JSON emitted
  2  I/O error  -- absent, not-a-directory, or symlink root; no JSON emitted
"""
import argparse
import json
import os
import re
import stat as _stat
import sys

SCHEMA = "module-find.v1"

# Cap: maximum .java files to scan before setting truncated:true
_MAX_FILES = 5000

# Cap: maximum bytes read per .java file (2 MiB); guards against huge generated files.
_MAX_FILE_BYTES = 2 * 1024 * 1024

_O_NOFOLLOW = getattr(os, "O_NOFOLLOW", 0)
_O_CLOEXEC = getattr(os, "O_CLOEXEC", 0)


# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

def _write_json(path, data):
    """Write key-sorted JSON to path; refuse symlinks and pre-existing files."""
    content = (json.dumps(data, indent=2, sort_keys=True) + "\n").encode("utf-8")
    fd = os.open(
        str(path),
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | _O_NOFOLLOW | _O_CLOEXEC,
        0o600,
    )
    try:
        os.write(fd, content)
    finally:
        os.close(fd)


# ---------------------------------------------------------------------------
# Containment guard
# ---------------------------------------------------------------------------

def _real_root(root):
    """Resolve the real path of root (after stripping trailing sep)."""
    root = root.rstrip(os.sep) or os.sep
    return os.path.realpath(root)


def _within_root(real_root, path):
    """Return True if path's realpath is inside real_root."""
    rp = os.path.realpath(path)
    return rp == real_root or rp.startswith(real_root + os.sep)


# ---------------------------------------------------------------------------
# Java lexical helpers (issue #521)
# ---------------------------------------------------------------------------

def _code_only(text):
    """Return text with string literals and Java comments removed.

    Strips: double-quoted strings (handles \\" escapes), single-quoted char
    literals, // line comments, and /* */ block comments.  Newlines are
    preserved so split('\\n') returns the same line count as the input.

    Used for annotation keyword detection and paren depth counting so that
    parens and keywords inside strings/comments do not affect either check.
    """
    out = []
    state = 0  # 0 NORMAL  1 DQUOTE  2 SQUOTE  3 LINE_COMMENT  4 BLOCK_COMMENT
    i = 0
    n = len(text)
    while i < n:
        c = text[i]
        if state == 0:
            if c == '"':
                state = 1
            elif c == "'":
                state = 2
            elif c == '/' and i + 1 < n:
                if text[i + 1] == '/':
                    state = 3
                    i += 2
                    continue
                if text[i + 1] == '*':
                    state = 4
                    i += 2
                    continue
                out.append(c)
            else:
                out.append(c)
        elif state == 1:  # double-quoted string — omit content
            if c == '\\':
                i += 2
                continue
            if c == '"':
                state = 0
        elif state == 2:  # single-quoted char literal — omit content
            if c == '\\':
                i += 2
                continue
            if c == "'":
                state = 0
        elif state == 3:  # line comment — keep newline for split sync
            if c == '\n':
                out.append('\n')
                state = 0
        elif state == 4:  # block comment — keep newlines
            if c == '\n':
                out.append('\n')
            elif c == '*' and i + 1 < n and text[i + 1] == '/':
                state = 0
                i += 2
                continue
        i += 1
    return ''.join(out)


def _strip_comments(text):
    """Return text with Java comments removed but string literals intact.

    Strips // line comments and /* */ block comments; double- and
    single-quoted literals are preserved verbatim (backslash escapes
    inside them are handled so the closing delimiter is recognised
    correctly).  Newlines are preserved.

    Used to build the annotation accumulation buffer in _parse_file so
    that the annotation fragment extractor operates on comment-free
    source and regex extraction of name/type/flags fields still works.
    """
    out = []
    state = 0  # 0 NORMAL  1 DQUOTE  2 SQUOTE  3 LINE_COMMENT  4 BLOCK_COMMENT
    i = 0
    n = len(text)
    while i < n:
        c = text[i]
        if state == 0:
            if c == '"':
                state = 1
                out.append(c)
            elif c == "'":
                state = 2
                out.append(c)
            elif c == '/' and i + 1 < n:
                if text[i + 1] == '/':
                    state = 3
                    i += 2
                    continue
                if text[i + 1] == '*':
                    state = 4
                    i += 2
                    continue
                out.append(c)
            else:
                out.append(c)
        elif state == 1:  # double-quoted string — preserve verbatim
            out.append(c)
            if c == '\\':
                i += 1
                if i < n:
                    out.append(text[i])
            elif c == '"':
                state = 0
        elif state == 2:  # single-quoted char literal — preserve verbatim
            out.append(c)
            if c == '\\':
                i += 1
                if i < n:
                    out.append(text[i])
            elif c == "'":
                state = 0
        elif state == 3:  # line comment — discard, keep newline
            if c == '\n':
                out.append('\n')
                state = 0
        elif state == 4:  # block comment — discard, keep newlines
            if c == '\n':
                out.append('\n')
            elif c == '*' and i + 1 < n and text[i + 1] == '/':
                state = 0
                i += 2
                continue
        i += 1
    return ''.join(out)


# ---------------------------------------------------------------------------
# Annotation fragment extractor
# ---------------------------------------------------------------------------

def _extract_annotation_fragments(buf, tag):
    """Return a list of balanced annotation spans for 'tag' within buf.

    Finds every occurrence of tag + '(' and extracts the paren-balanced span
    from that '(' to its matching ')'.  Returns a list of strings, each being
    tag + '(' + inner_content + ')'.

    This handles both:
    - Bare form: @NiagaraProperty(...)  → one fragment
    - Container form: @NiagaraProperties({@NiagaraProperty(...), ...})
                     → one fragment per nested @NiagaraProperty(...)

    The search key is tag + '(' exactly, so '@NiagaraProperty(' never
    matches '@NiagaraProperties(' (which starts with 'Properties').

    The paren-balance walk uses a lexical state machine so that parens
    inside double-quoted strings, single-quoted char literals, and /* */
    block comments do not affect the depth counter (fixes C-1, issue #521).
    buf is expected to have been built from _strip_comments output so that
    // line comments are already absent.
    """
    fragments = []
    search_from = 0
    full_tag = tag + "("
    while True:  # fragment-loop
        idx = buf.find(full_tag, search_from)
        if idx == -1:
            break
        # Walk forward from the opening '(' counting paren depth.
        # lex states: 0 NORMAL  1 DQUOTE  2 SQUOTE  4 BLOCK_COMMENT
        paren_start = idx + len(tag)  # index of '('
        depth = 0
        lex = 0
        i = paren_start
        while i < len(buf):
            c = buf[i]
            if lex == 0:
                if c == '"':
                    lex = 1  # enter double-quoted string
                elif c == "'":
                    lex = 2  # enter single-quoted char literal
                elif c == '/' and i + 1 < len(buf) and buf[i + 1] == '*':
                    lex = 4  # enter block comment
                    i += 1   # skip '*' on next iteration
                elif c == "(":
                    depth += 1
                elif c == ")":
                    depth -= 1
                    if depth == 0:
                        fragments.append(buf[idx : i + 1])
                        search_from = i + 1
                        break
            elif lex == 1:  # inside double-quoted string
                if c == '\\':
                    i += 1  # skip escaped char
                elif c == '"':
                    lex = 0
            elif lex == 2:  # inside single-quoted char literal
                if c == '\\':
                    i += 1
                elif c == "'":
                    lex = 0
            elif lex == 4:  # inside block comment
                if c == '*' and i + 1 < len(buf) and buf[i + 1] == '/':
                    lex = 0
                    i += 1
            i += 1
        else:
            # Unbalanced — skip past this tag occurrence and continue.
            search_from = idx + len(full_tag)
    return fragments


# ---------------------------------------------------------------------------
# Source tree scanner
# ---------------------------------------------------------------------------

def _scan_tree(root):
    """Walk root, parse .java files; return (slots, actions, extends, scanned, truncated, byte_capped_count, errors).

    slots:            list of {class, slot, type, flags, min}
    actions:          list of {action, class, flags}
    extends:          dict {class: superclass}
    scanned:          int (number of .java files attempted)
    truncated:        bool (True when file count hit _MAX_FILES)
    byte_capped_count: int (number of files whose content was capped by _MAX_FILE_BYTES)
    errors:           list of str
    """
    slots = []
    actions = []
    extends = {}
    errors = []
    scanned = 0
    truncated = False
    byte_capped_count = 0
    real_root = _real_root(root)

    for cur, dirs, files in os.walk(root, followlinks=False):
        # Prune dot-dirs in place (D9b: skip .git, .svn, etc.)
        dirs[:] = sorted(d for d in dirs if not d.startswith("."))

        # Containment: skip any subdir that resolves outside root
        dirs[:] = [
            d for d in dirs
            if _within_root(real_root, os.path.join(cur, d))
        ]

        for fname in sorted(files):
            if not fname.endswith(".java"):
                continue
            if scanned >= _MAX_FILES:
                truncated = True
                break

            fpath = os.path.join(cur, fname)
            # Only accept regular files (S_ISREG); skip symlinks, devices, etc.
            try:
                fstat = os.lstat(fpath)
            except OSError:
                continue
            if not _stat.S_ISREG(fstat.st_mode):
                continue

            cls = fname[:-5]  # strip .java
            scanned += 1

            try:
                with open(fpath, "rb") as fh:
                    raw = fh.read(_MAX_FILE_BYTES)
                file_byte_capped = len(raw) == _MAX_FILE_BYTES
                content = raw.decode("utf-8", errors="replace")
            except OSError as exc:
                errors.append(f"{fpath}: {exc}")
                continue
            if file_byte_capped:
                byte_capped_count += 1

            _parse_file(cls, content, slots, actions, extends, errors)

        if truncated:
            break

    return slots, actions, extends, scanned, truncated, byte_capped_count, errors


def _parse_file(cls, content, slots, actions, extends, errors):
    """Parse one Java source file; append to slots/actions/extends in place."""
    # extends: class X extends Y
    ext_m = re.search(
        r"\bclass\s+" + re.escape(cls) + r"\s+extends\s+(\w+)", content
    )
    if ext_m:
        superclass = ext_m.group(1)
        if cls in extends and extends[cls] != superclass:
            errors.append(
                f"extends collision: class '{cls}' seen with both"
                f" '{extends[cls]}' and '{superclass}' — keeping first"
            )
        else:
            extends[cls] = superclass

    # Paren-balance annotation join: handles both single-line and multi-line
    # @NiagaraProperty / @NiagaraAction annotations.
    #
    # Two pre-computed views of the content are used (issue #521):
    #   stripped_lines — comments stripped, string literals intact; used for
    #                    annotation keyword detection and the accumulation buf
    #                    so that commented-out annotations (C-2) are ignored
    #                    and regex extraction of name/type/flags still works.
    #   code_lines     — comments AND string contents stripped; used only for
    #                    paren depth counting so parens inside strings (C-1)
    #                    do not inflate the depth counter.
    stripped_content = _strip_comments(content)   # M7-TARGET: C-2 comment guard
    stripped_lines = stripped_content.split("\n")
    code_lines = _code_only(content).split("\n")
    i = 0
    while i < len(stripped_lines):
        stripped_ln = stripped_lines[i]
        if "@NiagaraProperty" not in stripped_ln and "@NiagaraAction" not in stripped_ln:
            i += 1
            continue

        # Start paren-balance accumulation.
        buf = stripped_ln
        depth = code_lines[i].count("(") - code_lines[i].count(")")
        j = i + 1
        while depth > 0 and j < len(stripped_lines):
            buf += " " + stripped_lines[j]
            depth += code_lines[j].count("(") - code_lines[j].count(")")
            j += 1
        i = j

        # Split buf into per-annotation fragments and process each one.
        # This handles both the bare form and the container form
        # (@NiagaraProperties({@NiagaraProperty(...), @NiagaraProperty(...)})).
        if "@NiagaraProperty" in buf:
            for frag in _extract_annotation_fragments(buf, "@NiagaraProperty"):
                nm = re.search(r'name\s*=\s*"([^"]+)"', frag)
                if not nm:
                    continue
                tm = re.search(r'type\s*=\s*"([^"]+)"', frag)
                # Capture full flags expression (handles compound 'Flags.A | Flags.B')
                fm = re.search(r"flags\s*=\s*([^,)]+)", frag)
                flags_str = re.sub(r"\s+", " ", fm.group(1).strip()) if fm else ""
                min_val = None
                mm = re.search(
                    r"BFacets\.MIN[^,)]*,\s*BDouble\.make\(\s*(-?[0-9.]+)[dDfFlL]?\s*\)",
                    frag,
                )
                if mm:
                    try:
                        min_val = float(mm.group(1))
                    except ValueError:
                        pass
                slots.append(
                    {
                        "class": cls,
                        "flags": flags_str,
                        "min": min_val,
                        "slot": nm.group(1),
                        "type": tm.group(1) if tm else "",
                    }
                )

        if "@NiagaraAction" in buf:
            for frag in _extract_annotation_fragments(buf, "@NiagaraAction"):
                nm = re.search(r'name\s*=\s*"([^"]+)"', frag)
                if not nm:
                    continue
                # Capture full flags expression (handles compound 'Flags.A | Flags.B')
                fm = re.search(r"flags\s*=\s*([^,)]+)", frag)
                flags_str = re.sub(r"\s+", " ", fm.group(1).strip()) if fm else ""
                actions.append(
                    {
                        "action": nm.group(1),
                        "class": cls,
                        "flags": flags_str,
                    }
                )


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main(argv=None):
    p = argparse.ArgumentParser(
        prog="module-find.py",
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("root", help="module source root directory (non-symlink)")
    p.add_argument("--output", metavar="PATH", help="write JSON evidence to PATH")
    args = p.parse_args(argv)

    root = args.root.rstrip(os.sep) or os.sep

    # Guard: reject absent, non-directory, or symlink root.
    # Step 1: lstat to detect symlinks BEFORE any follow.
    try:
        lstat_result = os.lstat(root)
    except OSError as exc:
        sys.stderr.write(f"module-find: cannot access root: {exc}\n")
        sys.exit(2)

    if _stat.S_ISLNK(lstat_result.st_mode):
        sys.stderr.write(f"module-find: symlink root rejected: {root}\n")
        sys.exit(2)

    # Step 2: check it is a directory (follows no symlink; lstat was clean above).
    if not os.path.isdir(root):
        sys.stderr.write(f"module-find: not a directory: {root}\n")
        sys.exit(2)

    # Scan
    try:
        slots, actions, extends, scanned, truncated, byte_capped_count, errors = _scan_tree(root)
    except Exception as exc:  # noqa: BLE001
        errors = [str(exc)]
        slots, actions, extends, scanned, truncated, byte_capped_count = [], [], {}, 0, False, 0

    status = "failed" if errors else "complete"
    evidence = {
        "actions": sorted(actions, key=lambda a: (a["class"], a["action"])),
        "errors": errors,
        "extends": extends,
        "files_byte_capped": byte_capped_count,
        "root": os.path.abspath(root),
        "scanned": scanned,
        "schema": SCHEMA,
        "slots": sorted(slots, key=lambda s: (s["class"], s["slot"])),
        "status": status,
        "truncated": truncated,
    }

    if args.output:
        try:
            _write_json(args.output, evidence)
        except OSError as exc:
            sys.stderr.write(f"module-find: cannot write output: {exc}\n")
            sys.exit(2)
    else:
        print(json.dumps(evidence, indent=2, sort_keys=True))

    sys.exit(1 if status == "failed" else 0)


if __name__ == "__main__":
    main()
