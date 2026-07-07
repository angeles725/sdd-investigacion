// adversarial-verdict.test.mjs — RED-FIRST unit tests for the seal decision.
// Run: node research-sdd/toolbelt/tests/adversarial-verdict.test.mjs
//
// The discriminating cases are the DEGRADED-vote ones (fewer than a full panel), which
// the old fixed `refutes < 2` rule got wrong (false seal). Teeth: a copy of the OLD buggy
// rule must DISAGREE with the fixed one on those cases — proving the tests catch the bug.

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { sealVerdict } from '../adversarial-verdict.mjs';

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

// ── PARITY — the .mjs export and the INLINE copy in adversarial-verify.js must not drift.
// The inline copy is not exported (the workflow file must stay self-contained for the engine),
// so we extract its `sealVerdict` source by brace-matching and materialize it via new Function.
function extractInlineSealVerdict(src) {
  const start = src.indexOf('function sealVerdict');
  if (start < 0) throw new Error('inline sealVerdict not found in adversarial-verify.js');
  // Skip the parameter list first (it contains braces: `{ quorum = 2 } = {}`), matching
  // parens, so we begin brace-matching at the function BODY's opening `{`, not a param one.
  let p = 0, i = src.indexOf('(', start);
  for (; i < src.length; i++) {
    if (src[i] === '(') p++;
    else if (src[i] === ')' && --p === 0) { i++; break; }
  }
  let depth = 0, end = src.indexOf('{', i);
  for (; end < src.length; end++) {
    if (src[end] === '{') depth++;
    else if (src[end] === '}' && --depth === 0) { end++; break; }
  }
  // eslint-disable-next-line no-new-func
  return new Function(`${src.slice(start, end)}; return sealVerdict;`)();
}
const __dir = dirname(fileURLToPath(import.meta.url));
const jsSrc = readFileSync(join(__dir, '../adversarial-verify.js'), 'utf8');
const inlineSeal = extractInlineSealVerdict(jsSrc);
const parityMatrix = [
  [[V(false), V(false), V(false)], undefined],
  [[V(true), V(false), V(false)], undefined],
  [[V(true), V(true), V(false)], undefined],
  [[V(true), null, null], undefined],
  [[null, null, null], undefined],
  [[Vc(false, 0.5), Vc(false, 0.5), Vc(false, 0.5)], undefined],
  [[Vc(false, 0.9), Vc(false, 0.8), Vc(false, 0.95)], undefined],
  [[Vc(false, 0.7), Vc(false, 0.7), Vc(false, 0.7)], undefined],
  [[Vc(true, 0.9), Vc(true, 0.9), Vc(false, 0.9)], undefined],
  [[Vc(false, 0.99), null, null], undefined],
  [[Vc(false, 0.5), Vc(false, 0.5)], { confThreshold: 0.4 }],
  [[Vc(false, 0.9), V(false), V(false)], undefined],   // mixed shape — mean over present only
  [[Vc(false, 0.1), V(false), V(false)], undefined],   // mixed shape — lone graded survivor sinks it
];
let drift = 0;
for (const [c, opt] of parityMatrix) {
  const a = sealVerdict(c, opt), b = inlineSeal(c, opt);
  if (a.verdict !== b.verdict || a.meanConfidence !== b.meanConfidence) drift++;
}
if (drift === 0) ok(`parity: .mjs export and inline .js sealVerdict agree on all ${parityMatrix.length} matrix rows`);
else no(`parity: ${drift}/${parityMatrix.length} rows DRIFT between the two sealVerdict copies`);

console.log(`== ${pass} passed · ${fail} failed ==`);
process.exit(fail ? 1 : 0);
