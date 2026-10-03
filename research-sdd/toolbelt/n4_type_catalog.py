#!/usr/bin/env python3
"""n4-type-catalog: static catalog of Niagara 4 component slot declarations (n4-type-catalog.v1).

WHY: a station's .bog stores only NON-DEFAULT values, and the live station serves its own type contract only
over BOX. This tool recovers the same information OFFLINE and per version from Slotomatic-generated
declarations that survive decompilation:

    public static final Property in8 = newProperty(Flags.READONLY, new BStatusNumeric(...), null);
    public static final Action   set = newAction(Flags.OPERATOR, BDouble.DEFAULT, null);
    public static final Topic    ev  = newTopic(Flags.SUMMARY, null);

It reads ORIGINAL javadoc source or CFR/Vineflower output (numeric flags such as `(int)1026`), decodes the
flag expression to an int + letter list, and emits one record per type:
{package, class, extends, properties[], actions[], topics[]}. Value expressions stay STRINGS (never evaluated).

Read-only, stdlib only. Usage:
    n4_type_catalog.py build <dir>... [--out catalog.json]
    n4_type_catalog.py show <catalog.json|dir> <ClassName|pkg.Class>
Exit codes: 0 ok; 1 nothing catalogued (no .java files / no declarations) or type not found;
2 usage error, absent root, unreadable or malformed catalog, --out that cannot be written, or a degraded
read (.java entries or directories were unreadable and NO .java file could be read at all).
Nothing is skipped quietly: unreadable files/directories, non-regular files, declarations whose call could
not be parsed, and files with declarations but no class are each warned on stderr and counted in the summary.
Provenance rule: a catalog entry is `[CERT]`-grade only for the file it was parsed from (`source`; no line
numbers are recorded); inherited slots are NOT merged (use `extends` to walk), and a type with no
declarations is omitted.
"""

import argparse
import json
import os
import re
import sys

# javax.baja.sys.Flags (docSource baja/javax/baja/sys/Flags.java:179-198, B1169/B1174)
FLAG_BITS = {
    "READONLY": (0x00000001, "r"),
    "TRANSIENT": (0x00000002, "t"),
    "HIDDEN": (0x00000004, "h"),
    "SUMMARY": (0x00000008, "s"),
    "ASYNC": (0x00000010, "a"),
    "NO_RUN": (0x00000020, "n"),
    "DEFAULT_ON_CLONE": (0x00000040, "d"),
    "CONFIRM_REQUIRED": (0x00000080, "c"),
    "OPERATOR": (0x00000100, "o"),
    "EXECUTE_ON_CHANGE": (0x00000200, "x"),
    "FAN_IN": (0x00000400, "f"),
    "NO_AUDIT": (0x00000800, "A"),
    "COMPOSITE": (0x00001000, "p"),
    "REMOVE_ON_CLONE": (0x00002000, "R"),
    "METADATA": (0x00004000, "m"),
    "LINK_TARGET": (0x00008000, "L"),
    "NON_CRITICAL": (0x00010000, "N"),
    "USER_DEFINED_1": (0x10000000, "1"),
}
_BIT_LETTERS = sorted(((v, l) for v, l in FLAG_BITS.values()))


def decode_flags(expr):
    """Return (int value, [letters], [unrecognised tokens]) for `Flags.A | Flags.B`, `(int)1026`, `0`, `0x10`."""
    total = 0
    unknown = []
    for part in expr.split("|"):
        tok = part.strip()
        tok = re.sub(r"^\(\s*int\s*\)\s*", "", tok).strip()
        if not tok:
            continue
        m = re.match(r"^(?:javax\.baja\.sys\.)?Flags\.([A-Z_0-9]+)$", tok)
        if m and m.group(1) in FLAG_BITS:
            total |= FLAG_BITS[m.group(1)][0]
        elif re.match(r"^-?\d+$", tok):
            total |= int(tok)
        elif re.match(r"^0[xX][0-9a-fA-F]+$", tok):
            total |= int(tok, 16)
        else:
            unknown.append(tok)
    letters = [l for bit, l in _BIT_LETTERS if total & bit]
    return total, letters, unknown


