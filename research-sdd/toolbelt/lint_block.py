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
  R3  ephemeral evidence: a Self-verify table row or list item (not prose) marked [CERT-hw] or [CERT-live] whose cited
      evidence is only a /tmp (or scratchpad) path — a session-local file nobody can re-open.
      Also (slice 2): an inline `[CERT-hw] (<evidence>)` group OUTSIDE Self-verify sections, in prose,
      list items and table cells, when the parenthetical directly after the marker cites only an
      ephemeral path. Prose INSIDE Self-verify sections stays out of scope (known gap).
  R6  cross-block comparison: a clause of the form "[Block N] ... does not mention/show/contain/
      include/cite ..." in a paragraph or table row that cites no raw artifact path.

Rule ids R3/R6 keep the numbering of the reference implementation so waivers stay stable when the
per-target packs (slice 2) add the remaining ids. Extension point: RULES (a registry of
`(rule_id, fn)` pairs, `fn(doc) -> [(line, rule_id, message)]`); a pack appends to it.

Waiver (per unit)
  <!-- lint-waive: R3 reason=free text explaining why -->
  Placed on any line of the flagged paragraph / table row. Without a non-empty `reason=` the token
  is an R0 finding and does NOT waive; so is an unknown or lower-case rule id. The reference
  implementation's spelling `<!-- lint-ok: R3 free text reason -->` is accepted as an alias.
  Waiver-shaped text inside a code fence is quoted material and is not parsed.

Waivers for reserved pack rule ids (R1 R2 R4 R5 R7 R8 R9) are INFO, counted as `inactive-waivers=`.

Warnings (never change the exit code, counted as `warn=` in SUMMARY)
  WARN path:LINE: unclosed code fence — everything after it is hidden from the rules.

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

Unit = namedtuple("Unit", "text line kind")  # kind: para | item (list item) | row | header | heading

TABLE_ROW_RE = re.compile(r"^\s*\|(.+)\|\s*$")
TABLE_SEP_RE = re.compile(r"^\s*\|[\s:|-]+\|\s*$")
LIST_ITEM_RE = re.compile(r"^\s*(?:\d+\.|[-*])\s+")
# ATX heading: 1-6 `#` followed by whitespace or end of line ("#1 priority" / "#hashtag" are prose).
HEADING_RE = re.compile(r"^\s*(#{1,6})(?:\s+(.*))?$")
BLOCKQUOTE_RE = re.compile(r"^\s*>\s?")
FENCE_OPEN_RE = re.compile(r"^\s*(`{3,}|~{3,})")


def _dequote(line):
    return BLOCKQUOTE_RE.sub("", line, count=1)


def heading_title(line):
    m = HEADING_RE.match(line)
    return (m.group(2) or "") if m else None


def scan_fences(lines):
    """Return (fenced_lines, unclosed) for a document.

    CommonMark rules: a fence opens with 3+ backticks or tildes and closes only with the SAME
    character, at least as long, and nothing else on the line (so a `~~~` line inside a ``` fence
    is content). `fenced_lines` is the set of 1-based lines inside a fence, fence lines included;
    `unclosed` is [(opening_line, lines_hidden)] for a fence that never closes: everything after it
    is hidden from the linter, which the caller must surface rather than skip silently.
    """
    fenced = set()
    unclosed = []
    open_ch, open_len, open_line = None, 0, 0
    for i, raw in enumerate(lines, start=1):
        content = _dequote(raw)
        if open_ch is None:
            m = FENCE_OPEN_RE.match(content)
            if m:
                open_ch, open_len, open_line = m.group(1)[0], len(m.group(1)), i
                fenced.add(i)
            continue
        fenced.add(i)
        st = content.strip()
        if st and set(st) == {open_ch} and len(st) >= open_len:
            open_ch = None
    if open_ch is not None:
        unclosed.append((open_line, len(lines) - open_line))
    return fenced, unclosed


def split_row_cells(row_text):
    inner = row_text.strip()
    if inner.startswith("|"):
        inner = inner[1:]
    if inner.endswith("|"):
        inner = inner[:-1]
    return [c.strip() for c in inner.split("|")]


