"""multi-version pack for lint_block.py (kit #1206/#1365): baseline attribution.

  R8  an "N5-only" / "new in N5" / "added in N5" / "introduced in N5" / "absent from N4" claim about a
      software surface (jar, class, module, package, feature, API) with no 4.15 / PowerB / N4.15
      baseline token in the same clause. Comparing N5 against N4.14 alone attributes to N5 what an
      intermediate release already shipped.

Vocabulary derived from the niagara5-research reference linter; heuristic, clause-scoped. The reference
surface regex `\bclasses?\b` never matched the singular "class" (it requires the `e`); fixed here with
`class(?:es)?` and pinned by a fixture. Scoped to software surfaces so a build property or config key "new in N5" is not a finding; a negated, question or "whether" clause is not a claim. Waive with
`<!-- lint-waive: R8 reason=... -->`. Loaded with `lint-block.sh --pack multi-version`.
"""
import re

R8_TRIGGER_RE = re.compile(
    r"N5-only|new in N5|added in N5|introduced in N5|absent from N4", re.IGNORECASE)
# `4.15` also covers "N4.15" and a dotted patch release such as "4.15.1" (still the 4.15 baseline); the
# leading digit/dot guard stops "14.15" and "3.4.15", and the trailing digit guard stops "4.150".
R8_BASELINE_RE = re.compile(r"(?<![\d.])4\.15(?!\d)|PowerB", re.IGNORECASE)
R8_SURFACE_RE = re.compile(
    r"\.jar\b|\.class\b|\bjars?\b|\bclass(?:es)?\b|\bmodules?\b|\bpackages?\b|\bfeatures?\b|\bAPI\b",
    re.IGNORECASE)


# A claim that is only negated ("not new in N5"), asked about ("Is the jar N5-only?") or deferred
# ("whether ... is new in N5", "Confirm whether ...") attributes nothing to N5 (kit #1548 calibration:
# R8 precision was ~47% with these in scope). Everything is POSITIONAL: it is judged on the sentence the
# trigger sits in (split on ? ; . !) and, for "whether" / negation, on the sub-clause before the trigger
# (after the last comma). So "The jar is new in N5; why was it missed?", "Is this a regression? No, the
# package is new in N5." and "... are new in N5, but left open whether ..." all remain claims.
# "not only/just/merely/simply/solely" is an intensifier, not a negation; "whether or not" defers nothing.
R8_NEGATION_RE = re.compile(
    r"\b(?:not(?!\s+(?:only|just|merely|simply|solely)\b)|never|isn't|aren't|wasn't|weren't)\s+(?:\w+\s+){0,2}$",
    re.IGNORECASE)
R8_WHETHER_RE = re.compile(r"\bwhether\b(?!\s+or\s+not\b)", re.IGNORECASE)
# A sentence that opens as a question ("Is the jar N5-only", "3. Does ...") is interrogative even when the
# splitter consumed its "?".
R8_QUESTION_OPEN_RE = re.compile(r"^\s*(?:(?:\d+\.|[-*])\s+)?(?:is|are|was|were|does|did)\b", re.IGNORECASE)
R8_SENTENCE_END_RE = re.compile(r"\?|[;.!](?=\s)")
# Question scope is finer than sentence scope: a parenthesised aside "(did 4.14 ship it?)" and a tag
# question ", isn't it?" are questions ABOUT the claim, not the claim, so the claim before them stays.
R8_QUESTION_END_RE = re.compile(
    r"\?|[;.!](?=\s)|[()]|,(?=\s*(?:isn't it|aren't they|doesn't it|don't they|right|no)\s*\?)", re.IGNORECASE)


def spans_of(clause, end_re):
    """[(start, end, ends_with_question)] covering the clause, split at the boundaries of `end_re`."""
    spans, start = [], 0
    for m in end_re.finditer(clause):
        spans.append((start, m.start(), m.group(0) == "?"))
        start = m.end()
    spans.append((start, len(clause), False))
    return spans


def span_at(spans, pos):
    for start, end, is_question in spans:
        if start <= pos < max(end, start + 1):
            return start, end, is_question
    return None


def is_r8_claim(clause):
    if not R8_SURFACE_RE.search(clause):
        return False
    sentences = spans_of(clause, R8_SENTENCE_END_RE)
    fine = spans_of(clause, R8_QUESTION_END_RE)
    for t in R8_TRIGGER_RE.finditer(clause):
        sent, part = span_at(sentences, t.start()), span_at(fine, t.start())
        if sent is None or part is None:
            continue
        start, end, _ = sent
        if part[2] or R8_QUESTION_OPEN_RE.search(clause[start:end]):
            continue
        before = clause[start:t.start()].rsplit(",", 1)[-1]
        if not R8_WHETHER_RE.search(before) and not R8_NEGATION_RE.search(before):
            return True
    return False


def build(api):
    return [("R8", api.make_claim_rule(
        "R8", is_r8_claim, R8_BASELINE_RE.search,
        "N5-only/baseline claim without a 4.15 baseline check"))]
