'use strict';

// Single parse seam for the pr-check.yml "RED evidence" gate (kit issue #2208).
//
// A PR that changes production behavior must show that its tests were run RED against the pre-fix code, in
// reviewer-visible PR body text (HTML comments and fenced code are ignored, exactly as for issue references):
//
//   RED: <suite> <case-or-test-name> — <failing output excerpt>
//   RED: n/a — <reason RED cannot be executed>
//
// <suite> is a test file name (`foo.test.sh`, `foo.test.mjs`, `foo.test.cjs`, `foo.test.py`; a path is fine).
// The separator before the excerpt is an em dash, an en dash or a double hyphen surrounded by spaces (a single
// hyphen is not accepted: test names contain them). Placeholders (`<...>`, TBD, TODO) fail closed.
// Mirrors parse-linked-issues.cjs: returns plain data and errors, never throws on bad input.

const { stripHiddenText } = require('./parse-linked-issues.cjs');

const SUITE_PATTERN = /^[^\s]*\.test\.(?:sh|mjs|cjs|py)$/;
const SEPARATOR = /\s(?:—|–|--)\s/;
// A whole field that is a `<...>` template token or a stand-in word; a `<` inside real output is fine.
const PLACEHOLDER = /^\s*(?:<[^>]*>|tbd|todo|n\/a|none|-)\s*$/i;
const MIN_TEXT = 8;
const MIN_NA_REASON = 20;
// Generic stand-ins that say nothing about why RED cannot run (compared after trimming and dropping trailing punctuation).
const GENERIC_NA = new Set([
  'not applicable',
  'not applicable to this change',
  'no tests needed',
  'no test needed',
  'no tests needed for this change',
  'not needed',
  'nothing to test',
  'nothing to test here',
  'see above',
  'see description',
  'see description above',
  'see the description',
  'see the diff',
  'see commits',
  'trivial',
  'trivial change',
  'trivial change, nothing to do',
  'minor change',
  'small change',
  'no red needed',
  'red not needed',
]);

// Lines starting with `RED:` (optionally a list bullet), case-sensitive on the keyword.
const RED_LINE = /^\s*(?:[-*]\s+)?RED:(.*)$/;

function parseRedEvidence(body) {
  const evidence = [];
  const notApplicable = [];
  const errors = [];
  const visible = stripHiddenText(typeof body === 'string' ? body : '');

  for (const line of visible.split('\n')) {
    const m = RED_LINE.exec(line);
    if (!m) continue;
    const raw = line.trim();
    const rest = m[1].trim();
    const parts = rest.split(SEPARATOR);

    if (/^n\/a(?:\s|$)/i.test(rest)) {
      const reason = rest.replace(/^n\/a\s*(?:—|–|--)?\s*/i, '').trim();
      const normalized = reason.toLowerCase().replace(/[\s.!;:]+$/, '');
      if (reason.length < MIN_NA_REASON || PLACEHOLDER.test(reason)) {
        errors.push({ raw, reason: `"RED: n/a" needs a real reason (at least ${MIN_NA_REASON} characters, no placeholder)` });
      } else if (GENERIC_NA.has(normalized)) {
        errors.push({ raw, reason: '"RED: n/a" reason is generic: say specifically why RED cannot be executed here' });
      } else {
        notApplicable.push({ reason });
      }
      continue;
    }

    if (parts.length < 2) {
      errors.push({ raw, reason: 'missing the " — " separator before the failing output excerpt' });
      continue;
    }
    const head = parts[0].trim();
    const excerpt = parts.slice(1).join(' — ').trim();
    const firstSpace = head.search(/\s/);
    const suite = firstSpace === -1 ? head : head.slice(0, firstSpace);
    const name = firstSpace === -1 ? '' : head.slice(firstSpace).trim();

    if (PLACEHOLDER.test(suite) || PLACEHOLDER.test(name) || PLACEHOLDER.test(excerpt)) {
      errors.push({ raw, reason: 'still contains a template placeholder' });
    } else if (/[<>]/.test(suite)) {
      errors.push({ raw, reason: `"${suite}" contains angle brackets (a template placeholder?)` });
    } else if (!SUITE_PATTERN.test(suite)) {
      errors.push({ raw, reason: `"${suite}" is not a test file name (expected *.test.sh, *.test.mjs, *.test.cjs or *.test.py)` });
    } else if (name.length === 0) {
      errors.push({ raw, reason: 'missing the case or test name after the suite' });
    } else if (excerpt.length < MIN_TEXT) {
      errors.push({ raw, reason: `the failing output excerpt must be at least ${MIN_TEXT} characters` });
    } else {
      evidence.push({ suite, name, excerpt });
    }
  }

  if (evidence.length > 0 && notApplicable.length > 0) {
    errors.push({ raw: 'RED: n/a', reason: 'ambiguous: the body has both RED evidence and a "RED: n/a" line' });
  }
  return { evidence, notApplicable, errors };
}

// Production behavior = a script (.sh .py .mjs .js .cjs .ts) under research-sdd/toolbelt, install or templates, EXCEPT
// suites (tests/*.test.*), tests/fixtures/**, other tests/ sub-directories and install/tests/**; the test
// infrastructure (tests/run-all.sh, suite-impact.sh, shard-join.sh, tests/lib/**) counts. This is the same rule as
// is_production in research-sdd/toolbelt/maint/kit-writer-check.sh; the shared list
// research-sdd/toolbelt/tests/fixtures/kit-writer-check/production-paths.txt pins both implementations.
const SCRIPT_EXT = /\.(?:sh|py|mjs|js|cjs|ts)$/;
function isProductionPath(path) {
  if (typeof path !== 'string') return false;
  if (/^research-sdd\/toolbelt\/tests\/fixtures\//.test(path)) return false;
  if (/^research-sdd\/toolbelt\/tests\/lib\//.test(path)) return SCRIPT_EXT.test(path);
  if (/^research-sdd\/toolbelt\/tests\/[^/]*\.test\./.test(path)) return false;
  if (/^research-sdd\/toolbelt\/tests\/.+\//.test(path)) return false;
  if (/^research-sdd\/install\/tests\//.test(path)) return false;
  if (/^research-sdd\/(?:toolbelt|install|templates)\//.test(path)) return SCRIPT_EXT.test(path);
  return false;
}

// A cited suite exists when some known path is that path or ends with "/<suite>" (a bare file name is fine).
function suiteExists(suite, knownPaths) {
  return knownPaths.some((k) => k === suite || k.endsWith(`/${suite}`));
}

// files: array of paths (a rename contributes both its new and previous path).
// knownPaths: optional array of every repo path plus the PR's files; when given, each cited suite must exist in it.
function checkRedEvidence(body, files, knownPaths) {
  const list = Array.isArray(files) ? files : [];
  const production = list.filter(isProductionPath);
  const parsed = parseRedEvidence(body);
  if (production.length === 0) {
    return { required: false, ok: true, production, ...parsed, problems: [] };
  }
  const problems = [];
  if (parsed.errors.length > 0) {
    for (const e of parsed.errors) problems.push(`${e.raw}: ${e.reason}`);
  } else if (parsed.evidence.length === 0 && parsed.notApplicable.length === 0) {
    problems.push('no "RED:" line in the PR body');
  } else if (Array.isArray(knownPaths)) {
    for (const e of parsed.evidence) {
      if (!suiteExists(e.suite, knownPaths)) problems.push(`RED: ${e.suite}: suite not found in the repository or the PR files`);
    }
  }
  return { required: true, ok: problems.length === 0, production, ...parsed, problems };
}

module.exports = { parseRedEvidence, checkRedEvidence, isProductionPath };
