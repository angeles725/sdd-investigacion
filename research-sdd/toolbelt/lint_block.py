#!/usr/bin/env python3
"""lint_block.py — rule engine behind lint-block.sh (kit issue #1206, slice 1).

Mechanically enforces the GENERIC block-writing rules that prose already failed to hold. The
rule set here is deliberately the *generic core* only: a rule is in the core when its trigger and
its clearing evidence are expressed in kit vocabulary (METHODOLOGY markers, `[Block N]`, Self-verify
tables) and not in the vocabulary of one target (jar names, N4/N5 baselines, one corpus's
`coverage-check:` clause convention).

Core rules
  R0  waiver hygiene: a `<!-- lint-waive: ... -->` token that names no rule or carries no reason.
      An invalid waiver never suppresses anything (fail closed) and is itself a finding.
  R3  ephemeral evidence: a Self-verify row/item marked [CERT-hw] or [CERT-live] whose cited
      evidence is only a /tmp (or scratchpad) path — a session-local file nobody can re-open.
  R6  cross-block comparison: a clause of the form "[Block N] ... does not mention/show/contain/
      include ..." in a paragraph or table row that cites no raw artifact path.

Rule ids R3/R6 keep the numbering of the reference implementation so waivers stay stable when the
per-target packs (slice 2) add the remaining ids. Extension point: RULES (a registry of
`(rule_id, fn)` pairs, `fn(doc) -> [(line, rule_id, message)]`); a pack appends to it.

Waiver (per unit)
  <!-- lint-waive: R3 reason=free text explaining why -->
  Placed on any line of the flagged paragraph / table row. Without a non-empty `reason=` the token
  is an R0 finding and does NOT waive.

Usage (normally via lint-block.sh, which resolves the file list):
  lint_block.py [--audit] --files-from -        newline-delimited paths on stdin
  lint_block.py [--audit] FILE...

Modes
  default  FAIL mode: exit 1 when any finding remains.
  --audit  report-only: exit 0 with counts regardless of findings.
Exit: 0 clean (or --audit) · 1 findings (FAIL mode) · 2 operational error (unreadable file, bad args).
Output is anti-silent-zero: every run ends with a SUMMARY line that names how many files were read,
how many were empty, and the coverage counters (how many Self-verify sections / rows R3 actually
inspected, how many R6 trigger clauses were seen) — a zero finding count can always be told apart
from "the instrument never saw anything to look at".
"""
import re
import sys
from collections import namedtuple

Unit = namedtuple("Unit", "text line kind header")  # kind: para | row | header | heading

TABLE_ROW_RE = re.compile(r"^\s*\|(.+)\|\s*$")
TABLE_SEP_RE = re.compile(r"^\s*\|[\s:|-]+\|\s*$")
LIST_ITEM_RE = re.compile(r"^\s*(?:\d+\.|[-*])\s+")
HEADING_RE = re.compile(r"^\s*(#{1,6})\s*(.*)$")
BLOCKQUOTE_RE = re.compile(r"^\s*>\s?")
FENCE_RE = re.compile(r"^\s*(```|~~~)")


def _dequote(line):
    return BLOCKQUOTE_RE.sub("", line, count=1)


def split_row_cells(row_text):
    inner = row_text.strip()
    if inner.startswith("|"):
        inner = inner[1:]
    if inner.endswith("|"):
        inner = inner[:-1]
    return [c.strip() for c in inner.split("|")]


