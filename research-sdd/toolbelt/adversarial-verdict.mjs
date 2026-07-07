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

export function sealVerdict(votes, { quorum = 2 } = {}) {
  const valid = (Array.isArray(votes) ? votes : []).filter(Boolean);
  const refutes = valid.filter((v) => v && v.refuted === true).length;
  if (valid.length < quorum) {
    return { valid: valid.length, refutes, killThreshold: null, verdict: 'INSUFFICIENT' };
  }
  // >= half of the valid votes refuting kills the claim (conservative: with only 2 valid
  // votes even one refute kills; with a full panel of 3 it takes a 2-of-3 majority).
  const killThreshold = Math.ceil(valid.length / 2);
  const verdict = refutes >= killThreshold ? 'KILLED' : 'SURVIVES';
  return { valid: valid.length, refutes, killThreshold, verdict };
}
