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

// ── Shared kernel constants + builders ────────────────────────────────────────
// One source of truth for BOTH legs of the sealer: the Workflow script
// (adversarial-verify.js) and the harness-agnostic plan/seal CLI (adversarial-verify.mjs).
// Nothing below changes the sealing math; it only stops the two legs from drifting on the
// skeptic prompt wording, the verdict schema, the result shape, or the [CERT] label strings.

export const DEFAULT_N = 3;
export const DEFAULT_QUORUM = 2;
export const DEFAULT_CONF_THRESHOLD = 0.7;

// The verdict schema every skeptic must satisfy (moved here from the .js leg; do NOT change).
export const VERDICT_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  properties: {
    refuted: { type: 'boolean', description: 'true if the claim is false, unsupported, or overstated' },
    confidence: { type: 'number', minimum: 0, maximum: 1, description: '0..1 confidence in your verdict' },
    reasoning: { type: 'string', description: 'one or two sentences' },
    evidence: { type: 'string', description: 'URL or quote supporting your verdict, if any' },
  },
  required: ['refuted', 'confidence', 'reasoning'],
};

// buildSkepticPrompt — render ONE skeptic's prompt. `num` is the 1-based skeptic number
// shown to the model ("#num of n"). BYTE-IDENTICAL to the original adversarial-verify.js
// template; tests/adversarial-verify.test.mjs pins it against frozen goldens. Do NOT reword.
export function buildSkepticPrompt(claim, num, n) {
  const c = claim || {};
  return (
    `You are adversarial fact-checker / skeptic #${num} of ${n}. Your JOB is to REFUTE the claim below.\n` +
    `Use web search and your own knowledge to find evidence that the claim is FALSE, unsupported, inaccurate, or overstated.\n` +
    `A claim survives ONLY if it is clearly and verifiably true. If you cannot confirm it with confidence, default to refuted=true.\n\n` +
    `CLAIM: "${c.claim}"\n` +
    (c.source ? `CITED SOURCE: ${c.source}\n` : '') +
    `\nReturn: refuted (true = the claim is false/unsupported), confidence (0..1), reasoning, and evidence (a URL or quote) if you found any.`
  );
}

// sealLabel — the user-facing verdict string. The research-sdd driver keys the [CERT]
// keep/downgrade/drop decision off these EXACT strings; do NOT change the wording.
export function sealLabel(verdict) {
  return verdict === 'SURVIVES' ? 'SURVIVES ([CERT] sealed)'
       : verdict === 'KILLED' ? 'KILLED'
       : 'INSUFFICIENT (too few skeptics survived, or survived below the confidence bar — NOT sealed)';
}

// buildClaimResult — the per-claim result object, identical for both legs. `votes` may
// contain nulls (dead skeptics); they are dropped for the returned `votes` list and are
// already excluded from the seal by sealVerdict. Shape matches today's .js return verbatim.
export function buildClaimResult({ id, claim }, votes, opts = {}) {
  const s = sealVerdict(votes, opts);
  return {
    id,
    claim,
    refutes: s.refutes,
    total: s.valid,
    meanConfidence: s.meanConfidence,
    confThreshold: s.confThreshold,
    verdict: sealLabel(s.verdict),
    votes: (Array.isArray(votes) ? votes : []).filter(Boolean).map((v) => ({ refuted: v.refuted, confidence: v.confidence, reasoning: v.reasoning })),
  };
}

// summarize — roll per-claim results into the top-level { survived, killed, insufficient,
// total, results } object. Buckets are keyed off the label prefixes (same as today's .js).
export function summarize(results) {
  const kept = results.filter((r) => r.verdict.startsWith('SURVIVES'));
  const killed = results.filter((r) => r.verdict === 'KILLED');
  const insufficient = results.filter((r) => r.verdict.startsWith('INSUFFICIENT'));
  return { survived: kept.length, killed: killed.length, insufficient: insufficient.length, total: results.length, results };
}

export function sealVerdict(votes, { quorum = DEFAULT_QUORUM, confThreshold = DEFAULT_CONF_THRESHOLD } = {}) {
  // DEFENSE: a non-finite or < 1 quorum (legacy/hand-written plan.json, or an un-validated CLI
  // flag) must NEVER disable the below-quorum INSUFFICIENT floor — otherwise `valid.length < 0`
  // never fires and a degraded 1-of-3 panel falsely seals. Fall back to the safe default so a
  // bad quorum can only ever be SAFER (a higher floor), never a floor-disabling seal.
  const q = (Number.isFinite(quorum) && quorum >= 1) ? quorum : DEFAULT_QUORUM;
  const valid = (Array.isArray(votes) ? votes : []).filter(Boolean);
  const refutes = valid.filter((v) => v && v.refuted === true).length;
  if (valid.length < q) {
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
  // DEFENSE: only a FINITE confidence in [0,1] participates. An out-of-range value (e.g. a
  // 0-1 vs 0-100 scale slip like 95) or a non-finite one is DROPPED — it can never inflate the
  // mean into a false seal. An ungraded survivor (no numeric confidence) still simply abstains.
  const confs = surviving
    .map((v) => v.confidence)
    .filter((c) => typeof c === 'number' && Number.isFinite(c) && c >= 0 && c <= 1);
  if (confs.length === 0) {
    return { valid: valid.length, refutes, killThreshold, verdict: 'SURVIVES', meanConfidence: null, confThreshold };
  }
  // Round to 6 decimals so IEEE754 dust (e.g. (0.7+0.7+0.7)/3 = 0.6999…998) can't sink a
  // mean that is mathematically == confThreshold; the seal is `>= confThreshold`.
  const meanConfidence = Math.round((confs.reduce((a, b) => a + b, 0) / confs.length) * 1e6) / 1e6;
  const verdict = meanConfidence >= confThreshold ? 'SURVIVES' : 'INSUFFICIENT';
  return { valid: valid.length, refutes, killThreshold, verdict, meanConfidence, confThreshold };
}
