#!/usr/bin/env python3
"""oracle.py - test-only oracle over the FROZEN lint_block.py and its packs (kit issue #2393).

The Go differential tests (internal/lint/*_test.go) feed it one JSON document on stdin:
    {"calls": [{"fn": "<name>", "inputs": [<json>, ...]}, ...]}
and read one JSON document back: {"results": [[<result per input>], ...]}. It evaluates the legacy Python
regexes and helpers on each input, so every lookaround / Unicode rewrite in Go is checked against the code it
replaced. Positions are Python code-point indexes. This file is frozen with the legacy copies and is never run by
the product.
"""
import importlib.util
import json
import os
import sys
import types

HERE = os.path.dirname(os.path.abspath(__file__))


def _load_core():
    spec = importlib.util.spec_from_file_location("legacy_lint_block", os.path.join(HERE, "lint_block.py"))
    mod = importlib.util.module_from_spec(spec)
    sys.modules["legacy_lint_block"] = mod
    spec.loader.exec_module(mod)
    return mod


LB = _load_core()


def _pack(name):
    path = os.path.join(HERE, "lint-block-packs", name + ".py")
    with open(path, "r", encoding="utf-8") as fh:
        code = compile(fh.read(), path, "exec")
    mod = types.ModuleType("legacy_pack_" + name.replace("-", "_"))
    exec(code, mod.__dict__)
    return mod


JVM = _pack("jvm")
MV = _pack("multi-version")
NB = _pack("native-binary")
CG = _pack("child-gap")


def _span(m):
    return None if m is None else [m.start(), m.end()]


def r5_scrub(clause):
    if JVM.R5_ACCESS_CTX_RE.search(clause):
        clause = JVM.R5_ACCESS_ACTION_RE.sub("\x00", clause)
    return clause


def cg_sentence_end(arg):
    text, pos, endpos = arg
    m = CG.SENTENCE_END_RE.search(text, pos, endpos)
    return None if m is None else m.start()


def cg_coverage_problem(body):
    return CG.coverage_problem(body)


def cg_number(prose):
    return CG.stated_number(prose)


def cg_bullet(line):
    m = CG.BULLET_RE.match(line)
    return None if m is None else [len(m.group(1)), m.group(2)]


def cg_judge(text):
    return [list(x) for x in CG.judge_bullet(text)]


FUNCS = {
    "clauses": lambda s: LB.clauses(s),
    "jvm.r1_feature": lambda s: bool(JVM.R1_FEATURE_RE.search(s)),
    "jvm.r1_verb": lambda s: bool(JVM.R1_VERB_RE.search(s)),
    "jvm.r1_evidence": lambda s: bool(JVM.R1_EVIDENCE_RE.search(s)),
    "jvm.access_ctx": lambda s: bool(JVM.R5_ACCESS_CTX_RE.search(s)),
    "jvm.access_scrub": r5_scrub,
    "jvm.r5_consequence": lambda s: bool(JVM.r5_consequence(s)),
    "jvm.r5_perm_context": lambda s: bool(JVM.R5_PERM_CONTEXT_RE.search(s)),
    "jvm.r5_cleared": lambda s: bool(JVM.R5_CLEARED_RE.search(s)),
    "jvm.r5_gap_ref": lambda s: bool(JVM.R5_GAP_REF_RE.search(s)),
    "jvm.r7_trigger": lambda s: bool(JVM.R7_TRIGGER_RE.search(s)),
    "jvm.r7_evidence": lambda s: bool(JVM.R7_EVIDENCE_RE.search(s)),
    "mv.baseline": lambda s: bool(MV.R8_BASELINE_RE.search(s)),
    "mv.surface": lambda s: bool(MV.R8_SURFACE_RE.search(s)),
    "mv.negation": lambda s: bool(MV.R8_NEGATION_RE.search(s)),
    "mv.whether": lambda s: bool(MV.R8_WHETHER_RE.search(s)),
    "mv.question_open": lambda s: bool(MV.R8_QUESTION_OPEN_RE.search(s)),
    "mv.sentence_spans": lambda s: [list(x) for x in MV.spans_of(s, MV.R8_SENTENCE_END_RE)],
    "mv.question_spans": lambda s: [list(x) for x in MV.spans_of(s, MV.R8_QUESTION_END_RE)],
    "mv.is_claim": lambda s: bool(MV.is_r8_claim(s)),
    "nb.native": lambda s: bool(NB.R9_NATIVE_RE.search(s)),
    "nb.sha256": lambda s: bool(NB.R9_SHA256_RE.search(s)),
    "nb.anchor": lambda s: bool(NB.R9_ANCHOR_RE.search(s)),
    "nb.instruments": lambda s: sorted(NB.instruments(s)),
    "cg.section": lambda s: bool(CG.SECTION_RE.search(s)),
    "cg.excluded_title": lambda s: bool(CG.EXCLUDED_TITLE_RE.search(s)),
    "cg.sentence_end": cg_sentence_end,
    "cg.placeholder": lambda s: bool(CG.PLACEHOLDER_RE.match(s)),
    "cg.result_placeholder": lambda s: bool(CG.RESULT_PLACEHOLDER_RE.match(s)),
    "cg.prose_placeholder": lambda s: bool(CG.PROSE_PLACEHOLDER_RE.search(s)),
    "cg.number": cg_number,
    "cg.ref_mask": lambda s: CG.REF_RE.sub(" ", s),
    "cg.bullet": cg_bullet,
    "cg.coverage_problem": cg_coverage_problem,
    "cg.judge": cg_judge,
    "cg.label": lambda s: bool(CG.LABEL_RE.match(s)),
}


def main():
    req = json.load(sys.stdin)
    out = []
    for call in req["calls"]:
        fn = FUNCS[call["fn"]]
        out.append([fn(x) for x in call["inputs"]])
    json.dump({"results": out}, sys.stdout, ensure_ascii=False, separators=(",", ":"))


if __name__ == "__main__":
    main()