def extract_units(lines, fenced):
    """Split into paragraph/list-item, table-row, table-header and heading units.

    Lines inside a fence are skipped (quoted material, not the block's own claims). A table row
    followed by a separator line becomes a `header` unit. A leading blockquote marker is stripped
    first so a header blockquote behaves like prose.
    """
    units = []
    buf = []
    buf_start = None
    buf_kind = "para"

    def flush():
        nonlocal buf, buf_start, buf_kind
        if buf:
            units.append(Unit(" ".join(buf).strip(), buf_start, buf_kind))
        buf = []
        buf_start = None
        buf_kind = "para"

    for i, raw in enumerate(lines, start=1):
        if i in fenced:
            flush()
            continue
        content = _dequote(raw)
        stripped = content.strip()
        if not stripped:
            flush()
            continue
        if TABLE_SEP_RE.match(content):
            flush()
            if units and units[-1].kind == "row" and units[-1].line == i - 1:
                prev = units.pop()
                units.append(Unit(prev.text, prev.line, "header"))
            continue
        if TABLE_ROW_RE.match(content):
            flush()
            units.append(Unit(stripped, i, "row"))
            continue
        if HEADING_RE.match(content):
            flush()
            units.append(Unit(stripped, i, "heading"))
            continue
        if LIST_ITEM_RE.match(content) and buf:
            flush()
        if buf_start is None:
            buf_start = i
            buf_kind = "item" if LIST_ITEM_RE.match(content) else "para"
        buf.append(stripped)
    flush()
    return units


def heading_sections(lines, fenced):
    """[(start_line, end_line_exclusive, title)] for every heading-delimited section."""
    starts = []
    for i, raw in enumerate(lines, start=1):
        if i in fenced:
            continue
        title = heading_title(_dequote(raw))
        if title is not None:
            starts.append((i, title))
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
# `lint-waive: R<n> reason=...` is the kit form; `lint-ok: R<n> <reason>` is accepted as an alias
# for the reference implementation's token. Tokens inside a fence are quoted material, not parsed.
WAIVER_TOKEN_RE = re.compile(r"<!--\s*lint-(waive|ok):(.*?)-->", re.IGNORECASE | re.DOTALL)
WAIVER_BODY_RE = re.compile(r"^\s*(R\d+)\b\s*(.*)$", re.DOTALL | re.IGNORECASE)
WAIVER_REASON_RE = re.compile(r"^reason=(.*)$", re.DOTALL)


class Doc:
    """One parsed block file plus the per-run coverage counters rules bump."""

    def __init__(self, text):
        # Strip bold markers before matching: emphasis inside a trigger phrase ("does **not** ship")
        # would otherwise split it. Line count and every other character are untouched.
        self.lines = text.replace("**", "").splitlines()
        self.fenced, self.unclosed = scan_fences(self.lines)
        self.units = extract_units(self.lines, self.fenced)
        self.sections = heading_sections(self.lines, self.fenced)
        self.cov = {"selfverify_sections": 0, "cert_hw_live_items": 0, "r6_trigger_clauses": 0,
                    "cert_inline_items": 0}
        self.valid_waivers = []   # [(line, rule)]
        self.r0 = []              # [(line, "R0", msg)]
        self.infos = []           # [(line, msg)] — inactive-pack-rule waivers
        self.warns = [(ln, f"unclosed code fence: {hidden} following line(s) were NOT linted")
                      for ln, hidden in self.unclosed]
        self._parse_waivers()

    def _parse_waivers(self):
        for i, raw in enumerate(self.lines, start=1):
            if i in self.fenced:
                continue
            for m in WAIVER_TOKEN_RE.finditer(raw):
                alias = m.group(1).lower() == "ok"
                bm = WAIVER_BODY_RE.match(m.group(2))
                if not bm:
                    self.r0.append((i, "R0", "waiver names no rule id (expected `R<n> reason=...`): "
                                    + excerpt(m.group(0))))
                    continue
                raw_id, rest = bm.group(1), bm.group(2).strip()
                rule = raw_id.upper()
                if raw_id != rule:
                    self.r0.append((i, "R0", f"waiver rule id must be upper-case ({rule}, not {raw_id}); it does NOT waive"))
                    continue
                inactive = rule in RESERVED_PACK_RULE_IDS and rule not in RULE_IDS
                if rule not in RULE_IDS and not inactive:
                    self.r0.append((i, "R0", f"waiver names unknown rule {rule} (active: {', '.join(RULE_IDS)}); it does NOT waive"))
                    continue
                rm = WAIVER_REASON_RE.match(rest)
                reason = rm.group(1).strip() if rm else (rest if alias else "")
                if not reason:
                    self.r0.append((i, "R0", f"waiver for {rule} has no reason text; it does NOT waive"))
                    continue
                if inactive:
                    self.infos.append((i, f"waiver for inactive pack rule {rule} (not enforced by the generic core)"))
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
            if (ln in self.fenced or not raw.strip() or TABLE_ROW_RE.match(raw) or HEADING_RE.match(raw)
                    or LIST_ITEM_RE.match(raw)):
                break
            end = ln
        return end


