"""child-gap pack for lint_block.py (kit #1214/#1365): the open-time `coverage-check:` grammar.

  R4  a child-gap bullet (`- B<n>-G<m> ...`) inside an open-time "Child gaps ..." section must carry
      (a) `coverage-check: <query> -> <result>` (METHODOLOGY §8b "Child-gap bullet grammar at OPEN time"):
          the grep / INDEX query that asked whether the gap is already answered, and what it returned;
      (b) `measured-by: <tool/method>` when the bullet states any number (a number in a gap is a
          hypothesis until the tool that produced it is named).

Typed findings, never one undifferentiated "bad bullet":
  ABSENT     the bullet has no `coverage-check:` token at all
  MALFORMED  the token is there but the clause is not a query plus a result (empty, placeholder such as
             TODO/n/a, a query with no `->` / `→` result, a result with no content)
  MEASURE    the bullet states a number but carries no `measured-by:` clause (absent or empty/placeholder)

Section model. A judged section starts at a heading whose title names child gaps (`Child gaps opened`,
`Open child gaps`, ...; NOT `closed` / `resolved` / `no child gaps`), or at a whole-line label
`Child gaps opened` (a bold label; the core strips `**`). A heading-started section runs to the next heading
of the same or a higher level, so `### Medium priority` sub-headings stay inside it; a label-started section
runs to the next heading. Gap-id bullets found OUTSIDE every judged section are not judged, but they are
counted in the SUMMARY as `r4-unscoped=<n>` (always printed when the pack is loaded), so a block whose gaps
sit under an unrecognised heading cannot read as a silent clean.

Bullet = its first line, its continuation lines and any more-indented sub-bullet (`  - coverage-check: ...`),
up to a blank line, a heading or a same-or-lower-indent list item. A clause body ends at the next clause token
or at the end of its sentence, so trailing prose is neither a result nor hidden from the number check.
Numbers are read from the whole bullet EXCEPT the clause bodies, the id, the priority parenthetical, code
spans, `[Block N` / `B<n>` / `§N` references, dates, `:N` line references and 3-part versions; a two-part
dotted number is a version unless it carries a unit (`12.5%`, `2.5x`, `3k`). Tokens glued to letters (N5, v2,
A28) are not numbers. SUMMARY `r4-triggers=` counts the bullets inspected. Waive with
`<!-- lint-waive: R4 reason=... -->` on any line of the bullet. Loaded with `lint-block.sh --pack child-gap`.
"""
import re

SECTION_RE = re.compile(r"child[- ]gaps?", re.IGNORECASE)
EXCLUDED_TITLE_RE = re.compile(r"\bclosed\b|\bresolved\b|\bno\s+child[- ]gaps?\b", re.IGNORECASE)
LABEL_RE = re.compile(r"^\s*(?:open\s+)?child[- ]gaps?(?:\s+(?:opened|surfaced|named))?\s*:?\s*$", re.IGNORECASE)
BULLET_RE = re.compile(r"^(\s*)[-*+]\s+\(?(B\d+-G\d+)\b")
ANY_ITEM_RE = re.compile(r"^(\s*)(?:\d+\.|[-*+])\s+")
HEADING_LINE_RE = re.compile(r"^\s*(#{1,6})(?:\s+(.*))?$")
# The token may be wrapped in backticks (`coverage-check:`), as real blocks write it.
COVERAGE_RE = re.compile(r"`?coverage-check:`?", re.IGNORECASE)
MEASURED_RE = re.compile(r"`?measured-by:`?", re.IGNORECASE)
RESULT_SEP_RE = re.compile(r"->|→")
CODE_START_RE = re.compile(r"`([^`]+)`")  # a query written as a code span; match() anchors it at the clause start
# A clause body ends at its sentence end: . ! ? followed by whitespace and a capital / code / bracket, or EOL.
SENTENCE_END_RE = re.compile(r"[.!?](?=\s+[A-Z`\[(]|\s*$)")
PLACEHOLDER_RE = re.compile(
    r"^(?:todo|tbd|tba|tbc|xxx|n/?a|none|nil|null|unknown|unresolved|pending|missing|fixme|wip|\?+)\W*$",
    re.IGNORECASE)
