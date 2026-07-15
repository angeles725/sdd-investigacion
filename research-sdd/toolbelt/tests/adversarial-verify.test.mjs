// adversarial-verify.test.mjs — RED-FIRST tests for the harness-agnostic plan/seal CLI.
//
// This suite pins the re-hosted [CERT] sealer (adversarial-verify.mjs): the PURE `plan`
// and `seal` subcommands that replace the LLM-driven Workflow leg with a two-phase,
// harness-agnostic flow (a host renders the prompts, writes verdict files, then seals).
//
// The load-bearing invariants proven here:
//   * PROMPT PARITY — the rendered skeptic prompt is BYTE-FOR-BYTE the current
//     adversarial-verify.js template (frozen goldens, captured from that template).
//   * KERNEL, NOT A COPY — seal routes votes through the ONE sealVerdict kernel; verdict
//     labels/counts match the kernel's own test expectations exactly.
//   * DEAD SKEPTIC = null vote — a MISSING or MALFORMED verdict file becomes a null vote
//     (never a defaulted survive), so a degraded panel falls below quorum → INSUFFICIENT.
//   * LABEL/SHAPE PARITY — seal.json is the SAME object shape + label strings as today's
//     adversarial-verify.js return (the driver keys [CERT] keep/downgrade/drop off these).
//   * DETERMINISM — given fixed verdict files, `seal` is a pure function of them.
//   * TEETH — neutering the missing/malformed→null mapping flips a degraded case from
//     INSUFFICIENT to a FALSE "SURVIVES", proving the null-mapping is load-bearing.
//
// Run: node research-sdd/toolbelt/tests/adversarial-verify.test.mjs
// (auto-discovered by tests/run-all.sh; no --prove-teeth flag — the teeth check is inline.)