# ---------------------------------------------------------------------------
# R3 — ephemeral evidence in Self-verify
# ---------------------------------------------------------------------------
# Hyphen variants seen in real blocks: U+2010 hyphen, U+2011 non-breaking hyphen, U+2012 figure
# dash, U+2013 en dash, plain `-`, or a space / nothing.
_HY = "[-‐‑‒– ]"
R3_MARKER_RE = re.compile(r"\[CERT" + _HY + r"?(?:hw|live)\]", re.IGNORECASE)
R3_SECTION_RE = r"self" + _HY + r"?verif"
# An ephemeral location: a path (or a shell variable) that does not outlive the session.
R3_EPHEMERAL_RE = re.compile(r"/tmp/|/var/tmp/|/private/tmp/|/dev/shm/|\$\{?TMPDIR\}?|scratchpad", re.IGNORECASE)
R3_TOKEN_RE = re.compile(r"[^\s`\"'()]+")
# A durable citation is PATH-SHAPED (never a bare word that merely contains a slash: `binary/sha256`,
# `3/3`, `N/A`, `and/or`) or the canonical block FILE name (`<target>-block12.md`, never `[Block 12]`
# or `B12`, which any prose can say). Path-shaped = a trailing `/` after a segment (`evidence/`), or
# two or more non-empty segments of which at least one carries a file extension (a dot followed by
# 1-6 alphanumerics with at least one LETTER, optionally `:LINE[-LINE]`): `N4.14/N5.0` and
# `read/write/execute` are not paths. A bare `out.txt:12` is not durable: nobody can tell which
# file it is.
R3_EXT_RE = re.compile(r"\.[A-Za-z0-9]{0,5}[A-Za-z][A-Za-z0-9]{0,5}(?::\d+(?:-\d+)?)?$")
# Inline evidence group (outside Self-verify): the marker, an optional closing backtick / colon / dash, then
# a parenthetical (one nesting level, no `|` so a table cell is never crossed) of at most 400 characters. A path
# that merely sits elsewhere in the paragraph is NOT this marker's evidence.
R3_INLINE_GROUP_RE = re.compile(r"`?\s*[:—–-]?\s*\(((?:[^()|]|\([^()|]*\)){0,400})\)")
R3_BLOCKFILE_RE = re.compile(r"[\w.+-]+-(?:block|bloque)\d+(?:-[\w-]+)?\.md\b")


def _is_durable_token(tok):
    tok = tok.rstrip(".,;:")
    if R3_EPHEMERAL_RE.search(tok):
        return False
    if R3_BLOCKFILE_RE.search(tok):
        return True
    segs = [x for x in tok.split("/") if x]
    if tok.endswith("/") and segs:
        return True                      # `evidence/` — a directory reference
    if len(segs) < 2:
        return False
    return any(R3_EXT_RE.search(x) for x in segs)


