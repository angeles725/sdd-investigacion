// adversarial-verdict — the pure, deterministic SEAL decision for adversarial-verify.
//
// Extracted from the workflow so the decision that seals/kills a [CERT] claim is unit-
// testable WITHOUT running LLM skeptics. The workflow (adversarial-verify.js) imports
// sealVerdict; adversarial-verdict.test.mjs proves it red-first.
//
// The rule: KILL a claim on majority-refute among the VALID (non-null) skeptic votes.
// A skeptic that died returns null and is dropped. If fewer than `quorum` valid votes
// came back, the verdict is INSUFFICIENT — the claim is NOT sealed on thin/degraded
// evidence. (This replaced a fixed `refutes < 2` threshold that let a SINGLE refuting
// vote "survive" when two skeptics died — a false seal on one hostile vote.)
//
// CONFIDENCE-GRADED SEAL: when the refute-count says SURVIVES, the SURVIVING votes must
// ALSO clear a mean `confidence` bar (`confThreshold`, default 0.7); below it the claim
// survived only weakly → INSUFFICIENT (not sealed as full [CERT]). Backward-compatible:
// the gate applies ONLY when the surviving votes carry a numeric `confidence`; legacy
// confidence-less callers keep today's SURVIVES. Returns `meanConfidence` + `confThreshold`.

export function sealVerdict(votes, { quorum = 2, confThreshold = 0.7 } = {}) {
  const valid = (Array.isArray(votes) ? votes : []).filter(Boolean);
  const refutes = valid.filter((v) => v && v.refuted === true).length;
  if (valid.length < quorum) {
    return { valid: valid.length, refutes, killThreshold: null, verdict: 'INSUFFICIENT', meanConfidence: null, confThreshold };
  }
  // >= half of the valid votes refuting kills the claim (conservative: with only 2 valid
  // votes even one refute kills; with a full panel of 3 it takes a 2-of-3 majority).
  const killThreshold = Math.ceil(valid.length / 2);
  if (refutes >= killThreshold) {
    return { valid: valid.length, refutes, killThreshold, verdict: 'KILLED', meanConfidence: null, confThreshold };
  }
  // The refute-count says SURVIVES — GRADE it by the mean confidence of the SURVIVING votes
  // (valid && !refuted). A claim that survived only at low skeptic confidence must NOT seal as
  // full [CERT] → INSUFFICIENT. Backward-compat: if the surviving votes carry no numeric
  // `confidence` (legacy callers), the gate does not apply and today's SURVIVES is preserved.
  const surviving = valid.filter((v) => v.refuted !== true);
  // Mean is over surviving votes that carry a numeric confidence; ungraded survivors do NOT
  // dilute it (live path: all skeptic votes carry confidence per VERDICT_SCHEMA's required field).
  const confs = surviving.map((v) => v.confidence).filter((c) => typeof c === 'number');
  if (confs.length === 0) {
    return { valid: valid.length, refutes, killThreshold, verdict: 'SURVIVES', meanConfidence: null, confThreshold };
  }
  // Round to 6 decimals so IEEE754 dust (e.g. (0.7+0.7+0.7)/3 = 0.6999…998) can't sink a
  // mean that is mathematically == confThreshold; the seal is `>= confThreshold`.
  const meanConfidence = Math.round((confs.reduce((a, b) => a + b, 0) / confs.length) * 1e6) / 1e6;
  const verdict = meanConfidence >= confThreshold ? 'SURVIVES' : 'INSUFFICIENT';
  return { valid: valid.length, refutes, killThreshold, verdict, meanConfidence, confThreshold };
}
