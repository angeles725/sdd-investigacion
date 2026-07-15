#!/usr/bin/env node
// adversarial-verify.mjs — harness-agnostic [CERT] sealer (plan/seal CLI).
//
// WHAT IT DOES: re-hosts the research-sdd [CERT] sealer as TWO pure subcommands so ANY
// harness (Claude Workflow, a shell driver, an MCP host, …) can seal claims without this
// tool spawning skeptics itself:
//
//   plan <claims.json> --out <dir> [--n 3] [--quorum 2] [--conf-threshold 0.7]
//       Reads claims [{ id, claim, source? }] and writes <dir>/plan.json: for every claim,
//       N fully-rendered skeptic prompts + the exact relative `verdictPath` each skeptic
//       must write, plus the embedded VERDICT_SCHEMA and the seal params — so `seal` is
//       fully self-describing. The HOST runs the skeptics and drops each verdict at its path.
//
//   seal <dir> [--out seal.json]
//       Reads every verdictPath from <dir>/plan.json. A MISSING or MALFORMED verdict file
//       (or one lacking a boolean `refuted`) is a null vote — a DEAD skeptic — never a
//       defaulted survive. Routes votes through the ONE sealVerdict kernel and writes
//       <dir>/seal.json with the same shape + label strings as the Workflow leg returns.
//
// Both subcommands are PURE: no LLM, no agent spawning, no web. Given fixed verdict files,
// `seal` is deterministic. The sealing math + prompt wording live in adversarial-verdict.mjs
// (the single kernel); this file only does I/O and argv.

import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  VERDICT_SCHEMA,
  buildSkepticPrompt,
  buildClaimResult,
  summarize,
  DEFAULT_N,
  DEFAULT_QUORUM,
  DEFAULT_CONF_THRESHOLD,
} from './adversarial-verdict.mjs';

// ── plan ────────────────────────────────────────────────────────────────────
// Pure: (claims, params) → plan object. verdictPaths are RELATIVE to the plan dir so the
// plan is portable across harnesses; `seal` resolves them against the same dir.
export function buildPlan(claims, { n = DEFAULT_N, quorum = DEFAULT_QUORUM, confThreshold = DEFAULT_CONF_THRESHOLD } = {}) {
  const list = Array.isArray(claims) ? claims : [];
  return {
    version: 1,
    params: { n, quorum, confThreshold },
    verdictSchema: VERDICT_SCHEMA,
    claims: list.map((c, i) => {
      const id = c.id || 'c' + i;
      const skeptics = Array.from({ length: n }, (_unused, j) => {
        const num = j + 1;
        return {
          skeptic: num,
          verdictPath: `verdicts/${id}/skeptic${num}.json`,
          prompt: buildSkepticPrompt(c, num, n),
        };
      });
      // Only carry `source` when the claim actually had one (no defaulted/empty key).
      return c.source !== undefined
        ? { id, claim: c.claim, source: c.source, skeptics }
        : { id, claim: c.claim, skeptics };
    }),
  };
}

// ── seal ──────────────────────────────────────────────────────────────────────
// readVote — load ONE verdict file. Missing file, malformed JSON, non-object, or an object
// without a boolean `refuted` ALL map to null (a dead skeptic). Never coerce to a survive.
export function readVote(path) {
  let raw;
  try {
    raw = readFileSync(path, 'utf8');
  } catch {
    return null; // missing / unreadable = dead skeptic
  }
  let v;
  try {
    v = JSON.parse(raw);
  } catch {
    return null; // malformed JSON = dead skeptic (no coercion)
  }
  if (!v || typeof v !== 'object' || Array.isArray(v) || typeof v.refuted !== 'boolean') {
    return null; // shape-invalid (no boolean refuted) = dead skeptic
  }
  // A `confidence` that is PRESENT but not a finite number in [0,1] is a MALFORMED verdict (e.g.
  // a 0-1 vs 0-100 scale slip like 95). Map it to a dead skeptic (null) rather than admit a live,
  // mean-inflating vote — consistent with this file's "never coerce a bad value into a survive"
  // threat model. A MISSING confidence stays allowed (legacy ungraded survivor, unchanged).
  if (v.confidence !== undefined
      && !(typeof v.confidence === 'number' && Number.isFinite(v.confidence) && v.confidence >= 0 && v.confidence <= 1)) {
    return null; // present-but-out-of-[0,1]/non-finite confidence = malformed = dead skeptic
  }
  return v;
}

