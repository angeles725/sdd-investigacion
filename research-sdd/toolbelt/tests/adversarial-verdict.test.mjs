// adversarial-verdict.test.mjs — RED-FIRST unit tests for the seal decision.
// Run: node research-sdd/toolbelt/tests/adversarial-verdict.test.mjs
//
// The discriminating cases are the DEGRADED-vote ones (fewer than a full panel), which
// the old fixed `refutes < 2` rule got wrong (false seal). Teeth: a copy of the OLD buggy
// rule must DISAGREE with the fixed one on those cases — proving the tests catch the bug.

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { sealVerdict, VERDICT_SCHEMA } from '../adversarial-verdict.mjs';

let pass = 0, fail = 0;
const V = (refuted) => ({ refuted });                 // a valid vote (no confidence — legacy shape)
const Vc = (refuted, confidence) => ({ refuted, confidence }); // a valid vote WITH confidence
const ok = (m) => { console.log('  PASS  ' + m); pass++; };
const no = (m) => { console.log('  FAIL  ' + m); fail++; };
const eq = (m, got, want) => (got === want ? ok(`${m} → ${got}`) : no(`${m} — got ${got}, want ${want}`));

console.log('== adversarial-verdict.test.mjs ==');

// full panel of 3 — the majority rule
eq('3 votes, 0 refute',  sealVerdict([V(false),V(false),V(false)]).verdict, 'SURVIVES');
eq('3 votes, 1 refute',  sealVerdict([V(true), V(false),V(false)]).verdict, 'SURVIVES');
eq('3 votes, 2 refute',  sealVerdict([V(true), V(true), V(false)]).verdict, 'KILLED');
eq('3 votes, 3 refute',  sealVerdict([V(true), V(true), V(true)]).verdict,  'KILLED');

// degraded panels — the bug-fix zone
eq('2 votes, 0 refute',  sealVerdict([V(false),V(false)]).verdict, 'SURVIVES');
eq('2 votes, 1 refute',  sealVerdict([V(true), V(false)]).verdict, 'KILLED');      // was wrongly SURVIVES
eq('1 valid vote (refute), 2 died', sealVerdict([V(true), null, null]).verdict, 'INSUFFICIENT'); // never seal on one
eq('1 valid vote (survive), 2 died', sealVerdict([V(false), null, null]).verdict, 'INSUFFICIENT');
eq('0 valid votes',      sealVerdict([null, null, null]).verdict, 'INSUFFICIENT');
eq('nulls filtered, 3 real', sealVerdict([V(true),V(true),null,V(false)]).verdict, 'KILLED');
eq('non-array input',    sealVerdict(undefined).verdict, 'INSUFFICIENT');

// TEETH — the OLD buggy rule (fixed `refutes < 2`, no quorum) must DISAGREE on the degraded cases.
function buggyVerdict(votes) {
  const valid = (votes || []).filter(Boolean);
  const refutes = valid.filter((v) => v && v.refuted).length;
  return refutes < 2 ? 'SURVIVES' : 'KILLED';   // the pre-fix logic
}
const teethCases = [
  [V(true), V(false)],            // 2 votes 1 refute: fixed=KILLED, buggy=SURVIVES
  [V(true), null, null],          // 1 valid refute: fixed=INSUFFICIENT, buggy=SURVIVES
];
let flips = 0;
for (const c of teethCases) if (sealVerdict(c).verdict !== buggyVerdict(c)) flips++;
if (flips === teethCases.length) ok(`teeth: fixed rule disagrees with the buggy rule on all ${flips} degraded cases`);
else no(`teeth: only ${flips}/${teethCases.length} cases differ — tests do not discriminate the bug (THEATER)`);

// ── CONFIDENCE-GRADED SEAL (part a of the audit fix) ──────────────────────────
// A claim that SURVIVES the refute-count must ALSO clear a mean-confidence bar on its
// surviving votes; otherwise it survived only weakly → INSUFFICIENT (not sealed).
eq('3 survive @0.5,0.5,0.5 (mean .5 < .7) → not sealed',
   sealVerdict([Vc(false, 0.5), Vc(false, 0.5), Vc(false, 0.5)]).verdict, 'INSUFFICIENT');
eq('3 survive @0.9,0.8,0.95 (mean ≥ .7) → sealed',
   sealVerdict([Vc(false, 0.9), Vc(false, 0.8), Vc(false, 0.95)]).verdict, 'SURVIVES');
eq('boundary: 3 survive @0.7 (mean == .7 → >=) → sealed',
   sealVerdict([Vc(false, 0.7), Vc(false, 0.7), Vc(false, 0.7)]).verdict, 'SURVIVES');
// KILLED is decided by the refute-count and is UNAFFECTED by (even high) confidence.
eq('2-of-3 refute @0.9 → KILLED regardless of confidence',
   sealVerdict([Vc(true, 0.9), Vc(true, 0.9), Vc(false, 0.9)]).verdict, 'KILLED');
