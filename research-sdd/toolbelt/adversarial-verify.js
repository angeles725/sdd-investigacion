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
      const valid = votes.filter(Boolean)
      const refutes = valid.filter(v => v.refuted).length
      const survives = refutes < 2
      return {
        id: c.id || 'c' + i,
        claim: c.claim,
        refutes,
        total: valid.length,
        verdict: survives ? 'SURVIVES ([CERT] sealed)' : 'KILLED',
        votes: valid.map(v => ({ refuted: v.refuted, confidence: v.confidence, reasoning: v.reasoning })),
      }
    })
)

const kept = results.filter(r => r.verdict.startsWith('SURVIVES'))
const killed = results.filter(r => r.verdict === 'KILLED')
log(`Adversarial verify done: ${kept.length} survived, ${killed.length} killed of ${results.length} claims`)
return { survived: kept.length, killed: killed.length, total: results.length, results }