def extract_units(lines):
    """Split into paragraph/list-item, table-row, table-header and heading units.

    Fenced code blocks are skipped (their content is quoted material, not the block's own claims).
    A table row followed by a separator line becomes a `header` unit; the rows after it carry it.
    A leading blockquote marker is stripped first so a header blockquote behaves like prose.
    """
    units = []
    buf = []
    buf_start = None
    fence = False
    header = None

    def flush():
        nonlocal buf, buf_start
        if buf:
            units.append(Unit(" ".join(buf).strip(), buf_start, "para", None))
        buf = []
        buf_start = None

    for i, raw in enumerate(lines, start=1):
        content = _dequote(raw)
        if FENCE_RE.match(content):
            flush()
            header = None
            fence = not fence
            continue
        if fence:
            continue
        stripped = content.strip()
        if not stripped:
            flush()
            header = None
            continue
        if TABLE_SEP_RE.match(content):
            flush()
            if units and units[-1].kind == "row" and units[-1].line == i - 1:
                prev = units.pop()
                header = split_row_cells(prev.text)
                units.append(Unit(prev.text, prev.line, "header", None))
            continue
        if TABLE_ROW_RE.match(content):
            flush()
            units.append(Unit(stripped, i, "row", header))
            continue
        header = None
        if HEADING_RE.match(content):
            flush()
            units.append(Unit(stripped, i, "heading", None))
            continue
        if LIST_ITEM_RE.match(content) and buf:
            flush()
        if buf_start is None:
            buf_start = i
        buf.append(stripped)
    flush()
    return units


def heading_sections(lines):
    """[(start_line, end_line_exclusive, title)] for every heading-delimited section."""
    starts = []
    fence = False
    for i, raw in enumerate(lines, start=1):
        content = _dequote(raw)
        if FENCE_RE.match(content):
            fence = not fence
            continue
        if fence:
            continue
        m = HEADING_RE.match(content)
        if m:
            starts.append((i, m.group(2)))
    out = []
    for idx, (start, title) in enumerate(starts):
        end = starts[idx + 1][0] if idx + 1 < len(starts) else len(lines) + 1
        out.append((start, end, title))
    return out


def lines_in_sections(sections, title_pattern):
    pat = re.compile(title_pattern, re.IGNORECASE)
    out = set()
    sec_count = 0
    for start, end, title in sections:
        if pat.search(title):
            sec_count += 1
            out.update(range(start, end))
    return out, sec_count


def excerpt(text, n=100):
    text = " ".join(text.split())
    return text if len(text) <= n else text[: n - 1] + "..."


# ---------------------------------------------------------------------------
# Waivers
# ---------------------------------------------------------------------------
WAIVER_TOKEN_RE = re.compile(r"<!--\s*lint-waive:(.*?)-->", re.IGNORECASE | re.DOTALL)
WAIVER_BODY_RE = re.compile(r"^\s*(R\d+)\b\s*(.*)$", re.DOTALL)
WAIVER_REASON_RE = re.compile(r"^reason=(.*)$", re.DOTALL)


class Doc:
    """One parsed block file plus the per-run coverage counters rules bump."""

    def __init__(self, path, text):
        self.path = path
        # Strip bold markers before matching: emphasis inside a trigger phrase ("does **not** ship")
        # would otherwise split it. Line count and every other character are untouched.
        self.lines = text.replace("**", "").splitlines()
        self.units = extract_units(self.lines)
        self.sections = heading_sections(self.lines)
        self.cov = {"selfverify_sections": 0, "cert_hw_live_items": 0, "r6_trigger_clauses": 0}
        self.valid_waivers = []   # [(line, rule)]
        self.r0 = []              # [(line, "R0", msg)]
        self._parse_waivers()

    def _parse_waivers(self):
        for i, raw in enumerate(self.lines, start=1):
            for m in WAIVER_TOKEN_RE.finditer(raw):
                body = m.group(1)
                bm = WAIVER_BODY_RE.match(body)
                if not bm:
                    self.r0.append((i, "R0", "waiver names no rule id (expected `R<n> reason=...`): "
                                    + excerpt(m.group(0))))
                    continue
                rule, rest = bm.group(1).upper(), bm.group(2).strip()
                rm = WAIVER_REASON_RE.match(rest)
                reason = rm.group(1).strip() if rm else ""
                if not reason:
                    self.r0.append((i, "R0", f"waiver for {rule} has no `reason=` text; it does NOT waive"))
                    continue
                self.valid_waivers.append((i, rule))

    def waived(self, rule, unit):
        """A valid waiver for `rule` on any physical line of the unit."""
        first = unit.line
        last = self._unit_end(unit)  # paragraph units are space-joined: recover the raw-line extent
        return any(r == rule and first <= ln <= last for ln, r in self.valid_waivers)

    def _unit_end(self, unit):
        if unit.kind in ("row", "header", "heading"):
            return unit.line
        end = unit.line
        for ln in range(unit.line + 1, len(self.lines) + 1):
            raw = _dequote(self.lines[ln - 1])
            if (not raw.strip() or TABLE_ROW_RE.match(raw) or HEADING_RE.match(raw)
                    or LIST_ITEM_RE.match(raw) or FENCE_RE.match(raw)):
                break
            end = ln
        return end