// Below quorum stays INSUFFICIENT even with a high-confidence lone survivor.
eq('1 valid survivor @0.99, 2 died → INSUFFICIENT (quorum)',
   sealVerdict([Vc(false, 0.99), null, null]).verdict, 'INSUFFICIENT');
// BACKWARD-COMPAT: surviving votes with NO confidence field keep today's SURVIVES.
eq('3 survive, NO confidence field → SURVIVES (legacy shape unchanged)',
   sealVerdict([V(false), V(false), V(false)]).verdict, 'SURVIVES');
// Transparency: meanConfidence + confThreshold are surfaced on the returned object.
{
  const s = sealVerdict([Vc(false, 0.5), Vc(false, 0.5), Vc(false, 0.5)]);
  eq('meanConfidence surfaced', s.meanConfidence, 0.5);
  eq('confThreshold surfaced (default)', s.confThreshold, 0.7);
}
{
  const s = sealVerdict([V(false), V(false), V(false)]);
  eq('meanConfidence null when confidence absent', s.meanConfidence, null);
}
// A custom confThreshold is honored.
eq('mean .5 clears a custom confThreshold .4 → SURVIVES',
   sealVerdict([Vc(false, 0.5), Vc(false, 0.5)], { confThreshold: 0.4 }).verdict, 'SURVIVES');
// MIXED shape — pins CURRENT behavior: the mean is over the PRESENT confidences only, so a lone
// graded survivor among ungraded ones single-handedly decides the seal (latent for future callers;
// can't trigger live — VERDICT_SCHEMA marks confidence required, so real votes always carry it).
{
  const hi = sealVerdict([Vc(false, 0.9), V(false), V(false)]);
  eq('mixed: one @0.9 + two ungraded → SURVIVES (mean over present only)', hi.verdict, 'SURVIVES');
  eq('mixed: meanConfidence is 0.9 (the lone present value)', hi.meanConfidence, 0.9);
  const lo = sealVerdict([Vc(false, 0.1), V(false), V(false)]);
  eq('mixed: one @0.1 + two ungraded → INSUFFICIENT (mean over present only)', lo.verdict, 'INSUFFICIENT');
  eq('mixed: meanConfidence is 0.1 (the lone present value)', lo.meanConfidence, 0.1);
}

// ── QUORUM-FLOOR DEFENSE (audit fix) ─────────────────────────────────────────
// A non-finite or < 1 quorum (hand-written/legacy plan.json, or an un-validated CLI flag)
// must NOT disable the below-quorum INSUFFICIENT floor: a lone survivor with 2 dead skeptics
// can never seal on a degraded 1-of-3 panel. The kernel falls back to the safe default.
eq('quorum=0 defense: 1 live survivor, 2 dead → INSUFFICIENT (floor not disabled)',
   sealVerdict([V(false), null, null], { quorum: 0 }).verdict, 'INSUFFICIENT');
eq('quorum=-1 defense: 1 live survivor, 2 dead → INSUFFICIENT',
   sealVerdict([V(false), null, null], { quorum: -1 }).verdict, 'INSUFFICIENT');
eq('quorum=NaN defense: 1 live survivor, 2 dead → INSUFFICIENT',
   sealVerdict([V(false), null, null], { quorum: NaN }).verdict, 'INSUFFICIENT');
eq('quorum=Infinity defense: 1 live survivor, 2 dead → INSUFFICIENT',
   sealVerdict([V(false), null, null], { quorum: Infinity }).verdict, 'INSUFFICIENT');
// The defense restores the safe floor, it is not a lockout: a full 3-survivor panel still seals.
eq('quorum=0 defense: full 3-survivor panel still SURVIVES (not a lockout)',
   sealVerdict([Vc(false, 0.9), Vc(false, 0.9), Vc(false, 0.9)], { quorum: 0 }).verdict, 'SURVIVES');
// A legitimate quorum=1 is honored (integer >= 1 is valid — not clamped away).
eq('quorum=1 honored: 1 live survivor → SURVIVES (legit low quorum)',
   sealVerdict([Vc(false, 0.9), null, null], { quorum: 1 }).verdict, 'SURVIVES');

// TEETH — neutering the quorum-floor clamp flips the degraded case to a FALSE SURVIVES.
{
  const badQuorum = 0;
  function unclampedVerdict(votes, quorum) {           // pre-fix: raw quorum, no clamp/fallback
    const valid = (votes || []).filter(Boolean);
    const refutes = valid.filter((v) => v && v.refuted === true).length;
    if (valid.length < quorum) return 'INSUFFICIENT';
    const killThreshold = Math.ceil(valid.length / 2);
    if (refutes >= killThreshold) return 'KILLED';
    return 'SURVIVES';
  }
  const honest = sealVerdict([V(false), null, null], { quorum: badQuorum }).verdict;
  const mutant = unclampedVerdict([V(false), null, null], badQuorum);
  if (honest === 'INSUFFICIENT' && mutant === 'SURVIVES')
    ok('teeth: quorum-floor clamp is load-bearing — a bad quorum=0 flips a 1-live panel to false SURVIVES when neutered');
  else no(`teeth: quorum-clamp mutant did NOT flip (honest=${honest}, mutant=${mutant}) — THEATER`);
}

