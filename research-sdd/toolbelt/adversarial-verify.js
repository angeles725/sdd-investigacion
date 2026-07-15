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

// ONE kernel, no dup: the seal decision, the verdict schema, the skeptic prompt, the result
// shape + [CERT] labels all live in adversarial-verdict.mjs. This Workflow leg imports them so
// it can never drift from the harness-agnostic plan/seal CLI (adversarial-verify.mjs). The
// inline sealVerdict copy that used to live here is GONE — see adversarial-verdict.mjs.
import {
  VERDICT_SCHEMA,
  buildSkepticPrompt,
  buildClaimResult,
  summarize,
  DEFAULT_N,
} from './adversarial-verdict.mjs'

export const meta = {
  name: 'adversarial-verify',
  description: 'Adversarially verify a list of claims: 3 skeptics per claim, kill on majority-refute (research-sdd [CERT] sealer prototype)',
  phases: [{ title: 'Verify', detail: '3 adversarial skeptics per claim, majority vote' }],
}

// Defensive: args may arrive as an array OR as a JSON-encoded string.
let claims = args
if (typeof claims === 'string') { try { claims = JSON.parse(claims) } catch (e) { claims = [] } }
claims = Array.isArray(claims) ? claims : []
if (!claims.length) { return { error: 'no claims provided in args' } }

const N = DEFAULT_N
phase('Verify')

const results = await pipeline(
  claims,
  (c, _orig, i) =>
    parallel(Array.from({ length: N }, (_unused, k) =>
      () => agent(
        // Same rendered prompt the plan/seal CLI emits — one builder, byte-for-byte in lockstep.
        buildSkepticPrompt(c, k + 1, N),
        { label: `verify:${c.id || 'c' + i}:skeptic${k + 1}`, phase: 'Verify', model: 'sonnet', schema: VERDICT_SCHEMA }
      )
    )).then(votes =>
      // votes carry `confidence` → seal is confidence-graded; one shared result builder + labels.
      buildClaimResult({ id: c.id || 'c' + i, claim: c.claim }, votes)
    )
)

const s = summarize(results)
log(`Adversarial verify done: ${s.survived} sealed, ${s.killed} killed, ${s.insufficient} insufficient of ${s.total} claims`)
return s