# ---------------------------------------------------------------------------
# R3 — ephemeral evidence in Self-verify
# ---------------------------------------------------------------------------
R3_MARKER_RE = re.compile(r"\[CERT-hw\]|\[CERT-live\]")
R3_SECTION_RE = r"self[- ]?verif"
# An ephemeral location: a path (or a shell variable) that does not outlive the session.
R3_EPHEMERAL_RE = re.compile(r"/tmp/|/var/tmp/|/private/tmp/|/dev/shm/|\$\{?TMPDIR\}?|scratchpad", re.IGNORECASE)
R3_TOKEN_RE = re.compile(r"[^\s`\"'()]+")
# A durable citation: a repo-style path (contains "/", not ephemeral), a `file.ext:LINE` cite, or a
# block reference (`B28`, `bloque28`, `block28`).
R3_FILELINE_RE = re.compile(r"^[\w.+-]+\.\w{1,6}:\d+")
R3_BLOCKREF_RE = re.compile(r"\b(?:B|bloque|block)[- ]?\d+\b", re.IGNORECASE)


def _is_durable_token(tok):
    tok = tok.rstrip(".,;:")
    if R3_EPHEMERAL_RE.search(tok):
        return False
    return "/" in tok or bool(R3_FILELINE_RE.match(tok)) or bool(R3_BLOCKREF_RE.search(tok))


def rule_r3(doc):
    sv, nsec = lines_in_sections(doc.sections, R3_SECTION_RE)
    doc.cov["selfverify_sections"] = nsec
    out = []
    for u in doc.units:
        if u.kind not in ("row", "para") or u.line not in sv:
            continue
        if u.kind == "row":
            cells = split_row_cells(u.text)
            idx = next((k for k, c in enumerate(cells) if R3_MARKER_RE.search(c)), None)
            if idx is None:
                continue
            evidence = " ".join(cells[idx + 1:])
        else:
            m = R3_MARKER_RE.search(u.text)
            if not m:
                continue
            evidence = u.text[m.end():]
        doc.cov["cert_hw_live_items"] += 1
        if not R3_EPHEMERAL_RE.search(evidence):
            continue
        if any(_is_durable_token(t) for t in R3_TOKEN_RE.findall(evidence)):
            continue
        if doc.waived("R3", u):
            continue
        out.append((u.line, "R3", "[CERT-hw]/[CERT-live] evidence cites only an ephemeral path: "
                    + excerpt(evidence)))
    return out


# ---------------------------------------------------------------------------
# R6 — cross-block comparison without the other block's raw artifact
# ---------------------------------------------------------------------------
# The verdict must be ABOUT the block: `[Block N]` is the (near) subject of "does not mention/show/
# contain/include". At most 80 characters, with no sentence/clause boundary or dash between them
# (\u2014 em dash, \u2013 en dash) — a block reference merely sitting in the same sentence as an
# unrelated "never shows" is not a comparison claim (measured: 2 of 3 non-fixture hits in the
# first, looser version were that shape).
R6_CLAIM_RE = re.compile(
    r"\[Block\s*\d+\](?:[^.;\u2014\u2013\n]|\.(?=\S)){0,80}?\b(?:does not|doesn't|never)\s+(?:mention|show|contain|include)s?\b",
    re.IGNORECASE)