# A RESULT may legitimately be "none" (the query found no hit: that IS the finding), so the result
# placeholder list leaves that word out.
RESULT_PLACEHOLDER_RE = re.compile(
    r"^(?:todo|tbd|tba|tbc|xxx|n/?a|nil|null|unknown|unresolved|pending|missing|fixme|wip|\?+)\W*$", re.IGNORECASE)
# A prose-only clause is accepted on length, so a placeholder padded with words ("n/a for this gap") must
# be refused by content: any placeholder word anywhere in it.
PROSE_PLACEHOLDER_RE = re.compile(
    r"(?<![\w/])(?:todo|tbd|tba|tbc|xxx|n/a|fixme|wip|unknown|unresolved)(?![\w/])", re.IGNORECASE)

# Prose stripped before the number search.
CODE_SPAN_RE = re.compile(r"`[^`]*`")
REF_RE = re.compile(r"\[Block\s*\d+|\bB\d+(?:-G\d+)?\b|§\s*\d[\d.]*", re.IGNORECASE)
LEADING_PAREN_RE = re.compile(r"^\s*\([^)]*\)")  # "(medium, investigable read-only)"
VERSION3_RE = re.compile(r"\d+(?:\.\d+){2,}")
DATE_RE = re.compile(r"\d{4}-\d{2}(?:-\d{2})?")  # ISO dates are not measurements
# A standalone number, optionally decimal, optionally with a unit suffix (%, x, k, M, kB, MB, ...): not
# glued to a letter/underscore/dot before it ("N5", "v2", "A28") nor to a line-ref colon ("File:79").
NUMBER_RE = re.compile(r"(?<![\w.:])(\d[\d,]*)(\.\d+)?(%|[xXkKmM]|[kKmMgG][bB])?(?!\w)")


def mask_code(text):
    """Same-length copy of `text` with code-span interiors blanked to 'x' (so punctuation inside one is inert)."""
    return CODE_SPAN_RE.sub(lambda m: "x" * len(m.group(0)), text)


def clause_spans(text, tokens):
    """[(token_match, body_start, body_end)] - a body runs to the next clause token or its sentence end."""
    masked = mask_code(text)
    toks = sorted(tokens, key=lambda m: m.start())
    out = []
    for idx, m in enumerate(toks):
        end = toks[idx + 1].start() if idx + 1 < len(toks) else len(text)
        se = SENTENCE_END_RE.search(masked, m.end(), end)
        if se is not None:
            end = se.start()
        out.append((m, m.end(), end))
    return out


def stated_number(prose):
    prose = CODE_SPAN_RE.sub(" ", prose)
    prose = REF_RE.sub(" ", prose)
    prose = DATE_RE.sub(" ", prose)
    prose = VERSION3_RE.sub(" ", prose)
    for m in NUMBER_RE.finditer(prose):
        if m.group(2) and not m.group(3):
            continue  # a bare two-part dotted number ("4.15") reads as a version
        return m.group(0)
    return None


def coverage_problem(body):
    """None when the clause body is a query plus a result; else what is wrong with it.

    Accepted: `query -> result` (the arrow form, `->` or the arrow character), or a query written as a
    leading code span followed by the result in prose (the form real blocks use). A prose-only clause with
    no code span and no arrow is accepted when it has 4+ words and no placeholder word: a query named by a
    doc reference ("T10 state in odd/tasks/x.md") cannot be told from its result mechanically, and the check
    only proves the clause is not a stub."""
    plain = body.strip("` ")
    if not plain or PLACEHOLDER_RE.match(plain):
        return "is empty or a placeholder"
    sep = RESULT_SEP_RE.search(body)
    span = CODE_START_RE.match(body)
    if sep is not None:
        query, result = body[:sep.start()], body[sep.end():]
    elif span is not None:
        query, result = span.group(1), body[span.end():]
    elif PROSE_PLACEHOLDER_RE.search(plain):
        return "is a placeholder padded with words"
    elif len(plain.split()) >= 4:
        return None
    else:
        return "names no query and no result (expected `query -> result`)"
    query, result = query.strip("` "), result.strip(" `.;")
    if not re.search(r"[A-Za-z0-9]{2,}", query):
        return "names no query before the result"
    if not re.search(r"[A-Za-z0-9]{2,}", result) or RESULT_PLACEHOLDER_RE.match(result):
        return "states no result for the query"
    return None


