'use strict';

// Adapted from Gentleman-Programming/gentle-ai (MIT License, Copyright (c) 2025 Gentleman Programming),
// .github/scripts/parse-linked-issues.test.cjs.

const { readFileSync } = require('node:fs');
const { resolve } = require('node:path');
const { test } = require('node:test');
const assert = require('node:assert/strict');

const { parseLinkedIssues } = require('./parse-linked-issues.cjs');

const closing = (number) => ({ number, kind: 'closing' });
const nonClosing = (number) => ({ number, kind: 'non-closing' });
const ok = (...references) => ({ references, errors: [] });

test('references inside HTML comments are ignored; an unclosed comment hides the rest', () => {
  const cases = [
    ['## Summary\n\n<!--\nCloses #42\n-->\n\nSome visible text.', []],
    ['Closes #1770\n\n<!--\nExample: Closes #42\n-->', [closing(1770)]],
    ['Fixes #7\n<!-- Closes #42 --> trailing visible text', [closing(7)]],
    ['Closes #10\n<!-- Refs #42 -->', [closing(10)]],
    ['Closes #1770\n<!-- forgot to close this comment\nCloses #42', [closing(1770)]],
  ];
  for (const [body, references] of cases) {
    assert.deepEqual(parseLinkedIssues(body), ok(...references));
  }
});

test('the workflow parses the event body through the module and never re-scans the raw body', () => {
  const workflow = readFileSync(resolve(__dirname, '../workflows/pr-check.yml'), 'utf8');

  assert.match(workflow, /parseLinkedIssues\(context\.payload\.pull_request\.body \|\| ''\)/);
  assert.match(workflow, /parse-linked-issues\.cjs/);
  assert.doesNotMatch(workflow, /matchAll/, 'a raw-body regex scan would bypass the comment-blind seam');
  assert.doesNotMatch(workflow, /\(\?:closes\|fixes\|resolves\)/i);
});

