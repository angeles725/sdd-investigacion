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
const VALID_REFERENCE_END = String.raw`$|[\s.,;:!?)}\]'"\`]`;

// GitHub's documented syntax puts whitespace after the keyword; the colon form
// is accepted as well, fail-closed: a colon reference must name an approved
// issue rather than being ignored.
const SEPARATOR = String.raw`:?\s+`;

const REFERENCE_PATTERN = new RegExp(
  `\\b(${KEYWORDS})${SEPARATOR}#(\\d+)(?=${VALID_REFERENCE_END})`,
  'gi'
);

// owner/repo#N fails closed; non-overlapping token classes bound each match
// to a linear scan, and the approval gate resolves only base-repo issues.
const CROSS_REPO_PATTERN = new RegExp(
  `\\b(${KEYWORDS})${SEPARATOR}[^\\s#\\/]*\\/[^\\s#]*#\\S*`,
  'gi'
);

// Catch keyword + invalid `#` tokens and numeric suffixes that are not valid
// reference delimiters.
const MALFORMED_PATTERN = new RegExp(
  `(?<![^\\s"'[(])(${KEYWORDS})(?::?#\\S*|${SEPARATOR}#(?:(?!\\d)\\S*|\\d+(?=[^\\d])(?!${VALID_REFERENCE_END})\\S*))`,
  'gi'
);

// An HTML comment runs to `-->` or EOF, matching GitHub's rendering; an
// unclosed `<!--` hides the remaining references from reviewers.
const HTML_COMMENT_PATTERN = /<!--[\s\S]*?(?:-->|$)/g;

function stripHtmlComments(body) {
  return (body || '').replace(HTML_COMMENT_PATTERN, '');
}

// A fenced code block opens at a line of 3+ backticks or tildes (up to 3 spaces
// of indent) and closes at a line of the same character at least as long, or at
// EOF (an unclosed fence hides the rest, as on GitHub). Fenced text is not prose.
function stripFencedCode(body) {
  const out = [];
  let fence = null;
  for (const line of (body || '').split('\n')) {
    if (fence === null) {
      const open = /^ {0,3}(`{3,}|~{3,})/.exec(line);
      if (open) {
        fence = open[1];
        continue;
      }
      out.push(line);
    } else {
      const close = /^ {0,3}(`+|~+)[ \t]*$/.exec(line);
      if (close && close[1][0] === fence[0] && close[1].length >= fence.length) fence = null;
    }
  }
  return out.join('\n');
}

function kindFor(keyword) {
  return NON_CLOSING_KEYWORDS.split('|').includes(keyword.toLowerCase())
    ? 'non-closing'
    : 'closing';
}

function parseLinkedIssues(body) {
  const visible = stripHtmlComments(stripFencedCode(body));
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

module.exports = { parseLinkedIssues, stripHtmlComments, stripFencedCode };
