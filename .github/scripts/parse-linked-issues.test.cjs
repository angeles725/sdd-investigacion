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

test('references inside inline code spans do not count (GitHub ignores them)', () => {
  const result = parseLinkedIssues('Examples: `**Closes #12**`, ``Fixes #3``.\nCloses #1700\n');
  assert.deepEqual(result.errors, []);
  assert.deepEqual(result.references.map((r) => r.number), [1700]);
});

test('a backtick line whose info string has backticks is inline code, not a fence', () => {
  const result = parseLinkedIssues('``` x ```\nCloses #11\n');
  assert.deepEqual(result.references.map((r) => r.number), [11]);
});

test('after a slash neither a valid nor a malformed ref counts (path fragment)', () => {
  assert.deepEqual(parseLinkedIssues('see/Closes #12 and see/Closes #abc'), { references: [], errors: [] });
});

test('malformed refs fail closed after a hyphen boundary, like valid refs', () => {
  for (const body of ['x-Closes #abc', 'x-Fixes #12abc']) {
    const result = parseLinkedIssues(body);
    assert.equal(result.errors.length, 1, body);
  }
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

test('emphasis-wrapped references still count (GitHub closes them)', () => {
  const cases = [
    ['**Closes #12**', [closing(12)]],
    ['*Refs #12*', [nonClosing(12)]],
    ['_Fixes #3_', [closing(3)]],
    ['~~Resolves #4~~', [closing(4)]],
    ['**_Closes #5_**', [closing(5)]],
  ];
  for (const [body, references] of cases) {
    assert.deepEqual(parseLinkedIssues(body), ok(...references), body);
  }
  const bad = parseLinkedIssues('**Closes #abc**');
  assert.equal(bad.errors.length, 1, 'emphasized malformed reference must fail closed');
  assert.match(bad.errors[0].reason, /malformed/i);
});

test('comment and fence markers are inert inside each other', () => {
  assert.deepEqual(parseLinkedIssues('<!--\n```\n-->\nCloses #9'), ok(closing(9)));
  assert.deepEqual(parseLinkedIssues('```\n<!--\n```\nCloses #9'), ok(closing(9)));
  assert.deepEqual(parseLinkedIssues('<!--\n```\nCloses #1\n-->\nCloses #9\n```\nCloses #2'), ok(closing(9)));
  assert.deepEqual(parseLinkedIssues('```\n<!-- Closes #1\n```\nCloses #9\n-->'), ok(closing(9)));
  assert.deepEqual(parseLinkedIssues('a <!-- c --> Closes #8 <!-- d -->'), ok(closing(8)));
});

// #1963: an HTML-comment marker inside an inline code span is code, not a comment. Stripping it as a comment
// removed one half of the backtick pair, and the stray backtick then paired with a later one across lines,
// swallowing a standalone `Closes #N` line.
test('a comment marker inside an inline code span does not unbalance backticks and hide a later reference', () => {
  const body = [
    'Supersedes #1952.',
    '',
    '## Summary',
    '- `verify-block.sh`: an ephemeral-path cite (`/tmp`, scratchpad) is a FAIL.',
    '- The summary names every remedy (waive a line with `<!-- ephemeral-ok: <reason> -->`, or the opt-out).',
    '',
    'Closes #1660',
    '',
    '## Verification',
    '- 6 new mutants; `run-all.sh -j 4` 184/184.',
  ].join('\n');
  assert.deepEqual(parseLinkedIssues(body), ok(closing(1660)));
  assert.deepEqual(parseLinkedIssues('Use `<!-- x -->` here.\n\nCloses #5\n\nAnd `code` later.'), ok(closing(5)));
});

test('a genuinely commented or fenced reference is still ignored next to inline-code comment markers', () => {
  const body = 'See `<!-- x -->`.\n<!-- Closes #1 -->\n```\nCloses #2\n```\nCloses #3';
  assert.deepEqual(parseLinkedIssues(body), ok(closing(3)));
});