def _chars(text, start=0):
    """Yield (index, char, in_literal) for text[start:]; the ONE string/char-literal scanner.

    Quotes and escaped characters count as in-literal, so a paren, comma or ';' inside a literal is never
    structural. _split_args, _balanced_call and _call_args all walk through this, so a literal-handling fix
    lands once.
    """
    in_str, i, n = None, start, len(text)
    while i < n:
        c = text[i]
        if in_str:
            yield i, c, True
            if c == "\\" and i + 1 < n:
                i += 1
                yield i, text[i], True
            elif c == in_str:
                in_str = None
        elif c in "\"'":
            in_str = c
            yield i, c, True
        else:
            yield i, c, False
        i += 1


def _split_args(s):
    """Split a call-argument string at top-level commas (respecting parens and string literals)."""
    args, depth, cur = [], 0, []
    for _, c, lit in _chars(s):
        if not lit:
            if c in "([{":
                depth += 1
            elif c in ")]}":
                depth -= 1
            elif c == "," and depth == 0:
                args.append("".join(cur).strip())
                cur = []
                continue
        cur.append(c)
    tail = "".join(cur).strip()
    if tail or args:
        args.append(tail)
    return args


def _clean(expr):
    e = expr.strip()
    # drop leading casts produced by decompilers: (BValue)x, (int)0
    while True:
        m = re.match(r"^\((?:int|BValue|BFacets|String|long|double|boolean|BObject)\)\s*(.*)$", e, re.S)
        if not m:
            break
        e = m.group(1).strip()
    return re.sub(r"\s+", " ", e)


_DECL = re.compile(
    r"public\s+static\s+final\s+(Property|Action|Topic)\s+(\w+)\s*=\s*",
)


def _balanced_call(text, start):
    """From `start` (just after '='), return the expression up to the terminating ';' at paren depth 0."""
    depth = 0
    for i, c, lit in _chars(text, start):
        if lit:
            continue
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
        elif c == ";" and depth == 0:
            return text[start:i]
    return text[start:]


def _call_args(expr):
    """Argument list of the first `newProperty(`/`newAction(`/`newTopic(` call in `expr`, or [] if not parseable.

    Walks to the matching ')' while ignoring parens inside string/char literals.
    """
    call = re.search(r"new(Property|Action|Topic)\s*\(", expr)
    if not call:
        return []
    start = call.end()
    depth = 1
    for j, c, lit in _chars(expr, start):
        if lit:
            continue
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return _split_args(expr[start:j])
    return []


def _default_and_facets(kind, args):
    """(default, facets) strings for a slot call.

    Property: newProperty(flags, default, facets).
    Action/Topic: the 2-arg form (flags, facets) has no default/parameter; the longer forms take the
    parameter/default as arg 2 and the facets as the LAST arg.
    """
    if kind == "Property":
        return (_clean(args[1]) if len(args) > 1 else "",
                _clean(args[2]) if len(args) > 2 else "null")
    if len(args) == 2:
        return "", _clean(args[1])
    return (_clean(args[1]) if len(args) > 1 else "",
            _clean(args[-1]) if len(args) > 2 else "null")


def parse_source(text):
    pkg = re.search(r"^\s*package\s+([\w.]+)\s*;", text, re.M)
    cls = re.search(r"\bpublic\s+(?:final\s+|abstract\s+)*class\s+(\w+)(?:\s+extends\s+([\w.<>]+))?", text)
    out = {
        "package": pkg.group(1) if pkg else "",
        "class": cls.group(1) if cls else "",
        "extends": cls.group(2) if cls and cls.group(2) else "",
        "properties": [],
        "actions": [],
        "topics": [],
        "dropped": [],
    }
    for m in _DECL.finditer(text):
        kind, name = m.group(1), m.group(2)
        args = _call_args(_balanced_call(text, m.end()))
        if not args:
            out["dropped"].append(name)   # a declaration we could not parse: counted by the caller, never silent
            continue
        flags, letters, unknown = decode_flags(_clean(args[0]))
        rec = {"name": name, "flags": flags, "flagLetters": "".join(letters), "args": [_clean(a) for a in args]}
        if unknown:
            # Surfaced, never dropped: the int/letters above are then a LOWER BOUND for this slot.
            rec["unknownFlags"] = unknown
        rec["default"], rec["facets"] = _default_and_facets(kind, args)
        out[{"Property": "properties", "Action": "actions", "Topic": "topics"}[kind]].append(rec)
    return out


