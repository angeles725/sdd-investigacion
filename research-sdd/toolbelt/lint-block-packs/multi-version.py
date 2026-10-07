"""multi-version pack for lint_block.py (kit #1206/#1365): baseline attribution.

  R8  an "N5-only" / "new in N5" / "added in N5" / "introduced in N5" / "absent from N4" claim about a
      software surface (jar, class, module, package, feature, API) with no 4.15 / PowerB / N4.15
      baseline token in the same clause. Comparing N5 against N4.14 alone attributes to N5 what an
      intermediate release already shipped.

Vocabulary derived from the niagara5-research reference linter; heuristic, clause-scoped. The reference
surface regex `\bclasses?\b` never matched the singular "class" (it requires the `e`); fixed here with
`class(?:es)?` and pinned by a fixture. Scoped to software surfaces so a build property or config key "new in N5" is not a finding. Waive with
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


def build(api):
    return [("R8", api.make_claim_rule(
        "R8", lambda c: R8_TRIGGER_RE.search(c) and R8_SURFACE_RE.search(c), R8_BASELINE_RE.search,
        "N5-only/baseline claim without a 4.15 baseline check"))]