def judge_bullet(text):
    """[(kind, detail)] for one bullet's joined text; empty when the bullet conforms."""
    text = text.replace("**", "")
    cov = list(COVERAGE_RE.finditer(text))
    mea = list(MEASURED_RE.finditer(text))
    spans = clause_spans(text, cov + mea)
    out = []
    if not cov:
        out.append(("ABSENT", "no `coverage-check:` clause"))
    else:
        first_cov = next(s for s in spans if s[0] is cov[0])
        problem = coverage_problem(text[first_cov[1]:first_cov[2]].strip(" \t.;,"))
        if problem:
            out.append(("MALFORMED", "`coverage-check:` " + problem))
    # Prose = the bullet without its clauses (token through sentence end).
    pieces, pos = [], 0
    for m, _bs, be in spans:
        pieces.append(text[pos:m.start()])
        pos = be
    pieces.append(text[pos:])
    prose = " ".join(pieces)
    prose = re.sub(r"^\s*[-*+]\s+\(?B\d+-G\d+\)?", "", prose)
    prose = LEADING_PAREN_RE.sub("", prose)
    number = stated_number(prose)
    if number is not None:
        if not mea:
            out.append(("MEASURE", f"states {number} but has no `measured-by:` clause"))
        else:
            first_mea = next(s for s in spans if s[0] is mea[0])
            mbody = text[first_mea[1]:first_mea[2]].strip(" \t.;,`")
            if not re.search(r"[A-Za-z0-9]{2,}", mbody) or PLACEHOLDER_RE.match(mbody):
                out.append(("MEASURE", f"states {number} but `measured-by:` is empty or a placeholder"))
    return out


def make_rule(api):
    def rule(doc):
        doc.cov["r4_triggers"] += 0   # register: the SUMMARY prints r4-triggers=0 when nothing was inspected
        doc.cov["r4_unscoped"] += 0   # ... and r4-unscoped=0 when no gap bullet sat outside a judged section
        out = []
        scope = None        # None | ("h", level) heading-started | ("label", None) label-started
        excluded = None     # level of an excluded sub-heading (closed / resolved) inside a judged section
        i, n = 1, len(doc.lines)
        while i <= n:
            raw = doc.lines[i - 1]
            if i in doc.fenced:
                i += 1
                continue
            hm = HEADING_LINE_RE.match(raw)
            if hm:
                level, title = len(hm.group(1)), hm.group(2) or ""
                if excluded is not None and level <= excluded:
                    excluded = None
                if scope is not None and (scope[0] == "label" or level <= scope[1]):
                    scope = None
                if scope is None and excluded is None and SECTION_RE.search(title) \
                        and not EXCLUDED_TITLE_RE.search(title):
                    scope = ("h", level)
                elif scope is not None and EXCLUDED_TITLE_RE.search(title) and excluded is None:
                    excluded = level
                i += 1
                continue
            if scope is None and LABEL_RE.match(raw):
                scope = ("label", None)
                i += 1
                continue
            m = BULLET_RE.match(raw)
            if not m:
                i += 1
                continue
            indent = len(m.group(1))
            last = i
            for j in range(i + 1, n + 1):
                nxt = doc.lines[j - 1]
                if j in doc.fenced or not nxt.strip() or HEADING_LINE_RE.match(nxt):
                    break
                im = ANY_ITEM_RE.match(nxt)
                if im and len(im.group(1)) <= indent:
                    break
                last = j
            if scope is None or excluded is not None:
                doc.cov["r4_unscoped"] += 1
            else:
                text = " ".join(doc.lines[k - 1].strip() for k in range(i, last + 1))
                doc.cov["r4_triggers"] += 1
                waived = any(r == "R4" and i <= ln <= last for ln, r in doc.valid_waivers)
                if not waived:
                    for kind, detail in judge_bullet(text):
                        out.append((i, "R4", f"child gap {m.group(2)}: {kind} - {detail}"))
            i = last + 1
        return out
    return rule


def build(api):
    return [("R4", make_rule(api))]