// ── CONFIDENCE-BOUND DEFENSE (audit fix) ─────────────────────────────────────
// An out-of-[0,1] / non-finite confidence (a 0-1 vs 0-100 scale slip) must be DROPPED from
// the mean-confidence gate, never inflate it. Outcome must match the honest all-0.5 case,
// which the suite already pins to INSUFFICIENT.
eq('conf=95 dropped: [0.5, 0.5, 95] → INSUFFICIENT (same as honest all-0.5, no inflation)',
   sealVerdict([Vc(false, 0.5), Vc(false, 0.5), Vc(false, 95)]).verdict, 'INSUFFICIENT');
eq('conf=95 dropped: meanConfidence is the honest 0.5 (the 95 is not counted)',
   sealVerdict([Vc(false, 0.5), Vc(false, 0.5), Vc(false, 95)]).meanConfidence, 0.5);
eq('conf=-1 dropped: [0.5, 0.5, -1] → INSUFFICIENT',
   sealVerdict([Vc(false, 0.5), Vc(false, 0.5), Vc(false, -1)]).verdict, 'INSUFFICIENT');
eq('conf=Infinity dropped: [0.5, 0.5, Infinity] → INSUFFICIENT',
   sealVerdict([Vc(false, 0.5), Vc(false, 0.5), Vc(false, Infinity)]).verdict, 'INSUFFICIENT');
// In-range boundary confidences (0 and 1) still participate.
eq('conf boundary: [1, 1, 1] → SURVIVES (mean 1 ≥ .7)',
   sealVerdict([Vc(false, 1), Vc(false, 1), Vc(false, 1)]).verdict, 'SURVIVES');
eq('conf boundary 0: [0, 0, 0] → INSUFFICIENT (conf=0 is counted, mean 0 < .7 — not dropped as out-of-range)',
   sealVerdict([Vc(false, 0), Vc(false, 0), Vc(false, 0)]).verdict, 'INSUFFICIENT');

// TEETH — neutering the confidence range check flips [0.5,0.5,95] to a FALSE SURVIVES.
{
  function unboundedMeanVerdict(votes, confThreshold = 0.7) {   // pre-fix: typeof number only, no range
    const valid = (votes || []).filter(Boolean);
    const surviving = valid.filter((v) => v.refuted !== true);
    const confs = surviving.map((v) => v.confidence).filter((c) => typeof c === 'number');
    if (confs.length === 0) return 'SURVIVES';
    const mean = confs.reduce((a, b) => a + b, 0) / confs.length;
    return mean >= confThreshold ? 'SURVIVES' : 'INSUFFICIENT';
  }
  const votes = [Vc(false, 0.5), Vc(false, 0.5), Vc(false, 95)];
  const honest = sealVerdict(votes).verdict;
  const mutant = unboundedMeanVerdict(votes);
  if (honest === 'INSUFFICIENT' && mutant === 'SURVIVES')
    ok('teeth: confidence-bound is load-bearing — a conf=95 scale slip flips to false SURVIVES when the range check is neutered');
  else no(`teeth: confidence-bound mutant did NOT flip (honest=${honest}, mutant=${mutant}) — THEATER`);
}

// The VERDICT_SCHEMA documents the [0,1] contract for schema-validating hosts.
eq('VERDICT_SCHEMA.confidence declares minimum 0', VERDICT_SCHEMA.properties.confidence.minimum, 0);
eq('VERDICT_SCHEMA.confidence declares maximum 1', VERDICT_SCHEMA.properties.confidence.maximum, 1);

// ── PARITY — the Workflow leg (adversarial-verify.js) must consume the ONE kernel, not a copy.
// It used to inline its own `function sealVerdict`; the [CERT] re-host deleted that dup so the
// two legs cannot drift. This asserts the single-source contract directly: the .js imports
// sealVerdict from adversarial-verdict.mjs AND defines no inline sealVerdict of its own.
const __dir = dirname(fileURLToPath(import.meta.url));
const jsSrc = readFileSync(join(__dir, '../adversarial-verify.js'), 'utf8');
const importsKernel = /import\s*\{[^}]*\}\s*from\s*['"]\.\/adversarial-verdict\.mjs['"]/.test(jsSrc)
  && /buildClaimResult/.test(jsSrc);   // the shared result builder wraps sealVerdict — no inline seal path
const noInlineSeal = !/function\s+sealVerdict\b/.test(jsSrc) && !/\bsealVerdict\s*=/.test(jsSrc);
if (importsKernel && noInlineSeal) ok('parity: adversarial-verify.js consumes the single kernel (imports it, no inline sealVerdict dup)');
else no(`parity: adversarial-verify.js drift — importsKernel=${importsKernel} noInlineSeal=${noInlineSeal}`);

console.log(`== ${pass} passed · ${fail} failed ==`);
process.exit(fail ? 1 : 0);