def rule_r3(doc):
    sv, nsec = lines_in_sections(doc.sections, R3_SECTION_RE)
    doc.cov["selfverify_sections"] = nsec
    out = []
    for u in doc.units:
        if u.kind not in ("row", "item") or u.line not in sv:
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
    # Slice 2 (kit #1365 item 3): inline evidence group OUTSIDE Self-verify sections.
    for u in doc.units:
        if u.kind not in ("row", "item", "para") or u.line in sv:
            continue
        for m in R3_MARKER_RE.finditer(u.text):
            gm = R3_INLINE_GROUP_RE.match(u.text, m.end())
            if gm is None:
                continue
            doc.cov["cert_inline_items"] += 1
            evidence = gm.group(1)
            if not R3_EPHEMERAL_RE.search(evidence):
                continue
            if any(_is_durable_token(t) for t in R3_TOKEN_RE.findall(evidence)):
                continue
            if doc.waived("R3", u):
                continue
            out.append((u.line, "R3", "inline [CERT-hw]/[CERT-live] evidence cites only an ephemeral path: "
                        + excerpt(evidence)))
            break  # one finding per unit, like the Self-verify pass
    return out


# ---------------------------------------------------------------------------
# R6 — cross-block comparison without the other block's raw artifact
# ---------------------------------------------------------------------------
# The verdict must be ABOUT the block: `[Block N]` is the (near) subject of "does not mention/show/
# contain/include/cite" (not `reference`: "never referenced" is the code sense in the fleet) (any of does/do/did not, doesn't, didn't, never; any of -s/-ed/-d).
# At most 80 characters, with no sentence/clause boundary or dash between them (— em dash,
# – en dash; a `.` inside a token such as `§55.2` is not a boundary) — a block reference
# merely sitting in the same sentence as an unrelated "never shows" is not a comparison claim
# (measured: 2 of 3 non-fixture hits in the first, looser version were that shape).
R6_CLAIM_RE = re.compile(
    r"\[Block\s*\d+\](?:[^.;—–\n]|\.(?=\S)){0,80}?\b"
    r"(?:(?:does|do|did)\s+not|doesn't|didn't|never)\s+"
    r"(?:mention|show|contain|include|cite)(?:s|ed|d)?\b",
    re.IGNORECASE)
R6_RAW_PATH_RE = re.compile(r"evidence/|[\w./-]*/[\w.-]+\.\w{1,6}")


def rule_r6(doc):
    out = []
    for u in doc.units:
        if u.kind not in ("para", "item", "row"):
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
# Ids of the reference linter's per-target pack rules, reserved for slice 2. A waiver naming one is
# valid in a block (it is not R0) but nothing enforces it here: it is reported as INFO and counted
# as `inactive-waivers`. A pack that registers a rule in RULES activates its id automatically.
RESERVED_PACK_RULE_IDS = ("R1", "R2", "R4", "R5", "R7", "R8", "R9")


def lint_text(text):
    """Return (findings, warnings, infos, coverage) for one document.

    findings = sorted [(line, rule, message)]; warnings and infos = [(line, message)] (neither
    affects the exit code).
    """
    doc = Doc(text)
    findings = list(doc.r0)
    for _rid, fn in RULES:
        findings.extend(fn(doc))
    findings.sort(key=lambda f: (f[0], f[1]))
    return findings, doc.warns, doc.infos, doc.cov


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
    cov = {"selfverify_sections": 0, "cert_hw_live_items": 0, "r6_trigger_clauses": 0, "cert_inline_items": 0}
    read = empty = unreadable = total = warn = inactive = 0
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
        findings, warns, infos, c = lint_text(text)
        for k in cov:
            cov[k] += c[k]
        for line, msg in infos:
            print(f"INFO {path}:{line}: {msg}")
            inactive += 1
        for line, msg in warns:
            print(f"WARN {path}:{line}: {msg}")
            warn += 1
        for line, rule, msg in findings:
            print(f"{rule} {path}:{line}: {msg}")
            counts[rule] = counts.get(rule, 0) + 1
            total += 1

    mode = "AUDIT" if audit else "LINT"
    per_rule = " ".join(f"{r}={counts.get(r, 0)}" for r in ["R0"] + RULE_IDS)
    print(f"SUMMARY {mode} files={read} empty={empty} unreadable={unreadable} findings={total} warn={warn} inactive-waivers={inactive} {per_rule} "
          f"| inspected: selfverify-sections={cov['selfverify_sections']} "
          f"cert-hw-live-items={cov['cert_hw_live_items']} r6-trigger-clauses={cov['r6_trigger_clauses']} "
          f"cert-inline-items={cov['cert_inline_items']}")
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
