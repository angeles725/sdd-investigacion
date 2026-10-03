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
2 usage error, absent root, or unreadable catalog.
Provenance rule: a catalog entry is `[CERT]`-grade only for the file/line it was parsed from; inherited slots
are NOT merged (use `extends` to walk), and a type with no declarations is omitted.
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


def _split_args(s):
    """Split a call-argument string at top-level commas (respecting parens and string literals)."""
    args, depth, cur, i, n = [], 0, [], 0, len(s)
    in_str = None
    while i < n:
        c = s[i]
        if in_str:
            cur.append(c)
            if c == "\\" and i + 1 < n:
                cur.append(s[i + 1])
                i += 1
            elif c == in_str:
                in_str = None
        elif c in "\"'":
            in_str = c
            cur.append(c)
        elif c in "([{":
            depth += 1
            cur.append(c)
        elif c in ")]}":
            depth -= 1
            cur.append(c)
        elif c == "," and depth == 0:
            args.append("".join(cur).strip())
            cur = []
        else:
            cur.append(c)
        i += 1
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
    depth, i, n = 0, start, len(text)
    in_str = None
    while i < n:
        c = text[i]
        if in_str:
            if c == "\\":
                i += 1
            elif c == in_str:
                in_str = None
        elif c in "\"'":
            in_str = c
        elif c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
        elif c == ";" and depth == 0:
            return text[start:i]
        i += 1
    return text[start:]


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
    }
    for m in _DECL.finditer(text):
        kind, name = m.group(1), m.group(2)
        expr = _balanced_call(text, m.end())
        call = re.search(r"new(Property|Action|Topic)\s*\(", expr)
        if not call:
            continue
        inner_start = call.end()
        # inner = text up to the matching ')' of the call
        depth, j, inner = 1, inner_start, None
        in_str = None
        while j < len(expr):
            c = expr[j]
            if in_str:
                if c == "\\":
                    j += 1
                elif c == in_str:
                    in_str = None
            elif c in "\"'":
                in_str = c
            elif c == "(":
                depth += 1
            elif c == ")":
                depth -= 1
                if depth == 0:
                    inner = expr[inner_start:j]
                    break
            j += 1
        if inner is None:
            continue
        args = _split_args(inner)
        if not args:
            continue
        flags, letters, unknown = decode_flags(_clean(args[0]))
        rec = {"name": name, "flags": flags, "flagLetters": "".join(letters), "args": [_clean(a) for a in args]}
        if unknown:
            # Surfaced, never dropped: the int/letters above are then a LOWER BOUND for this slot.
            rec["unknownFlags"] = unknown
        if kind == "Property":
            rec["default"] = _clean(args[1]) if len(args) > 1 else ""
            rec["facets"] = _clean(args[2]) if len(args) > 2 else "null"
            out["properties"].append(rec)
        elif kind == "Action":
            if len(args) == 2:     # newAction(flags, facets): no parameter
                rec["default"] = ""
                rec["facets"] = _clean(args[1])
            else:
                rec["default"] = _clean(args[1]) if len(args) > 1 else ""
                rec["facets"] = _clean(args[-1]) if len(args) > 2 else "null"
            out["actions"].append(rec)
        else:
            if len(args) == 2:
                rec["default"] = ""
                rec["facets"] = _clean(args[1])
            else:
                rec["default"] = _clean(args[1]) if len(args) > 1 else ""
                rec["facets"] = _clean(args[-1]) if len(args) > 2 else "null"
            out["topics"].append(rec)
    return out


def build_catalog(roots, stats=None):
    """Walk roots (sorted, so first-wins on a duplicate type is deterministic); return {type: record}.

    `stats` (dict) receives java_files, unreadable, duplicates, unknown_flag_tokens so callers can prove
    the instrument looked (anti-silent-zero).
    """
    st = stats if stats is not None else {}
    for k in ("java_files", "unreadable", "duplicates", "unknown_flag_tokens"):
        st.setdefault(k, 0)
    cat = {}
    for root in roots:
        for dp, dn, files in os.walk(root):
            dn.sort()
            for fn in sorted(files):
                if not fn.endswith(".java"):
                    continue
                path = os.path.join(dp, fn)
                st["java_files"] += 1
                try:
                    with open(path, encoding="utf-8", errors="replace") as fh:
                        t = parse_source(fh.read())
                except OSError as e:
                    st["unreadable"] += 1
                    print("n4-type-catalog: warning: cannot read %s: %s" % (path, e), file=sys.stderr)
                    continue
                if not (t["properties"] or t["actions"] or t["topics"]) or not t["class"]:
                    continue
                t["source"] = path
                for label in ("properties", "actions", "topics"):
                    for it in t[label]:
                        for tok in it.get("unknownFlags", ()):
                            st["unknown_flag_tokens"] += 1
                            print("n4-type-catalog: warning: unknown flag token '%s' in %s (slot %s)"
                                  % (tok, path, it["name"]), file=sys.stderr)
                key = (t["package"] + "." if t["package"] else "") + t["class"]
                if key in cat:
                    st["duplicates"] += 1
                else:
                    cat[key] = t
    return cat


def _load_catalog(arg):
    if os.path.isdir(arg):
        return build_catalog([arg])
    with open(arg, encoding="utf-8") as fh:
        return json.load(fh)


def _show(cat, name):
    hits = [k for k in cat if k == name or k.endswith("." + name)]
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
    if files_seen == 0:
        print("n4-type-catalog: no .java files under: %s" % " ".join(args.dirs), file=sys.stderr)
        return 1
    if not cat:
        print("n4-type-catalog: no slot declarations found in %d .java file(s) under: %s"
              % (files_seen, " ".join(args.dirs)), file=sys.stderr)
        return 1
    summary = ("types: %d  properties: %d  actions: %d  topics: %d  java-files: %d  "
               "unknown-flag-tokens: %d  duplicates: %d  unreadable: %d" % (
                   len(cat),
                   sum(len(t["properties"]) for t in cat.values()),
                   sum(len(t["actions"]) for t in cat.values()),
                   sum(len(t["topics"]) for t in cat.values()),
                   files_seen, stats["unknown_flag_tokens"], stats["duplicates"], stats["unreadable"]))
    data = json.dumps(cat, indent=1, sort_keys=True)
    if args.out:
        with open(args.out, "w", encoding="utf-8") as fh:
            fh.write(data)
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
            cat = _load_catalog(args.catalog)
        except (OSError, ValueError) as e:
            print("n4-type-catalog: cannot load catalog %s: %s" % (args.catalog, e), file=sys.stderr)
            return 2
        return _show(cat, args.type)
    return 2


if __name__ == "__main__":
    sys.exit(main())