R6_RAW_PATH_RE = re.compile(r"evidence/|[\w./-]*/[\w.-]+\.\w{1,6}")


def rule_r6(doc):
    out = []
    for u in doc.units:
        if u.kind not in ("para", "row"):
            continue
        # The claim regex keeps `[Block N]` and the verdict in one clause (no `.`/`;`/dash between
        # them). The clearing raw artifact path may sit anywhere in the unit: it routinely lives in
        # a neighbouring clause.
        m = R6_CLAIM_RE.search(u.text)
        if m is None:
            continue
        hit = m.group(0)
        doc.cov["r6_trigger_clauses"] += 1
        if R6_RAW_PATH_RE.search(u.text):
            continue
        if doc.waived("R6", u):
            continue
        out.append((u.line, "R6", "comparison against another block without citing its raw artifact: "
                    + excerpt(hit)))
    return out


# Extension point (slice 2): per-target rule packs append `(rule_id, fn)` here.
RULES = [("R3", rule_r3), ("R6", rule_r6)]
RULE_IDS = [r for r, _ in RULES]


def lint_text(path, text):
    """Return (findings, coverage) for one document; findings = sorted [(line, rule, message)]."""
    doc = Doc(path, text)
    findings = list(doc.r0)
    for _rid, fn in RULES:
        findings.extend(fn(doc))
    findings.sort(key=lambda f: (f[0], f[1]))
    return findings, doc.cov


def main(argv):
    audit = False
    files_from_stdin = False
    files = []
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--audit":
            audit = True
        elif a == "--files-from":
            i += 1
            if i >= len(argv) or argv[i] != "-":
                print("lint-block: --files-from only supports '-' (stdin)", file=sys.stderr)
                return 2
            files_from_stdin = True
        elif a.startswith("-") and a != "-":
            print(f"lint-block: unknown option: {a}", file=sys.stderr)
            return 2
        else:
            files.append(a)
        i += 1
    if files_from_stdin:
        files.extend(ln for ln in sys.stdin.read().split("\n") if ln)
    if not files:
        print("lint-block: no input files", file=sys.stderr)
        return 2

    counts = {r: 0 for r in ["R0"] + RULE_IDS}
    cov = {"selfverify_sections": 0, "cert_hw_live_items": 0, "r6_trigger_clauses": 0}
    read = empty = unreadable = total = 0
    for path in files:
        try:
            with open(path, "r", encoding="utf-8") as fh:
                text = fh.read()
        except (OSError, UnicodeDecodeError) as exc:
            print(f"UNREADABLE {path}: {exc}", file=sys.stderr)
            unreadable += 1
            continue
        read += 1
        if not text.strip():
            empty += 1
            print(f"EMPTY-INPUT {path}")
            continue
        findings, c = lint_text(path, text)
        for k in cov:
            cov[k] += c[k]
        for line, rule, msg in findings:
            print(f"{rule} {path}:{line}: {msg}")
            counts[rule] = counts.get(rule, 0) + 1
            total += 1

    mode = "AUDIT" if audit else "LINT"
    per_rule = " ".join(f"{r}={counts.get(r, 0)}" for r in ["R0"] + RULE_IDS)
    print(f"SUMMARY {mode} files={read} empty={empty} unreadable={unreadable} findings={total} {per_rule} "
          f"| inspected: selfverify-sections={cov['selfverify_sections']} "
          f"cert-hw-live-items={cov['cert_hw_live_items']} r6-trigger-clauses={cov['r6_trigger_clauses']}")
    if unreadable:
        return 2
    if read - empty == 0:
        print("EMPTY-INPUT: every given file was empty; nothing was linted")
    elif total == 0:
        print("NO-MATCH: files were read and inspected; no rule fired")
    if audit:
        return 0
    return 1 if total else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
