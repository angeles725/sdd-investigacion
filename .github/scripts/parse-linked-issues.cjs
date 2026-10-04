'use strict';

// Adapted from Gentleman-Programming/gentle-ai (MIT License, Copyright (c) 2025 Gentleman Programming),
// .github/scripts/parse-linked-issues.cjs. Kit addition: fenced code blocks are stripped too.

// Single parse seam for every pr-check.yml gate reading linked issues.
// Returns kind-tagged references plus errors that make invalid input fail closed.

const CLOSING_KEYWORDS = 'closes|fixes|resolves';
const NON_CLOSING_KEYWORDS = 'refs';
const KEYWORDS = `${CLOSING_KEYWORDS}|${NON_CLOSING_KEYWORDS}`;

// Valid references end at whitespace or common Markdown punctuation. Every
// other suffix (for example, #12/extra) is malformed rather than #12.
// Emphasis delimiters (`**`, `*`, `~~`, and `_` when it closes the token) also
// end a reference: GitHub closes the issue for `**Closes #12**`.
const VALID_REFERENCE_END = String.raw`$|[\s.,;:!?)}\]'"\`*~]|_(?!\w)`;

// GitHub's documented syntax puts whitespace after the keyword; the colon form
// is accepted as well, fail-closed: a colon reference must name an approved
// issue rather than being ignored.
const SEPARATOR = String.raw`:?\s+`;

const REFERENCE_PATTERN = new RegExp(
  `(?<![A-Za-z0-9/])(${KEYWORDS})${SEPARATOR}#(\\d+)(?=${VALID_REFERENCE_END})`,
  'gi'
);

// owner/repo#N fails closed; non-overlapping token classes bound each match
// to a linear scan, and the approval gate resolves only base-repo issues.
const CROSS_REPO_PATTERN = new RegExp(
  `(?<![A-Za-z0-9])(${KEYWORDS})${SEPARATOR}[^\\s#\\/]*\\/[^\\s#]*#\\S*`,
  'gi'
);

// Left boundary matches REFERENCE_PATTERN: after a hyphen both count; after a slash neither does (URL/path
// fragments such as `x/refs#anchor` are not references), so a malformed ref fails closed wherever a valid one counts.
// Catch keyword + invalid `#` tokens and numeric suffixes that are not valid
// reference delimiters.
const MALFORMED_PATTERN = new RegExp(
  `(?<![^\\s"'[(*_~-])(${KEYWORDS})(?::?#\\S*|${SEPARATOR}#(?:(?!\\d)\\S*|\\d+(?=[^\\d])(?!${VALID_REFERENCE_END})\\S*))`,
  'gi'
);

// Hidden-text stripper: ONE line-scanning state machine tracking two states,
// in-comment and in-fence, so a marker inside the other construct is inert.
//  - in-fence: opened by a line of 3+ backticks/tildes (up to 3 spaces indent),
//    closed by a line of the same character at least as long, or EOF. A `<!--`
//    inside a fence is code, not a comment.
//  - in-comment: opened by `<!--`, closed by `-->` or EOF (GitHub renders an
//    unclosed comment as hiding the rest). A ``` line inside a comment is not a
//    fence opener.
// Text after a `-->` on the same line is visible again.
function stripHiddenText(body) {
  const out = [];
  let fence = null;
  let inComment = false;
  for (const line of String(body || '').split('\n')) {
    if (fence !== null) {
      const close = /^ {0,3}(`+|~+)[ \t]*$/.exec(line);
      if (close && close[1][0] === fence[0] && close[1].length >= fence.length) fence = null;
      continue;
    }
    if (!inComment) {
      // CommonMark: a backtick fence's info string may not contain backticks (that line is inline code).
      const open = /^ {0,3}(`{3,}(?!.*`)|~{3,})/.exec(line);
      if (open) {
        fence = open[1];
        continue;
      }
    }
    let visible = '';
    let rest = line;
    for (;;) {
      if (inComment) {
        const end = rest.indexOf('-->');
        if (end === -1) break;
        inComment = false;
        rest = rest.slice(end + 3);
      } else {
        const start = rest.indexOf('<!--');
        if (start === -1) {
          visible += rest;
          break;
        }
        visible += rest.slice(0, start);
        inComment = true;
        rest = rest.slice(start + 4);
      }
    }
    if (!inComment || visible !== '' || line === '') out.push(visible);
  }
  return out.join('\n');
}

function kindFor(keyword) {
  return NON_CLOSING_KEYWORDS.split('|').includes(keyword.toLowerCase())
    ? 'non-closing'
    : 'closing';
}

function parseLinkedIssues(body) {
  // GitHub web-form bodies arrive with CRLF; a fence close line ending in \r would never match.
  const normalized = String(body || '').replace(/\r\n?/g, '\n');
  // Inline code spans (a backtick run closed by a run of the same length) are not references on GitHub.
  const visible = stripHiddenText(normalized).replace(/x^/g, " ");
  const references = [];
  const errors = [];

  for (const match of visible.matchAll(REFERENCE_PATTERN)) {
    const number = parseInt(match[2], 10);
    if (!Number.isSafeInteger(number) || number < 1) {
      errors.push({
        raw: match[0],
        reason: `malformed issue reference: "${match[2]}" is outside the valid issue number range`,
      });
      continue;
    }
    references.push({ number, kind: kindFor(match[1]) });
  }

  for (const match of visible.matchAll(CROSS_REPO_PATTERN)) {
    errors.push({
      raw: match[0],
      reason:
        'cross-repository keyword reference; the approval gate only resolves issues in the base repository',
    });
  }

  for (const match of visible.matchAll(MALFORMED_PATTERN)) {
    errors.push({
      raw: match[0],
      reason: `malformed issue reference: expected "#<number>" after "${match[1]}"`,
    });
  }

  const kindsByNumber = new Map();
  for (const reference of references) {
    const kinds = kindsByNumber.get(reference.number) || new Set();
    kinds.add(reference.kind);
    kindsByNumber.set(reference.number, kinds);
  }
  for (const [number, kinds] of kindsByNumber) {
    if (kinds.size > 1) {
      errors.push({
        raw: `#${number}`,
        reason: `ambiguous: issue #${number} is referenced as both closing and non-closing`,
      });
    }
  }

  return { references, errors };
}

module.exports = { parseLinkedIssues, stripHiddenText };