import { readFileSync, writeFileSync, mkdirSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { execFileSync } from 'node:child_process';

import {
  sealVerdict,
  VERDICT_SCHEMA,
  buildSkepticPrompt,
  buildClaimResult,
  summarize,
  DEFAULT_N,
  DEFAULT_QUORUM,
  DEFAULT_CONF_THRESHOLD,
} from '../adversarial-verdict.mjs';
import { buildPlan, runSeal, readVote } from '../adversarial-verify.mjs';

const __dir = dirname(fileURLToPath(import.meta.url));
const CLI = join(__dir, '..', 'adversarial-verify.mjs');

let pass = 0, fail = 0;
const ok = (m) => { console.log('  PASS  ' + m); pass++; };
const no = (m) => { console.log('  FAIL  ' + m); fail++; };
const eq = (m, got, want) => (got === want ? ok(`${m} → ${JSON.stringify(got)}`) : no(`${m} — got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`));
const deepEq = (m, got, want) => (JSON.stringify(got) === JSON.stringify(want) ? ok(m) : no(`${m}\n        got  ${JSON.stringify(got)}\n        want ${JSON.stringify(want)}`));

console.log('== adversarial-verify.test.mjs ==');

// A fresh temp workspace per run; cleaned at the end.
const WS = mkdtempSync(join(tmpdir(), 'adv-verify-'));
const scratch = (name) => { const d = join(WS, name); mkdirSync(d, { recursive: true }); return d; };
const writeJson = (p, obj) => { mkdirSync(dirname(p), { recursive: true }); writeFileSync(p, JSON.stringify(obj)); };

// ── Fixtures ──────────────────────────────────────────────────────────────────
const CLAIMS = [
  { id: 'L1', claim: 'Water boils at 100C at sea level.' },                        // NO source
  { id: 'W2', claim: 'HTTP/2 uses a binary framing layer.', source: 'rfc7540 4.1' }, // WITH source
];

// ── PROMPT PARITY — frozen goldens captured verbatim from adversarial-verify.js's
// current template (lines ~77-82). If buildSkepticPrompt's wording drifts one byte, these break.
const HEAD = (num) =>
  `You are adversarial fact-checker / skeptic #${num} of 3. Your JOB is to REFUTE the claim below.\n` +
  `Use web search and your own knowledge to find evidence that the claim is FALSE, unsupported, inaccurate, or overstated.\n` +
  `A claim survives ONLY if it is clearly and verifiably true. If you cannot confirm it with confidence, default to refuted=true.\n\n`;
const TAIL = `\nReturn: refuted (true = the claim is false/unsupported), confidence (0..1), reasoning, and evidence (a URL or quote) if you found any.`;
// Golden strings are the EXACT bytes produced by executing the current .js template.
const GOLD_L1_S1 = HEAD(1) + `CLAIM: "Water boils at 100C at sea level."\n` + TAIL;
const GOLD_L1_S3 = HEAD(3) + `CLAIM: "Water boils at 100C at sea level."\n` + TAIL;
const GOLD_W2_S1 = HEAD(1) + `CLAIM: "HTTP/2 uses a binary framing layer."\n` + `CITED SOURCE: rfc7540 4.1\n` + TAIL;
const GOLD_W2_S3 = HEAD(3) + `CLAIM: "HTTP/2 uses a binary framing layer."\n` + `CITED SOURCE: rfc7540 4.1\n` + TAIL;

eq('prompt parity: L1 skeptic#1 (no source) byte-for-byte', buildSkepticPrompt(CLAIMS[0], 1, 3), GOLD_L1_S1);
eq('prompt parity: L1 skeptic#3 (no source) byte-for-byte', buildSkepticPrompt(CLAIMS[0], 3, 3), GOLD_L1_S3);
eq('prompt parity: W2 skeptic#1 (with source) byte-for-byte', buildSkepticPrompt(CLAIMS[1], 1, 3), GOLD_W2_S1);
eq('prompt parity: W2 skeptic#3 (with source) byte-for-byte', buildSkepticPrompt(CLAIMS[1], 3, 3), GOLD_W2_S3);
// Absent source must NOT emit a CITED SOURCE line (no empty/defaulted line).
ok(buildSkepticPrompt(CLAIMS[0], 2, 3).includes('CITED SOURCE') === false ? 'no-source prompt omits CITED SOURCE line' : (fail++, 'no-source prompt LEAKED a CITED SOURCE line'));

// ── plan: golden plan.json (defaults) via the real CLI (argv-exercising) ────────
{
  const dir = scratch('plan-defaults');
  const claimsPath = join(dir, 'claims.json');
  writeFileSync(claimsPath, JSON.stringify(CLAIMS));
  execFileSync('node', [CLI, 'plan', claimsPath, '--out', dir], { encoding: 'utf8' });
  const plan = JSON.parse(readFileSync(join(dir, 'plan.json'), 'utf8'));

  deepEq('plan.params defaults (n/quorum/confThreshold)', plan.params,
    { n: DEFAULT_N, quorum: DEFAULT_QUORUM, confThreshold: DEFAULT_CONF_THRESHOLD });
  deepEq('plan embeds the exact VERDICT_SCHEMA kernel', plan.verdictSchema, VERDICT_SCHEMA);
  eq('plan has one entry per claim', plan.claims.length, 2);
  eq('each claim carries N skeptics', plan.claims[0].skeptics.length, DEFAULT_N);

  // Correct verdictPaths (relative to the plan dir) + rendered prompts.
  const s = plan.claims[0].skeptics;
  deepEq('verdictPaths L1', s.map((x) => x.verdictPath),
    ['verdicts/L1/skeptic1.json', 'verdicts/L1/skeptic2.json', 'verdicts/L1/skeptic3.json']);
  deepEq('skeptic numbers L1', s.map((x) => x.skeptic), [1, 2, 3]);
  eq('rendered prompt L1 skeptic#1 == golden', s[0].prompt, GOLD_L1_S1);

  // WITH source vs WITHOUT source.
  eq('claim WITHOUT source omits the source key', Object.prototype.hasOwnProperty.call(plan.claims[0], 'source'), false);
  eq('claim WITH source keeps it', plan.claims[1].source, 'rfc7540 4.1');
  eq('rendered prompt W2 skeptic#1 embeds CITED SOURCE == golden', plan.claims[1].skeptics[0].prompt, GOLD_W2_S1);
  deepEq('verdictPaths W2', plan.claims[1].skeptics.map((x) => x.verdictPath),
    ['verdicts/W2/skeptic1.json', 'verdicts/W2/skeptic2.json', 'verdicts/W2/skeptic3.json']);
}

// ── plan: custom params ride into the plan (self-describing seal) ───────────────
{
  const dir = scratch('plan-custom');
  const claimsPath = join(dir, 'claims.json');
  writeFileSync(claimsPath, JSON.stringify([{ id: 'C', claim: 'x' }]));
  execFileSync('node', [CLI, 'plan', claimsPath, '--out', dir, '--n', '2', '--quorum', '2', '--conf-threshold', '0.9'], { encoding: 'utf8' });
  const plan = JSON.parse(readFileSync(join(dir, 'plan.json'), 'utf8'));
  deepEq('custom params ride the plan', plan.params, { n: 2, quorum: 2, confThreshold: 0.9 });
  eq('N=2 → 2 skeptics', plan.claims[0].skeptics.length, 2);
  eq('N=2 wording says "of 2"', plan.claims[0].skeptics[0].prompt.includes('#1 of 2'), true);
}

// ── seal: the kernel's own vote matrices, materialized as real verdict files ─────
// Each row = the verdict labels/counts the kernel test asserts; sealing real files must match.
const V = (refuted) => ({ refuted });
const Vc = (refuted, confidence) => ({ refuted, confidence });
// A fully schema-conformant vote (carries `reasoning`, as every live skeptic vote does).
const Vr = (refuted, confidence, reasoning = 'because') => ({ refuted, confidence, reasoning });
const sealMatrix = [
  ['3 survive',            [V(false), V(false), V(false)], 'SURVIVES ([CERT] sealed)'],
  ['3 votes 1 refute',     [V(true), V(false), V(false)],  'SURVIVES ([CERT] sealed)'],
  ['3 votes 2 refute',     [V(true), V(true), V(false)],   'KILLED'],
  ['3 votes 3 refute',     [V(true), V(true), V(true)],    'KILLED'],
  ['2 votes 1 refute',     [V(true), V(false)],            'KILLED'],
  ['low-conf survive',     [Vc(false, 0.5), Vc(false, 0.5), Vc(false, 0.5)], 'INSUFFICIENT (too few skeptics survived, or survived below the confidence bar — NOT sealed)'],
  ['high-conf survive',    [Vc(false, 0.9), Vc(false, 0.8), Vc(false, 0.95)], 'SURVIVES ([CERT] sealed)'],
];
for (const [name, votes, wantLabel] of sealMatrix) {
  const dir = scratch('seal-' + name.replace(/[^a-z0-9]+/gi, '-'));
  // Build a 3-skeptic plan and drop the votes as files (fewer votes than skeptics = dead tail).
  const plan = buildPlan([{ id: 'M', claim: 'c' }], { n: 3 });
  writeJson(join(dir, 'plan.json'), plan);
  votes.forEach((vote, i) => writeJson(join(dir, plan.claims[0].skeptics[i].verdictPath), vote));
  const seal = runSeal(dir);
  const r = seal.results[0];
  eq(`seal[${name}] label`, r.verdict, wantLabel);
  // Kernel agreement: sealing files must equal calling buildClaimResult on the same votes
  //   padded with nulls for the dead skeptics.
  const padded = votes.concat(Array(3 - votes.length).fill(null));
  deepEq(`seal[${name}] == kernel buildClaimResult`, r, buildClaimResult({ id: 'M', claim: 'c' }, padded, { quorum: plan.params.quorum, confThreshold: plan.params.confThreshold }));
}

// ── DEGRADED: missing verdict file = null vote → below quorum → INSUFFICIENT ─────
{
  const dir = scratch('degraded-missing');
  const plan = buildPlan([{ id: 'D', claim: 'lone survivor' }], { n: 3 });
  writeJson(join(dir, 'plan.json'), plan);
  // Only ONE skeptic writes a (surviving) verdict; the other two files are MISSING.
  writeJson(join(dir, plan.claims[0].skeptics[0].verdictPath), Vc(false, 0.99));
  const seal = runSeal(dir);
  eq('degraded/missing: 2 dead skeptics → INSUFFICIENT (never sealed on one vote)',
    seal.results[0].verdict, 'INSUFFICIENT (too few skeptics survived, or survived below the confidence bar — NOT sealed)');
  eq('degraded/missing: only 1 valid vote counted', seal.results[0].total, 1);
}

// ── DEGRADED: malformed JSON verdict file = null vote, no crash, no coercion ─────
{
  const dir = scratch('degraded-malformed');
  const plan = buildPlan([{ id: 'M2', claim: 'garbled' }], { n: 3 });
  writeJson(join(dir, 'plan.json'), plan);
  // Two survivors, one file that is NOT valid JSON.
  writeJson(join(dir, plan.claims[0].skeptics[0].verdictPath), Vc(false, 0.9));
  writeJson(join(dir, plan.claims[0].skeptics[1].verdictPath), Vc(false, 0.9));
  writeFileSync(join(dir, plan.claims[0].skeptics[2].verdictPath), '{ this is not json ');
  let seal;
  try { seal = runSeal(dir); ok('malformed verdict file does not crash seal'); }
  catch (e) { no('malformed verdict file CRASHED seal: ' + e.message); }
  if (seal) {
    eq('malformed→null: 2 valid votes counted (bad file dropped)', seal.results[0].total, 2);
    eq('malformed→null: 2 clean survivors → SURVIVES', seal.results[0].verdict, 'SURVIVES ([CERT] sealed)');
  }
  // A parsed object WITHOUT a boolean `refuted` is malformed too → null, never a defaulted survive.
  eq('object missing boolean refuted → readVote null', readVote(writeTmp(dir, '{"confidence":0.9}')), null);
  eq('non-boolean refuted → readVote null', readVote(writeTmp(dir, '{"refuted":"yes"}')), null);
}
function writeTmp(dir, raw) { const p = join(dir, 'tmp-' + Math.random().toString(36).slice(2) + '.json'); writeFileSync(p, raw); return p; }

// ── seal.json output shape + label strings == today's return object verbatim ────
{
  const dir = scratch('shape');
  const plan = buildPlan([
    { id: 'A', claim: 'survives' },
    { id: 'B', claim: 'killed' },
    { id: 'C', claim: 'thin' },
  ], { n: 3 });
  writeJson(join(dir, 'plan.json'), plan);
  // A survives (3 high-conf), B killed (2 refute), C thin (1 vote → INSUFFICIENT).
  [Vr(false, 0.9), Vr(false, 0.9), Vr(false, 0.9)].forEach((v, i) => writeJson(join(dir, plan.claims[0].skeptics[i].verdictPath), v));
  [Vr(true, 0.9), Vr(true, 0.9), Vr(false, 0.9)].forEach((v, i) => writeJson(join(dir, plan.claims[1].skeptics[i].verdictPath), v));
  writeJson(join(dir, plan.claims[2].skeptics[0].verdictPath), Vr(false, 0.9));
  // Drive the REAL CLI end-to-end and read seal.json off disk.
  execFileSync('node', [CLI, 'seal', dir], { encoding: 'utf8' });
  const seal = JSON.parse(readFileSync(join(dir, 'seal.json'), 'utf8'));

  deepEq('seal.json top-level keys', Object.keys(seal).sort(),
    ['insufficient', 'killed', 'results', 'survived', 'total'].sort());
  eq('survived count', seal.survived, 1);
  eq('killed count', seal.killed, 1);
  eq('insufficient count', seal.insufficient, 1);
  eq('total count', seal.total, 3);
  // Per-result shape verbatim (keys + label wiring the driver reads).
  deepEq('result keys verbatim', Object.keys(seal.results[0]).sort(),
    ['claim', 'confThreshold', 'id', 'meanConfidence', 'refutes', 'total', 'verdict', 'votes'].sort());
  eq('SURVIVES label verbatim', seal.results[0].verdict, 'SURVIVES ([CERT] sealed)');
  eq('KILLED label verbatim', seal.results[1].verdict, 'KILLED');
  eq('INSUFFICIENT label verbatim', seal.results[2].verdict, 'INSUFFICIENT (too few skeptics survived, or survived below the confidence bar — NOT sealed)');
  deepEq('vote shape verbatim {refuted,confidence,reasoning}', Object.keys(seal.results[0].votes[0]).sort(),
    ['confidence', 'reasoning', 'refuted'].sort());
}

// ── ROUND-TRIP: plan → fill verdicts → seal → expected decision ────────────────
{
  const dir = scratch('round-trip');
  const claimsPath = join(dir, 'claims.json');
  writeFileSync(claimsPath, JSON.stringify([{ id: 'RT', claim: 'the earth orbits the sun', source: 'astro:1' }]));
  execFileSync('node', [CLI, 'plan', claimsPath, '--out', dir], { encoding: 'utf8' });
  const plan = JSON.parse(readFileSync(join(dir, 'plan.json'), 'utf8'));
  // Host "fills" each skeptic's verdict at the exact path the plan dictated.
  plan.claims[0].skeptics.forEach((s) => writeJson(join(dir, s.verdictPath), Vc(false, 0.92)));
  execFileSync('node', [CLI, 'seal', dir], { encoding: 'utf8' });
  const seal = JSON.parse(readFileSync(join(dir, 'seal.json'), 'utf8'));
  eq('round-trip decision', seal.results[0].verdict, 'SURVIVES ([CERT] sealed)');
  eq('round-trip survived count', seal.survived, 1);
}

// ── DETERMINISM: same verdict files → identical seal, twice ─────────────────────
{
  const dir = scratch('determinism');
  const plan = buildPlan([{ id: 'Z', claim: 'z' }], { n: 3 });
  writeJson(join(dir, 'plan.json'), plan);
  plan.claims[0].skeptics.forEach((s, i) => writeJson(join(dir, s.verdictPath), Vc(i === 0, 0.8)));
  deepEq('seal is deterministic over fixed files', runSeal(dir), runSeal(dir));
}

// ── TEETH — neutering the missing/malformed→null mapping flips a degraded case ──
// Mutant reader: a missing/malformed file is COERCED into a defaulted survive vote
// (the exact false-seal bug the re-host must not reintroduce). It must flip the degraded
// case from INSUFFICIENT (honest) to a FALSE "SURVIVES".
{
  const dir = scratch('teeth');
  const plan = buildPlan([{ id: 'T', claim: 'thin evidence' }], { n: 3 });
  writeJson(join(dir, 'plan.json'), plan);
  writeJson(join(dir, plan.claims[0].skeptics[0].verdictPath), Vc(false, 0.99)); // 1 real survive; 2 files MISSING
  const honest = runSeal(dir).results[0].verdict;
  // Buggy reader: dead skeptic → { refuted: false } (defaulted survive) instead of null.
  const buggyRead = (p) => { const v = readVote(p); return v === null ? { refuted: false, confidence: 0.99 } : v; };
  const buggy = runSeal(dir, { readVoteFn: buggyRead }).results[0].verdict;
  const flips = honest.startsWith('INSUFFICIENT') && buggy.startsWith('SURVIVES');
  if (flips) ok(`teeth: null-mapping is load-bearing — honest=${JSON.stringify(honest.slice(0, 12))}… flips to false SURVIVES when neutered`);
  else no(`teeth: mutant did NOT flip the decision (honest=${honest}, buggy=${buggy}) — the degraded test is THEATER`);
}

// ── CLI VALIDATION (audit fix) — a bad --quorum / --n / --conf-threshold must FAIL LOUDLY
//    (nonzero exit), never ride a floor-disabling value silently into plan.json. ────────
function runCli(args) {
  try {
    const stdout = execFileSync('node', [CLI, ...args], { encoding: 'utf8' });
    return { code: 0, stdout, stderr: '' };
  } catch (e) {
    return { code: typeof e.status === 'number' ? e.status : 1, stdout: e.stdout || '', stderr: e.stderr || '' };
  }
}
{
  const dir = scratch('cli-validation');
  const claimsPath = join(dir, 'claims.json');
  writeFileSync(claimsPath, JSON.stringify([{ id: 'C', claim: 'x' }]));
  const badFlags = [
    ['--quorum', '0'], ['--quorum', '-1'], ['--quorum', 'abc'], ['--quorum', '1.5'],
    ['--n', '0'], ['--n', '-2'], ['--n', 'abc'],
    ['--conf-threshold', 'abc'], ['--conf-threshold', '2'], ['--conf-threshold', '-0.1'],
  ];
  for (const [flag, val] of badFlags) {
    const r = runCli(['plan', claimsPath, '--out', dir, flag, val]);
    eq(`plan ${flag} ${val} → nonzero exit (rejected loudly)`, r.code !== 0, true);
  }
  // A valid param set still succeeds (exit 0) and rides into plan.json.
  const okr = runCli(['plan', claimsPath, '--out', dir, '--quorum', '2', '--n', '3', '--conf-threshold', '0.7']);
  eq('plan with valid params → exit 0 (not over-rejecting)', okr.code, 0);
  // Boundary confidence thresholds 0 and 1 are inclusive-valid.
  eq('plan --conf-threshold 0 → exit 0 (inclusive lower bound)',
     runCli(['plan', claimsPath, '--out', dir, '--conf-threshold', '0']).code, 0);
  eq('plan --conf-threshold 1 → exit 0 (inclusive upper bound)',
     runCli(['plan', claimsPath, '--out', dir, '--conf-threshold', '1']).code, 0);
  // quorum=1 is a legit low quorum (integer >= 1).
  eq('plan --quorum 1 → exit 0 (legit low quorum)',
     runCli(['plan', claimsPath, '--out', dir, '--quorum', '1']).code, 0);
}

// ── DEFENSE-IN-DEPTH: a hand-written/legacy plan.json with a floor-disabling quorum:0
//    (the value the CLI now rejects) cannot seal a degraded 1-live-2-dead panel — the
//    KERNEL floor still fires. ─────────────────────────────────────────────────────────
{
  const dir = scratch('legacy-bad-quorum');
  const plan = buildPlan([{ id: 'LQ', claim: 'lone survivor' }], { n: 3 });
  plan.params.quorum = 0;                                       // simulate a legacy/tampered plan
  writeJson(join(dir, 'plan.json'), plan);
  writeJson(join(dir, plan.claims[0].skeptics[0].verdictPath), Vc(false, 0.99)); // 1 live, 2 dead
  const seal = runSeal(dir);
  eq('legacy quorum:0 + 1-live panel → INSUFFICIENT (kernel floor holds despite bad plan)',
     seal.results[0].verdict, 'INSUFFICIENT (too few skeptics survived, or survived below the confidence bar — NOT sealed)');
}

// ── readVote CONFIDENCE BOUND (audit fix) — a present-but-out-of-[0,1] / non-finite
//    confidence is MALFORMED → null (dead skeptic), never a live inflating vote. A MISSING
//    confidence stays allowed (legacy ungraded survivor, unchanged). ─────────────────────
eq('readVote: {refuted:false, confidence:95} → null (scale slip = malformed)',
   readVote(writeTmp(WS, '{"refuted":false,"confidence":95}')), null);
eq('readVote: {refuted:false, confidence:-0.5} → null (below range)',
   readVote(writeTmp(WS, '{"refuted":false,"confidence":-0.5}')), null);
eq('readVote: {refuted:false, confidence:"high"} → null (non-numeric)',
   readVote(writeTmp(WS, '{"refuted":false,"confidence":"high"}')), null);
deepEq('readVote: {refuted:false, confidence:1} → live (boundary in-range preserved)',
   readVote(writeTmp(WS, '{"refuted":false,"confidence":1}')), { refuted: false, confidence: 1 });
deepEq('readVote: {refuted:false, confidence:0} → live (boundary 0 in-range preserved)',
   readVote(writeTmp(WS, '{"refuted":false,"confidence":0}')), { refuted: false, confidence: 0 });
deepEq('readVote: {refuted:false} (no confidence) → live (legacy ungraded shape unchanged)',
   readVote(writeTmp(WS, '{"refuted":false}')), { refuted: false });

// TEETH — neutering readVote's confidence bound lets a conf=95 scale slip ride as a LIVE vote.
{
  const p = writeTmp(WS, '{"refuted":false,"confidence":95}');
  const honest = readVote(p);                                   // null (fixed: out-of-range dropped)
  const buggyRead = (path) => {                                 // pre-fix readVote: bounds `refuted` only
    let raw; try { raw = readFileSync(path, 'utf8'); } catch { return null; }
    let v;   try { v = JSON.parse(raw); }             catch { return null; }
    if (!v || typeof v !== 'object' || Array.isArray(v) || typeof v.refuted !== 'boolean') return null;
    return v;                                                   // no confidence bound → 95 rides live
  };
  const buggy = buggyRead(p);
  if (honest === null && buggy && buggy.confidence === 95)
    ok('teeth: readVote confidence-bound is load-bearing — a conf=95 scale slip rides as a live inflating vote when neutered');
  else no(`teeth: readVote confidence-bound mutant did NOT differ (honest=${JSON.stringify(honest)}, buggy=${JSON.stringify(buggy)}) — THEATER`);
}

// cleanup
try { rmSync(WS, { recursive: true, force: true }); } catch { /* best-effort */ }

console.log(`== ${pass} passed · ${fail} failed ==`);
process.exit(fail ? 1 : 0);
