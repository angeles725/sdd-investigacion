// adversarial-verdict.test.mjs — RED-FIRST unit tests for the seal decision.
// Run: node research-sdd/toolbelt/tests/adversarial-verdict.test.mjs
//
// The discriminating cases are the DEGRADED-vote ones (fewer than a full panel), which
// the old fixed `refutes < 2` rule got wrong (false seal). Teeth: a copy of the OLD buggy
// rule must DISAGREE with the fixed one on those cases — proving the tests catch the bug.

import { sealVerdict } from '../adversarial-verdict.mjs';

let pass = 0, fail = 0;
const V = (refuted) => ({ refuted });                 // a valid vote
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

console.log(`== ${pass} passed · ${fail} failed ==`);
process.exit(fail ? 1 : 0);
