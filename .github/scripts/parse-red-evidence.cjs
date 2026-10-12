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
      if (reason.length < MIN_TEXT || PLACEHOLDER.test(reason)) {
        errors.push({ raw, reason: `"RED: n/a" needs a real reason (at least ${MIN_TEXT} characters, no placeholder)` });
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

// Production behavior = a kit toolbelt (or install/templates) script outside tests/. Docs and test files are not.
function isProductionPath(path) {
  if (typeof path !== 'string') return false;
  if (/^research-sdd\/toolbelt\/tests\//.test(path)) return false;
  if (/^research-sdd\/install\/tests\//.test(path)) return false;
  if (/^research-sdd\/(?:toolbelt|install|templates)\//.test(path)) {
    return /\.(?:sh|py|mjs|js|cjs|ts)$/.test(path);
  }
  return false;
}

// files: array of paths (a rename contributes both its new and previous path).
function checkRedEvidence(body, files) {
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
  }
  return { required: true, ok: problems.length === 0, production, ...parsed, problems };
}

module.exports = { parseRedEvidence, checkRedEvidence, isProductionPath };
