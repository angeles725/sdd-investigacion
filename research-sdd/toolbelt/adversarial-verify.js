// adversarial-verify — Research-SDD [CERT] sealer (Workflow engine)
//
// WHAT IT DOES: adversarially verifies a list of claims. For each claim it runs N=3
// skeptics IN PARALLEL, each instructed to REFUTE the claim (default to refuted when it
// cannot be confirmed). A claim SURVIVES ("[CERT] sealed") only on MAJORITY SURVIVE —
// i.e. it is KILLED on majority-refute (>=2 of 3 skeptics refute it). Use it to SEAL
// load-bearing [CERT] claims instead of trusting only the sub-agent self-report (§11).
// Validated 3/3 true survived, 3/3 plausible-false killed (caught a transport-vs-port error).
//
// ARGS: a JSON array of { id, claim, source? } objects. `source` (optional) is the cited
// evidence (file:line for LOCAL claims → skeptics read it, no web needed → cheap; only
// web-verifiable claims are expensive). Note: `args` may arrive as an array OR as a
// JSON-encoded string, hence the defensive JSON.parse below.
//
// RULE: majority-refute kills. survives iff refutes < 2 of the valid votes.
// MODEL: skeptics run on model:'sonnet'.
//
// RETURNS: { survived, killed, total, results[] } — each result carries its verdict,
// refute count, and the per-skeptic votes.

export const meta = {
  name: 'adversarial-verify',
  description: 'Adversarially verify a list of claims: 3 skeptics per claim, kill on majority-refute (research-sdd [CERT] sealer prototype)',
  phases: [{ title: 'Verify', detail: '3 adversarial skeptics per claim, majority vote' }],
}

const VERDICT_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  properties: {
    refuted: { type: 'boolean', description: 'true if the claim is false, unsupported, or overstated' },
    confidence: { type: 'number', description: '0..1 confidence in your verdict' },
    reasoning: { type: 'string', description: 'one or two sentences' },
    evidence: { type: 'string', description: 'URL or quote supporting your verdict, if any' },
  },
  required: ['refuted', 'confidence', 'reasoning'],
}

// sealVerdict — inlined so this Workflow script stays self-contained for the engine.
// CANONICAL copy + red-first tests: adversarial-verdict.mjs / tests/adversarial-verdict.test.mjs.
// KILL on majority-refute of VALID (non-null) votes; INSUFFICIENT (never seal) below quorum —
// a fixed `refutes < 2` used to SEAL a claim on a single refuting vote when two skeptics died.
// CONFIDENCE-GRADED: a claim whose refute-count SURVIVES must ALSO clear a mean-confidence bar
// on its surviving votes (confThreshold, default 0.7), else INSUFFICIENT (survived weakly, not
// sealed). Backward-compat: the gate applies only when surviving votes carry numeric confidence.
// KEEP IDENTICAL to adversarial-verdict.mjs (tests/adversarial-verdict.test.mjs pins parity).
function sealVerdict(votes, { quorum = 2, confThreshold = 0.7 } = {}) {
  const valid = (Array.isArray(votes) ? votes : []).filter(Boolean)
  const refutes = valid.filter(v => v && v.refuted === true).length
  if (valid.length < quorum) return { valid: valid.length, refutes, killThreshold: null, verdict: 'INSUFFICIENT', meanConfidence: null, confThreshold }
  const killThreshold = Math.ceil(valid.length / 2)
  if (refutes >= killThreshold) return { valid: valid.length, refutes, killThreshold, verdict: 'KILLED', meanConfidence: null, confThreshold }
  const surviving = valid.filter(v => v.refuted !== true)
  // Mean is over surviving votes that carry a numeric confidence; ungraded survivors do NOT
  // dilute it (live path: all skeptic votes carry confidence per VERDICT_SCHEMA's required field).
  const confs = surviving.map(v => v.confidence).filter(c => typeof c === 'number')
  if (confs.length === 0) return { valid: valid.length, refutes, killThreshold, verdict: 'SURVIVES', meanConfidence: null, confThreshold }
  const meanConfidence = Math.round((confs.reduce((a, b) => a + b, 0) / confs.length) * 1e6) / 1e6
  const verdict = meanConfidence >= confThreshold ? 'SURVIVES' : 'INSUFFICIENT'
  return { valid: valid.length, refutes, killThreshold, verdict, meanConfidence, confThreshold }
}

// Defensive: args may arrive as an array OR as a JSON-encoded string.
let claims = args
if (typeof claims === 'string') { try { claims = JSON.parse(claims) } catch (e) { claims = [] } }
claims = Array.isArray(claims) ? claims : []
if (!claims.length) { return { error: 'no claims provided in args' } }

const N = 3
phase('Verify')

const results = await pipeline(
  claims,
  (c, _orig, i) =>
    parallel(Array.from({ length: N }, (_unused, k) =>
      () => agent(
        `You are adversarial fact-checker / skeptic #${k + 1} of ${N}. Your JOB is to REFUTE the claim below.\n` +
        `Use web search and your own knowledge to find evidence that the claim is FALSE, unsupported, inaccurate, or overstated.\n` +
        `A claim survives ONLY if it is clearly and verifiably true. If you cannot confirm it with confidence, default to refuted=true.\n\n` +
        `CLAIM: "${c.claim}"\n` +
        (c.source ? `CITED SOURCE: ${c.source}\n` : '') +
        `\nReturn: refuted (true = the claim is false/unsupported), confidence (0..1), reasoning, and evidence (a URL or quote) if you found any.`,
        { label: `verify:${c.id || 'c' + i}:skeptic${k + 1}`, phase: 'Verify', model: 'sonnet', schema: VERDICT_SCHEMA }
      )
    )).then(votes => {
      const s = sealVerdict(votes)   // votes carry `confidence` → seal is confidence-graded
      const label = s.verdict === 'SURVIVES' ? 'SURVIVES ([CERT] sealed)'
                  : s.verdict === 'KILLED'   ? 'KILLED'
                  :                            'INSUFFICIENT (too few skeptics survived, or survived below the confidence bar — NOT sealed)'
      return {
        id: c.id || 'c' + i,
        claim: c.claim,
        refutes: s.refutes,
        total: s.valid,
        meanConfidence: s.meanConfidence,
        confThreshold: s.confThreshold,
        verdict: label,
        votes: votes.filter(Boolean).map(v => ({ refuted: v.refuted, confidence: v.confidence, reasoning: v.reasoning })),
      }
    })
)

const kept = results.filter(r => r.verdict.startsWith('SURVIVES'))
const killed = results.filter(r => r.verdict === 'KILLED')
const insufficient = results.filter(r => r.verdict.startsWith('INSUFFICIENT'))
log(`Adversarial verify done: ${kept.length} sealed, ${killed.length} killed, ${insufficient.length} insufficient of ${results.length} claims`)
return { survived: kept.length, killed: killed.length, insufficient: insufficient.length, total: results.length, results }