def _warn(msg):
    print("n4-type-catalog: warning: " + msg, file=sys.stderr)


def build_catalog(roots, stats=None):
    """Walk roots (sorted, so first-wins on a duplicate type is deterministic); return {type: record}.

    `stats` (dict) receives java_files, unreadable, duplicates, unknown_flag_tokens, dropped_declarations and
    no_class_files so callers can prove the instrument looked (anti-silent-zero).
    """
    st = stats if stats is not None else {}
    for k in ("java_files", "read_files", "unreadable", "duplicates", "unknown_flag_tokens",
              "dropped_declarations", "no_class_files"):
        st.setdefault(k, 0)

    def walk_error(e):
        st["unreadable"] += 1
        _warn("cannot read directory %s: %s" % (e.filename, e))

    cat = {}
    for root in roots:
        for dp, dn, files in os.walk(root, onerror=walk_error):
            dn.sort()
            for fn in sorted(files):
                if not fn.endswith(".java"):
                    continue
                path = os.path.join(dp, fn)
                st["java_files"] += 1
                if not os.path.isfile(path):    # FIFO/device would block; dangling symlink cannot be read
                    st["unreadable"] += 1
                    _warn("not a regular file, skipped: %s" % path)
                    continue
                try:
                    with open(path, encoding="utf-8", errors="replace") as fh:
                        t = parse_source(fh.read())
                except OSError as e:
                    st["unreadable"] += 1
                    _warn("cannot read %s: %s" % (path, e))
                    continue
                st["read_files"] += 1
                for name in t.pop("dropped"):
                    st["dropped_declarations"] += 1
                    _warn("unparseable slot declaration '%s' dropped in %s" % (name, path))
                has_slots = bool(t["properties"] or t["actions"] or t["topics"])
                if has_slots and not t["class"]:
                    st["no_class_files"] += 1
                    _warn("slot declarations but no class declaration, skipped: %s" % path)
                    continue
                if not has_slots:
                    continue
                t["source"] = path
                key = (t["package"] + "." if t["package"] else "") + t["class"]
                if key in cat:
                    st["duplicates"] += 1
                    continue    # a dropped duplicate is not in the catalog: its tokens are not counted either
                for label in ("properties", "actions", "topics"):
                    for it in t[label]:
                        for tok in it.get("unknownFlags", ()):
                            st["unknown_flag_tokens"] += 1
                            _warn("unknown flag token '%s' in %s (slot %s)" % (tok, path, it["name"]))
                cat[key] = t
    return cat


def _degraded(stats, roots):
    """Message when the read was degraded (some entries unreadable, NO .java file readable), else None.

    Distinct from empty-input and no-match: the instrument could not look, so a zero says nothing.
    """
    if stats["unreadable"] > 0 and stats["read_files"] == 0:
        return ("n4-type-catalog: degraded — %d unreadable entr%s, 0 .java files readable under: %s; "
                "no catalog produced" % (stats["unreadable"], "y" if stats["unreadable"] == 1 else "ies",
                                         " ".join(roots)))
    return None


_SLOT_KEYS = ("name", "flags", "flagLetters", "default", "facets")


def _validate_catalog(cat):
    """Raise ValueError unless `cat` has the shape `build` emits (what `show` dereferences)."""
    if not isinstance(cat, dict):
        raise ValueError("catalog must be a JSON object keyed by type, got %s" % type(cat).__name__)
    for k, t in cat.items():
        if not isinstance(t, dict):
            raise ValueError("entry %r is not an object" % k)
        for key in ("extends", "properties", "actions", "topics"):
            if key not in t:
                raise ValueError("entry %r lacks '%s'" % (k, key))
        for label in ("properties", "actions", "topics"):
            if not isinstance(t[label], list):
                raise ValueError("entry %r: '%s' is not a list" % (k, label))
            for it in t[label]:
                if not isinstance(it, dict) or any(f not in it for f in _SLOT_KEYS):
                    raise ValueError("entry %r: a %s slot is not an object with %s" % (k, label, "/".join(_SLOT_KEYS)))


