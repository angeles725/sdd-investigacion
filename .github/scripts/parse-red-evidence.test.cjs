'use strict';

// Tests for parse-red-evidence.cjs (kit issue #2208). Run by pr-check.yml: node --test .github/scripts/*.test.cjs

const { readFileSync } = require('node:fs');
const { resolve } = require('node:path');
const { test } = require('node:test');
const assert = require('node:assert/strict');

const { parseRedEvidence, checkRedEvidence, isProductionPath } = require('./parse-red-evidence.cjs');

const GOOD = 'RED: foo.test.sh case one — expected 3 got 0';
const PROD = ['research-sdd/toolbelt/foo.sh'];

test('a well-formed evidence line parses into suite, name and excerpt', () => {
  const r = parseRedEvidence(GOOD);
  assert.deepEqual(r.errors, []);
  assert.deepEqual(r.evidence, [{ suite: 'foo.test.sh', name: 'case one', excerpt: 'expected 3 got 0' }]);
});

test('suite may be a path, any supported runner; en dash and double hyphen separate too', () => {
  for (const line of [
    'RED: research-sdd/toolbelt/tests/foo.test.sh c — failed: boom',
    'RED: .github/scripts/x.test.cjs name – AssertionError one',
    'RED: tests/y.test.mjs name -- AssertionError one',
    'RED: z.test.py test_name — assert 1 == 2',
  ]) {
    const r = parseRedEvidence(line);
    assert.deepEqual(r.errors, [], line);
    assert.equal(r.evidence.length, 1, line);
  }
});

test('list edges: first, middle, last and single evidence lines; bullets are accepted', () => {
  assert.equal(parseRedEvidence(`${GOOD}\nprose\nprose`).evidence.length, 1);
  assert.equal(parseRedEvidence(`prose\n- ${GOOD}\nprose`).evidence.length, 1);
  assert.equal(parseRedEvidence(`prose\nprose\n${GOOD}`).evidence.length, 1);
  assert.equal(parseRedEvidence(`${GOOD}\nRED: bar.test.sh other — boom boom\n${GOOD}`).evidence.length, 3);
  assert.equal(parseRedEvidence(GOOD + '\n').evidence.length, 1);
});

test('evidence inside HTML comments or code fences is ignored (the template example must not count)', () => {
  assert.equal(parseRedEvidence(`<!--\n${GOOD}\n-->`).evidence.length, 0);
  assert.equal(parseRedEvidence('```\n' + GOOD + '\n```').evidence.length, 0);
  assert.equal(parseRedEvidence(`<!-- ${GOOD} -->\n${GOOD}`).evidence.length, 1);
});

test('malformed lines fail closed with a reason', () => {
  const cases = [
    ['RED: foo.test.sh case one expected 3 got 0', 'separator'],
    ['RED: foo.test.sh case - expected 3 got 0', 'separator'],
    ['RED: foo.sh case — expected 3 got 0', 'not a test file name'],
    ['RED: foo.test.sh — expected 3 got 0', 'missing the case or test name'],
    ['RED: foo.test.sh case — short', 'at least'],
    ['RED: <suite> <case-or-test-name> — <failing output excerpt>', 'placeholder'],
    ['RED: foo.test.sh <case-or-test-name> — real output here', 'placeholder'],
    ['RED: foo.test.sh case — TBD', 'placeholder'],
    ['RED:', 'separator'],
  ];
  for (const [line, fragment] of cases) {
    const r = parseRedEvidence(line);
    assert.equal(r.evidence.length, 0, line);
    assert.equal(r.errors.length, 1, line);
    assert.match(r.errors[0].reason, new RegExp(fragment), line);
  }
});

test('"RED: n/a" needs a real reason', () => {
  assert.deepEqual(parseRedEvidence('RED: n/a — the change is a pure refactor; the existing suite covers it').notApplicable.length, 1);
  assert.equal(parseRedEvidence('RED: n/a').errors.length, 1);
  assert.equal(parseRedEvidence('RED: n/a — <reason>').errors.length, 1);
  assert.equal(parseRedEvidence('RED: n/a — tbd').errors.length, 1);
  assert.equal(parseRedEvidence('RED: n/a — short').errors.length, 1);
  assert.equal(parseRedEvidence('RED: N/A -- documented exception here').notApplicable.length, 1);
});

