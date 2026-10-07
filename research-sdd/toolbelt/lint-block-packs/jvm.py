"""jvm pack for lint_block.py (kit #1206/#1365): rules about decompiled-JVM claims.

  R1  syntax-adoption claim (pattern matching, var, text block, switch expression, enhanced for,
      lambda, ...) with an adoption verb and no bytecode/docSource evidence token in the same clause.
      A decompiler resugars, so "the source uses X" is not evidence that the class file does.
  R5  a fail-open / bypass / null-Context permission claim with no `dispatch:` clause naming the
      resolved override (or an inline `cited-absence:` clause citing that none exists). Scoped to clauses
      that are about permissions/security; a unit made only of `>` blockquote lines (restated gap text)
      is skipped and counted as `quoted-skipped=` in the SUMMARY.
  R7  a dead/unused/unreferenced-constant or shadow-literal/hardcoded-duplicate claim without a
      compile-time-constant-inlining evidence token (javac inlines constants: "never read" in the
      decompiled code does not mean unreferenced in the class file).

Vocabulary derived from the niagara5-research reference linter; heuristic, clause-scoped. Waive with
`<!-- lint-waive: R<n> reason=... -->`. Loaded with `lint-block.sh --pack jvm`.
"""
import re

R1_FEATURE_RE = re.compile("|".join([
    r"pattern-\s*match(?:ing)?", r"instanceof\s+pattern", r"JEP\s*394", r"switch\s+expression",
    r"arrow\s+switch", r"text\s+block", r"record\s+pattern",
    # Bare `var`, `sealed` and "for each" are ordinary English ("var-length", "sealed envelope", "for each
    # record"): they count only in their Java-feature forms (kit #1548 calibration, fleet FP rate 20/30).
    r"\brecords?\s*/\s*sealed\b", r"`var`", r"\bvar\s+(?:keyword|declarations?|inference)\b", r"local[\s-]+variable\s+type\s+inference",
    r"\bsealed\s+(?:classes|class|interfaces|interface|hierarch\w*|types?)\b",
    r"enhanced\s+for", r"for-each", r"\blambda\b",
]), re.IGNORECASE)
R1_VERB_RE = re.compile("|".join([
    r"\buses?\b", r"\badopts?\b", r"\badopted\b", r"\badoption\b",
    r"\brewrites?\b", r"\brewritten\b", r"\breplaces?\b", r"\breplaced\b",
    r"\bmodernized\b", r"migrated to", r"converted to",
    r"N5 now", r"new in N5", r"Java[\s-]21[\s-]?style",
]), re.IGNORECASE)
# Evidence tokens showing the claim was read from the class file (or the vendor source), not from a
# decompiler's resugared output; any one of them in the claim's own clause clears R1. A decompiler
# (CFR, Vineflower, Procyon) is deliberately NOT a token: it resugars (METHODOLOGY decompiler
# fidelity: its output is not 1:1 with the class file), so "CFR shows X" is the very evidence R1
# distrusts. Cite javap / bytecode / docSource instead.
R1_EVIDENCE_RE = re.compile("|".join([
    r"\bjavap\b", r"\btypeSwitch\b", r"\bSwitchBootstraps\b", r"\bLambdaMetafactory\b",
    r"\bPermittedSubclasses\b", r"Record attribute", r"extends\s+java\.lang\.Record",
    r"\bdocSource\b", r"\bbytecode\b", r"class-file attribute",
    r"\bLocalVariableTable\b",
]), re.IGNORECASE)

R5_CONSEQUENCE_RE = re.compile("|".join([
    r"fail-open", r"fails?\s+open", r"\bno-op\b", r"\bbypass(?:es|ed)?\b", r"\bungated\b",
    r"drops?\s+cx\b", r"null\s+Context", r"getPermissions\(null\)",
]), re.IGNORECASE)
# "bypass"/"no-op" are common outside the permission-dispatch failure class (build flags, test-mode
# shortcuts): require the clause to be about permissions/security, not just use one of those words.
# `Context` (the Niagara type) and `cx` are matched case-sensitively: lower-case "context" is an
# ordinary English word ("in the test context") and must not make a clause permission-scoped; the
# phrase "null context" / "null-context" (the permission-bypass idiom) stays in scope in any case.
R5_PERM_CONTEXT_RE = re.compile(
    r"(?i:\bpermissions?\b|getPermissions|\bsecurity\b|\bcredentials?\b|\bauth(?:n|z)?\b|\bauthenticat\w*|\bauthoris\w*|\bauthoriz\w*|\bnull[\s-]+context\b)"
    r"|\bContext\b|\bcx\b")
# Clearing forms: a resolved `dispatch:` clause, or an inline `cited-absence:` clause (the override was
# searched for and its absence is cited, e.g. "cited-absence: grep of the corpus found no override").
R5_CLEARED_RE = re.compile(r"dispatch:|cited-absence:", re.IGNORECASE)

R7_TRIGGER_RE = re.compile("|".join([
    r"\b(?:dead|unused|unreferenced)\s+constants?\b",
    r"\bconstants?\b.{0,15}\b(?:is|are)\b.{0,15}\b(?:dead|unused|unreferenced)\b",
    r"\bshadow\w*\b.{0,40}\bliteral\b",
    r"\bliteral\b.{0,40}\bshadow\w*\b",
    r"\bduplicat\w*\b.{0,25}(?:its own\s+)?constants?\b",
    r"\bconstants?\b.{0,25}\bduplicat\w*\b",
    r"\bhardcod\w*\b.{0,80}\binstead of\b.{0,40}\bconstant\b",
]), re.IGNORECASE)
# Bare "inlin" also matches ordinary prose ("an inline literal duplicate"): it must co-occur with a
# technical term so that phrasing cannot silently suppress the finding it describes.
R7_EVIDENCE_RE = re.compile("|".join([
    r"compile-time constant", r"JLS\s*4\.12\.4", r"JLS\s*13\.1", r"\bldc\b", r"\bdocSource\b",
    r"\binlin\w*\b.{0,25}(?:constant|compiler|javac|javap|bytecode)",
    r"(?:constant|compiler|javac|javap|bytecode).{0,25}\binlin\w*\b",
]), re.IGNORECASE)


def build(api):
    mk = api.make_claim_rule
    return [
        ("R1", mk("R1", lambda c: R1_FEATURE_RE.search(c) and R1_VERB_RE.search(c),
                  R1_EVIDENCE_RE.search, "syntax-adoption claim without bytecode/docSource evidence")),
        ("R5", mk("R5", lambda c: R5_CONSEQUENCE_RE.search(c) and R5_PERM_CONTEXT_RE.search(c),
                  R5_CLEARED_RE.search, "permission consequence claim without a resolved dispatch: target",
                  skip_quoted=True)),
        ("R7", mk("R7", R7_TRIGGER_RE.search, R7_EVIDENCE_RE.search,
                  "constant-inlining claim without bytecode/docSource evidence")),
    ]