// runSeal — pure over the on-disk plan + verdict files. `planObj` lets callers pass an
// in-memory plan; `readVoteFn` lets tests inject a reader (teeth). Returns summarize(results).
export function runSeal(dir, { planObj, readVoteFn = readVote } = {}) {
  const plan = planObj || JSON.parse(readFileSync(join(dir, 'plan.json'), 'utf8'));
  const { quorum, confThreshold } = plan.params || {};
  const results = (plan.claims || []).map((c) => {
    const votes = (c.skeptics || []).map((s) => readVoteFn(join(dir, s.verdictPath)));
    return buildClaimResult({ id: c.id, claim: c.claim }, votes, { quorum, confThreshold });
  });
  return summarize(results);
}

// ── CLI plumbing ────────────────────────────────────────────────────────────
function parseFlags(argv) {
  const positional = [];
  const flags = {};
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a.startsWith('--')) {
      const key = a.slice(2);
      const next = argv[i + 1];
      if (next === undefined || next.startsWith('--')) {
        flags[key] = true;
      } else {
        flags[key] = next;
        i++;
      }
    } else {
      positional.push(a);
    }
  }
  return { positional, flags };
}

function die(msg) {
  process.stderr.write(msg + '\n');
  process.exit(2);
}

// Validate an integer CLI flag (>= 1). FAIL LOUDLY (nonzero exit) rather than let a bad value
// (0, negative, NaN typo, non-integer, or a bare flag with no value) ride into plan.json where
// `--quorum 0`/`--n 0` would disable the seal floor. `raw === true` = the flag was passed with
// no value (parseFlags convention) — also rejected.
function requirePositiveInt(name, raw) {
  if (raw === true || raw === undefined) die(`plan: ${name} requires an integer >= 1 (no value given)`);
  const n = Number(raw);
  if (!Number.isInteger(n) || n < 1) die(`plan: ${name} must be an integer >= 1 (got ${JSON.stringify(raw)})`);
  return n;
}

// Validate the confidence-threshold flag: a FINITE number in [0,1] inclusive. A NaN typo or an
// out-of-range value (e.g. a 0-100 scale slip) is rejected so it can never ride into plan.json.
function requireUnitInterval(name, raw) {
  if (raw === true || raw === undefined) die(`plan: ${name} requires a number in [0,1] (no value given)`);
  const x = Number(raw);
  if (!Number.isFinite(x) || x < 0 || x > 1) die(`plan: ${name} must be a number in [0,1] (got ${JSON.stringify(raw)})`);
  return x;
}

function cmdPlan(positional, flags) {
  const claimsPath = positional[0];
  if (!claimsPath) die('plan: missing <claims.json>\nusage: adversarial-verify.mjs plan <claims.json> --out <dir> [--n 3] [--quorum 2] [--conf-threshold 0.7]');
  const outDir = flags.out;
  if (!outDir || outDir === true) die('plan: missing --out <dir>');

  let claims;
  try {
    claims = JSON.parse(readFileSync(claimsPath, 'utf8'));
  } catch (e) {
    die(`plan: cannot read/parse ${claimsPath}: ${e.message}`);
  }
  if (!Array.isArray(claims)) die('plan: claims file must be a JSON array of { id, claim, source? }');

  const opts = {};
  if (flags.n !== undefined) opts.n = requirePositiveInt('--n', flags.n);
  if (flags.quorum !== undefined) opts.quorum = requirePositiveInt('--quorum', flags.quorum);
  if (flags['conf-threshold'] !== undefined) opts.confThreshold = requireUnitInterval('--conf-threshold', flags['conf-threshold']);

  const plan = buildPlan(claims, opts);
  mkdirSync(outDir, { recursive: true });
  const outPath = join(outDir, 'plan.json');
  writeFileSync(outPath, JSON.stringify(plan, null, 2) + '\n');
  process.stdout.write(`plan: ${plan.claims.length} claim(s) × ${plan.params.n} skeptics → ${outPath}\n`);
}

function cmdSeal(positional, flags) {
  const dir = positional[0];
  if (!dir) die('seal: missing <dir>\nusage: adversarial-verify.mjs seal <dir> [--out seal.json]');
  let seal;
  try {
    seal = runSeal(dir);
  } catch (e) {
    die(`seal: cannot read plan/verdicts under ${dir}: ${e.message}`);
  }
  const outName = flags.out && flags.out !== true ? flags.out : 'seal.json';
  const outPath = join(dir, outName);
  writeFileSync(outPath, JSON.stringify(seal, null, 2) + '\n');
  process.stdout.write(`seal: ${seal.survived} sealed, ${seal.killed} killed, ${seal.insufficient} insufficient of ${seal.total} → ${outPath}\n`);
}

function main(argv) {
  const [sub, ...rest] = argv;
  const { positional, flags } = parseFlags(rest);
  if (sub === 'plan') return cmdPlan(positional, flags);
  if (sub === 'seal') return cmdSeal(positional, flags);
  die('usage: adversarial-verify.mjs <plan|seal> …');
}

// Run only when invoked directly (not when imported by tests).
if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  main(process.argv.slice(2));
}