def _load_catalog(arg):
    """Return (catalog, stats|None); stats is set only when `arg` is a source directory built on the fly."""
    if os.path.isdir(arg):
        stats = {}
        return build_catalog([arg], stats), stats
    with open(arg, encoding="utf-8") as fh:
        cat = json.load(fh)
    _validate_catalog(cat)
    return cat, None


def _show(cat, name):
    if not cat:
        print("n4-type-catalog: no types catalogued (empty catalog); cannot show %s" % name, file=sys.stderr)
        return 1
    hits = sorted(k for k in cat if k == name or k.endswith("." + name))
    if not hits:
        print("no such type: %s" % name, file=sys.stderr)
        return 1
    for k in hits:
        t = cat[k]
        print("%s  extends %s   (%s)" % (k, t["extends"], t.get("source", "")))
        for label, items in (("property", t["properties"]), ("action", t["actions"]), ("topic", t["topics"])):
            for it in items:
                print("  %-8s %-24s flags=%-6s %-8s default=%s facets=%s"
                      % (label, it["name"], it["flags"], it["flagLetters"], it["default"], it["facets"]))
    return 0


def _build(args):
    for root in args.dirs:
        if not os.path.isdir(root):
            print("n4-type-catalog: not a directory: %s" % root, file=sys.stderr)
            return 2
    stats = {}
    cat = build_catalog(args.dirs, stats)
    files_seen = stats["java_files"]
    degraded = _degraded(stats, args.dirs)
    if degraded:
        print(degraded, file=sys.stderr)
        return 2
    if files_seen == 0:
        print("n4-type-catalog: no .java files under: %s" % " ".join(args.dirs), file=sys.stderr)
        return 1
    if not cat:
        print("n4-type-catalog: no slot declarations found in %d .java file(s) under: %s"
              % (files_seen, " ".join(args.dirs)), file=sys.stderr)
        return 1
    summary = ("types: %d  properties: %d  actions: %d  topics: %d  java-files: %d  "
               "unknown-flag-tokens: %d  duplicates: %d  unreadable: %d  dropped-declarations: %d  no-class-files: %d" % (
                   len(cat),
                   sum(len(t["properties"]) for t in cat.values()),
                   sum(len(t["actions"]) for t in cat.values()),
                   sum(len(t["topics"]) for t in cat.values()),
                   files_seen, stats["unknown_flag_tokens"], stats["duplicates"], stats["unreadable"],
                   stats["dropped_declarations"], stats["no_class_files"]))
    data = json.dumps(cat, indent=1, sort_keys=True)
    if args.out:
        # temp file + rename: a failed or interrupted write never leaves a truncated catalog at --out
        tmp = "%s.tmp.%d" % (args.out, os.getpid())
        try:
            with open(tmp, "w", encoding="utf-8") as fh:
                fh.write(data)
            os.replace(tmp, args.out)
        except OSError as e:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            print("n4-type-catalog: cannot write %s: %s" % (args.out, e), file=sys.stderr)
            return 2
        print(summary)
    else:
        print(data)
        print(summary, file=sys.stderr)
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("build")
    b.add_argument("dirs", nargs="+")
    b.add_argument("--out")
    s = sub.add_parser("show")
    s.add_argument("catalog")
    s.add_argument("type")
    args = ap.parse_args(argv)
    if args.cmd == "build":
        return _build(args)
    if args.cmd == "show":
        try:
            cat, stats = _load_catalog(args.catalog)
        except (OSError, ValueError, RecursionError) as e:
            print("n4-type-catalog: cannot load catalog %s: %s" % (args.catalog, e), file=sys.stderr)
            return 2
        degraded = _degraded(stats, [args.catalog]) if stats is not None else None
        if degraded:
            print(degraded, file=sys.stderr)
            return 2
        return _show(cat, args.type)
    return 2


if __name__ == "__main__":
    sys.exit(main())