test('the legacy raw-body regex accepted a commented-out reference (the latent silent pass)', () => {
  const legacy = (body) => [...body.matchAll(/(?:closes|fixes|resolves)\s+#(\d+)/gi)].length;
  assert.equal(legacy('<!-- Closes #5 -->'), 1);
  assert.deepEqual(parseLinkedIssues('<!-- Closes #5 -->'), ok());
});

test('list edges: first, middle, last and single reference positions', () => {
  assert.deepEqual(parseLinkedIssues('Closes #1\nsome prose\nsome more'), ok(closing(1)));
  assert.deepEqual(parseLinkedIssues('prose\nCloses #2\nprose'), ok(closing(2)));
  assert.deepEqual(parseLinkedIssues('prose\nprose\nCloses #3'), ok(closing(3)));
  assert.deepEqual(parseLinkedIssues('Closes #1\nRefs #2\nFixes #3'), ok(closing(1), nonClosing(2), closing(3)));
  assert.deepEqual(parseLinkedIssues('Refs #9'), ok(nonClosing(9)));
});

test('CRLF bodies (GitHub web form): a fence closes and later references still count', () => {
  const body = 'Intro\r\n```\r\nCloses #9\r\n```\r\nCloses #42\r\n';
  const result = parseLinkedIssues(body);
  assert.deepEqual(result.errors, []);
  assert.deepEqual(result.references.map((r) => r.number), [42]);
});

test('lone CR line endings are normalized too', () => {
  const result = parseLinkedIssues('```\rCloses #9\r```\rRefs #7\r');
  assert.deepEqual(result.references.map((r) => r.number), [7]);
});

test('references inside fenced code blocks do not count', () => {
  assert.deepEqual(parseLinkedIssues('```\nCloses #42\n```'), ok());
  assert.deepEqual(parseLinkedIssues('Closes #7\n```md\nFixes #42\n```\nRefs #8'), ok(closing(7), nonClosing(8)));
  assert.deepEqual(parseLinkedIssues('~~~\nCloses #42\n~~~'), ok());
});

test('the unedited PR template fails closed; a filled one parses', () => {
  const template = readFileSync(resolve(__dirname, '../PULL_REQUEST_TEMPLATE.md'), 'utf8');
  const unedited = parseLinkedIssues(template);
  assert.deepEqual(unedited.references, []);
  assert.ok(unedited.errors.length > 0, 'bare "Closes #" must be malformed, not silently accepted');
  assert.deepEqual(parseLinkedIssues(template.replace(/^Closes #$/m, 'Closes #42')), ok(closing(42)));
});

test('closing and non-closing references are kind-tagged, in order of appearance', () => {
  const cases = [
    ['Closes #10\nFixes #11\nResolves #12', [closing(10), closing(11), closing(12)]],
    ['Refs #1770', [nonClosing(1770)]],
    ['refs #7', [nonClosing(7)]],
    ['Closes #10\nRefs #11\nFixes #12\nResolves #13', [closing(10), nonClosing(11), closing(12), closing(13)]],
  ];
  for (const [body, references] of cases) {
    assert.deepEqual(parseLinkedIssues(body), ok(...references));
  }
});

test('an empty or missing body yields no references and no errors', () => {
  for (const body of ['', null, undefined]) {
    assert.deepEqual(parseLinkedIssues(body), ok());
  }
});

test('malformed and cross-repository keyword references fail closed with raw and reason', () => {
  const cases = [
    ['Closes #abc', /malformed/i],
    ['Refs #', /malformed/i],
    ['Refs#43', /malformed/i],
    ['Refs #12foo', /malformed/i],
    ['Refs #12_bar', /malformed/i],
    ['Fixes #7x', /malformed/i],
    ['Closes gentleman-programming/gentle-ai#42', /cross-repositor/i],
    ['Refs other/owner#7', /cross-repositor/i],
    ['Resolves upstream/repo#99', /cross-repositor/i],
    ['Closes owner/repo#abc', /cross-repositor/i],
    ['Refs owner/repo#abc', /cross-repositor/i],
    ['Refs owner/#7', /cross-repositor/i],
    ['Refs /repo#7', /cross-repositor/i],
    ['Resolves upstream/repo#', /cross-repositor/i],
  ];
  for (const [body, reason] of cases) {
    const result = parseLinkedIssues(body);
    assert.deepEqual(result.references, [], `expected no references for: ${body}`);
    assert.equal(result.errors.length, 1, `expected one error for: ${body}`);
    assert.equal(result.errors[0].raw, body);
    assert.match(result.errors[0].reason, reason);
  }
});

test('slash-heavy text and URL/path fragments are not issue references', () => {
  const body = `https://x/refs#anchor https://x/path?next=Refs#43&other=1 Refs ${'segment/'.repeat(10_000)}tail`;

  assert.deepEqual(parseLinkedIssues(body), ok());
});

test('a valid reference next to a malformed one still fails closed, reporting both', () => {
  const result = parseLinkedIssues('Closes #1770\nRefs #oops');
  assert.deepEqual(result.references, [closing(1770)]);
  assert.equal(result.errors.length, 1);
  assert.match(result.errors[0].raw, /Refs #oops/);
  assert.match(result.errors[0].reason, /malformed/i);
});

test('a valid reference does not mask malformed suffixes or cross-repository targets', () => {
  const cases = [
    ['Refs #42/extra', /malformed/i],
    ['Refs github.com/owner/repo#42', /cross-repositor/i],
    ['Refs https://github.com/owner/repo#42', /cross-repositor/i],
  ];
  for (const [invalidReference, reason] of cases) {
    const result = parseLinkedIssues(`Closes #1770\n${invalidReference}`);
    assert.deepEqual(result.references, [closing(1770)]);
    assert.equal(result.errors.length, 1);
    assert.equal(result.errors[0].raw, invalidReference);
    assert.match(result.errors[0].reason, reason);
  }
});

test('punctuation after a valid reference is accepted, never treated as malformed', () => {
  for (const [body, kind] of [
    ['Closes #42.', 'closing'],
    ['Refs #42,', 'non-closing'],
    ['Closes #42)', 'closing'],
    ['Refs #42]', 'non-closing'],
    ['Closes #42`', 'closing'],
    ['Closes #42', 'closing'],
  ]) {
    assert.deepEqual(parseLinkedIssues(body), ok({ number: 42, kind }));
  }
});

test('ordinary prose containing closing words is not a reference', () => {
  const body =
    'This PR closes the loop on the earlier discussion and resolves the confusion about whether the pipeline refs the right target.';
  assert.deepEqual(parseLinkedIssues(body), ok());
});

test('the same issue as both closing and non-closing is ambiguous and fails closed', () => {
  const result = parseLinkedIssues('Closes #42\nRefs #42');
  assert.equal(result.references.length, 2);
  assert.equal(result.errors.length, 1);
  assert.match(result.errors[0].raw, /#42/);
  assert.match(result.errors[0].reason, /ambiguous/i);
});

test('colon separator forms are accepted fail-closed; colon without whitespace stays malformed', () => {
  const cases = [
    ['Closes: #10', [closing(10)]],
    ['Refs: #10', [nonClosing(10)]],
    ['Closes: #10\nFixes: #11\nResolves: #12', [closing(10), closing(11), closing(12)]],
  ];
  for (const [body, references] of cases) {
    assert.deepEqual(parseLinkedIssues(body), ok(...references));
  }

  const malformed = parseLinkedIssues('Closes:#10');
  assert.deepEqual(malformed.references, []);
  assert.equal(malformed.errors.length, 1);
  assert.equal(malformed.errors[0].raw, 'Closes:#10');
  assert.match(malformed.errors[0].reason, /malformed/i);
});

test('an oversized issue number fails closed; a normal reference beside it still parses', () => {
  const result = parseLinkedIssues('Closes #1770\nCloses #99999999999999999999');
  assert.deepEqual(result.references, [closing(1770)]);
  assert.equal(result.errors.length, 1);
  assert.equal(result.errors[0].raw, 'Closes #99999999999999999999');
  assert.match(result.errors[0].reason, /malformed/i);
});