test('evidence and n/a together are ambiguous', () => {
  const r = parseRedEvidence(`${GOOD}\nRED: n/a — pure refactor, nothing to run`);
  assert.equal(r.errors.length, 1);
  assert.match(r.errors[0].reason, /ambiguous/);
});

test('the keyword is case-sensitive and must start the line (prose mentioning RED does not count)', () => {
  assert.equal(parseRedEvidence('Observed RED: foo.test.sh c — failed here').evidence.length, 0);
  assert.equal(parseRedEvidence('red: foo.test.sh c — failed here').evidence.length, 0);
});

test('non-string bodies are an empty parse, not a throw', () => {
  for (const body of [undefined, null, 42, {}]) {
    assert.deepEqual(parseRedEvidence(body), { evidence: [], notApplicable: [], errors: [] });
  }
});

test('isProductionPath: toolbelt scripts yes; tests, fixtures, docs, workflows no', () => {
  const yes = [
    'research-sdd/toolbelt/foo.sh',
    'research-sdd/toolbelt/lib/x.sh',
    'research-sdd/toolbelt/maint/kit-writer-check.sh',
    'research-sdd/toolbelt/adv.mjs',
    'research-sdd/toolbelt/gate.py',
    'research-sdd/install/adapters.sh',
    'research-sdd/templates/hook-kit-run.sh',
  ];
  const no = [
    'research-sdd/toolbelt/tests/foo.test.sh',
    'research-sdd/toolbelt/tests/fixtures/x.sh',
    'research-sdd/install/tests/x.test.sh',
    'research-sdd/toolbelt/tool-registry.md',
    'research-sdd/METHODOLOGY.md',
    '.github/workflows/pr-check.yml',
    'CLAUDE.md',
    undefined,
  ];
  for (const p of yes) assert.equal(isProductionPath(p), true, p);
  for (const p of no) assert.equal(isProductionPath(p), false, String(p));
});

test('checkRedEvidence: required only when a production file changed', () => {
  assert.deepEqual(
    { required: false, ok: true },
    (({ required, ok }) => ({ required, ok }))(checkRedEvidence('', ['CLAUDE.md', 'research-sdd/toolbelt/tests/a.test.sh'])),
  );
  const missing = checkRedEvidence('Closes #1', PROD);
  assert.equal(missing.required, true);
  assert.equal(missing.ok, false);
  assert.match(missing.problems[0], /no "RED:" line/);
  assert.equal(checkRedEvidence(GOOD, PROD).ok, true);
  assert.equal(checkRedEvidence('RED: n/a — documented exception, see above', PROD).ok, true);
});

test('checkRedEvidence: one production file among docs is enough to require it (first, middle, last)', () => {
  for (const files of [
    [...PROD, 'CLAUDE.md', 'a.md'],
    ['CLAUDE.md', ...PROD, 'a.md'],
    ['CLAUDE.md', 'a.md', ...PROD],
  ]) {
    assert.equal(checkRedEvidence('', files).required, true, files.join(','));
  }
});

test('checkRedEvidence: a malformed RED line fails a PR that needs one', () => {
  const r = checkRedEvidence('RED: foo.test.sh case — short', PROD);
  assert.equal(r.ok, false);
  assert.match(r.problems[0], /at least/);
});

test('checkRedEvidence: no files / non-array files is "not required", never a throw', () => {
  assert.equal(checkRedEvidence('', []).required, false);
  assert.equal(checkRedEvidence('', undefined).required, false);
});

test('the workflow wires the gate through the module (no raw-body regex of its own)', () => {
  const workflow = readFileSync(resolve(__dirname, '../workflows/pr-check.yml'), 'utf8');
  assert.match(workflow, /parse-red-evidence\.cjs/);
  assert.match(workflow, /checkRedEvidence\(/);
  assert.match(workflow, /listFiles/);
  assert.match(workflow, /name: Check RED Evidence/);
});
