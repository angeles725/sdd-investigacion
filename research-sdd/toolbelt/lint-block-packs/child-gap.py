"""child-gap pack for lint_block.py (kit #1214/#1365): the open-time `coverage-check:` grammar.

  R4  a child-gap bullet (`- B<n>-G<m> ...`) inside a "Child gaps ..." section must carry
      (a) `coverage-check: <query> -> <result>` (METHODOLOGY §8b "Child-gap bullet grammar at OPEN time"):
          the grep / INDEX query that asked whether the gap is already answered, and what it returned;
      (b) `measured-by: <tool/method>` when the bullet states any number (a number in a gap is a
          hypothesis until the tool that produced it is named).

Typed findings, never one undifferentiated "bad bullet":
  ABSENT     the bullet has no `coverage-check:` token at all
  MALFORMED  the token is there but the clause is not a query plus a result (empty, placeholder such as
             TODO/n/a, a query with no `->` / `→` result, a result with no content)
  MEASURE    the bullet states a number but carries no `measured-by:` clause (absent or empty/placeholder)

Heuristic and clause-scoped: the bullet is its first line plus continuation lines up to a blank line, a
heading or the next list item. Numbers are read from the gap prose only: the id, the priority/type
parenthetical, code spans, `[Block N]` / `B<n>` / `§N` references, dotted versions and tokens glued to
letters (N5, v2, A28) are not numbers; the coverage-check and measured-by clauses are not prose. A
section with no gap bullet, or a file with no child-gap section, produces no finding and bumps no
counter, so the SUMMARY `r4-triggers=` proves how many bullets were actually inspected. Waive with
`<!-- lint-waive: R4 reason=... -->` on any line of the bullet. Loaded with `lint-block.sh --pack child-gap`.
"""
import re

SECTION_RE = re.compile(r"child[- ]gaps?", re.IGNORECASE)
BULLET_RE = re.compile(r"^(\s*)[-*+]\s+\(?(B\d+-G\d+)\b")
ANY_ITEM_RE = re.compile(r"^\s*(?:\d+\.|[-*+])\s+")
HEADING_RE = re.compile(r"^\s*#{1,6}(?:\s|$)")
# The token may be wrapped in backticks (`coverage-check:`), as real blocks write it.
COVERAGE_RE = re.compile(r"`?coverage-check:`?", re.IGNORECASE)
MEASURED_RE = re.compile(r"`?measured-by:`?", re.IGNORECASE)
RESULT_SEP_RE = re.compile(r"->|→")
CODE_START_RE = re.compile(r"`([^`]+)`")  # a query written as a code span; match() anchors it at the clause start
PLACEHOLDER_RE = re.compile(
    r"^(?:todo|tbd|tba|tbc|xxx|n/?a|none|nil|null|unknown|unresolved|pending|missing|fixme|wip|\?+)\W*$",
    re.IGNORECASE)
# A RESULT may legitimately be "none" (the query found no hit: that IS the finding), so the result
# placeholder list leaves those words out.
RESULT_PLACEHOLDER_RE = re.compile(r"^(?:todo|tbd|tba|tbc|xxx|n/?a|unknown|unresolved|fixme|wip|\?+)\W*$", re.IGNORECASE)

# Prose stripped before the number search.
CODE_SPAN_RE = re.compile(r"`[^`]*`")
REF_RE = re.compile(r"\[Block\s*\d+[^\]]*\]|\bB\d+(?:-G\d+)?\b|§\s*\d[\d.]*", re.IGNORECASE)
LEADING_PAREN_RE = re.compile(r"^\s*(?:\*\*)?\([^)]*\)")  # "(medium, investigable read-only)"
VERSION_RE = re.compile(r"\d+(?:\.\d+)+")
DATE_RE = re.compile(r"\d{4}-\d{2}(?:-\d{2})?")  # ISO dates are not measurements
# A standalone number: not glued to a letter/underscore/dot on either side ("N5", "v2", "A28", "4.15")
# and not a `:N` line reference ("BNumericPoint:79").
NUMBER_RE = re.compile(r"(?<![\w.:])\d[\d,]*(?![\w])")


def clause_body(text, start, other_tokens):
    """Text after the token that ends at `start`, up to the next clause token."""
    end = len(text)
    for m in other_tokens:
        if m.start() >= start:
            end = min(end, m.start())
    return text[start:end].strip(" \t.;,")


def stated_number(prose):
    prose = CODE_SPAN_RE.sub(" ", prose)
    prose = REF_RE.sub(" ", prose)
    prose = DATE_RE.sub(" ", prose)
    prose = VERSION_RE.sub(" ", prose)
    m = NUMBER_RE.search(prose)
    return m.group(0) if m else None


def coverage_problem(body):
    """None when the clause body is a query plus a result; else what is wrong with it.

    Accepted: `query -> result` (the arrow form), or a query written as a leading code span followed by
    the result in prose (the form real blocks use). A prose-only clause with no code span and no arrow
    is accepted when it has 4+ words: a query named by a doc reference ("T10 state in odd/tasks/x.md")
    cannot be told from its result mechanically, and the check only proves the clause is not a stub."""
    plain = body.strip("` ")
    if not plain or PLACEHOLDER_RE.match(plain):
        return "is empty or a placeholder"
    sep = RESULT_SEP_RE.search(body)
    span = CODE_START_RE.match(body)
    if sep is not None:
        query, result = body[:sep.start()], body[sep.end():]
    elif span is not None:
        query, result = span.group(1), body[span.end():]
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
    out = []
    if not cov:
        out.append(("ABSENT", "no `coverage-check:` clause"))
    else:
        problem = coverage_problem(clause_body(text, cov[0].end(), mea + cov[1:]).strip())
        if problem:
            out.append(("MALFORMED", "`coverage-check:` " + problem))
    first = min([m.start() for m in cov + mea] or [len(text)])
    prose = text[:first]
    prose = re.sub(r"^\s*[-*+]\s+\(?B\d+-G\d+\)?", "", prose)
    prose = LEADING_PAREN_RE.sub("", prose)
    number = stated_number(prose)
    if number is not None:
        if not mea:
            out.append(("MEASURE", f"states {number} but has no `measured-by:` clause"))
        else:
            mbody = clause_body(text, mea[0].end(), cov + mea[1:]).strip("` ")
            if not re.search(r"[A-Za-z0-9]{2,}", mbody) or PLACEHOLDER_RE.match(mbody):
                out.append(("MEASURE", f"states {number} but `measured-by:` is empty or a placeholder"))
    return out


def make_rule(api):
    def rule(doc):
        doc.cov["r4_triggers"] += 0  # register: the SUMMARY prints r4-triggers=0 when nothing was inspected
        out = []
        for start, end, title in doc.sections:
            if not SECTION_RE.search(title):
                continue
            i = start + 1
            while i < end:
                if i in doc.fenced:
                    i += 1
                    continue
                m = BULLET_RE.match(doc.lines[i - 1])
                if not m:
                    i += 1
                    continue
                last = i
                for j in range(i + 1, end):
                    raw = doc.lines[j - 1]
                    if (j in doc.fenced or not raw.strip() or HEADING_RE.match(raw) or ANY_ITEM_RE.match(raw)):
                        break
                    last = j
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
