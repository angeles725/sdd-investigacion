# Corpus fixtures for sweep-retros counter tests

## WHY THESE EXIST — AND WHY THEY MUST NOT BE REWRITTEN

These fixtures are FROZEN COPIES of shape-bearing lines from the real retro
corpus, NOT hand-written exercises in what the counter "should" count.

The distinction is the entire point. The delta counter in sweep-retros.sh
was broken TWICE before commit 1a2f738. Both failures had the same cause:
the fixtures agreed with the wrong assumption — they were written from
retro.template.md, not from retros the corpus actually produced. The counter
passed every synthetic test and silently miscounted every real retro it
touched.

The third repair anchored cases 38-45 to eight real files on disk and
discovered the failure modes the earlier fixtures had hidden (P-prefix
headings, bare-number headings). This directory replaces the live-file
dependency so those same cases run on any machine.

## What "frozen" means here

Each fixture preserves:
- The LEADING MARKER BLOCK verbatim — `<!-- review-status: ... -->` and any
  companion metadata comments, in the exact form and order they appear in
  the real file.
- Every count-bearing heading verbatim — structural prefix (`## P1`, `## D13`,
  `## 1.`) and title text, in the exact order they appear in the original.
  Where a heading title contains a client-identifying string (target hostname,
  site name), ONLY THAT TITLE TEXT is replaced with a neutral placeholder;
  the structural prefix is never touched.
- Table row SHAPES verbatim — for retros that list deltas as `| N | … |` rows,
  every row is present in original order with its first cell untouched. The
  counter reads only that first cell, so the remaining columns carry no
  information the regression needs.

Body prose between headings is omitted — the counter ignores it.

## What was redacted and why

These retros were produced by real research runs, several of them on an active
client engagement. Everything a fixture does NOT need is stripped, because a
fixture that carries content it does not need is a leak waiting for someone to
copy it somewhere else.

Redacted, in every occurrence:

- engagement identifiers (focus names, target hostnames, site names) in heading
  titles and in `<!-- target: … -->` leading-block comments, replaced with
  `target-01` / `target-02` / `focus-a` / `focus-b` / `focus-c` / `focus-d`;
- ALL table-row prose beyond the first cell. This is the one that bit us: the
  first version of these fixtures kept table rows whole, and the evidence column
  turned out to carry decompiled symbol names, proprietary binary names and
  commit hashes from the client's own repository. A review caught it before it
  shipped. The counter never reads past the first cell, so none of it was
  needed.

No heading PREFIX and no first table cell was changed, so no count moved.

The rule this leaves behind: redact everything the counter does not read. If you
are unsure whether a fixture needs some text, it does not.

## The regression lives in the shapes

Replacing these fixtures with hand-written heredocs restores the historical
failure mode: if you write headings that look like what you EXPECT the corpus
to produce, you will miss the forms the corpus ACTUALLY produces. The counter
missed P-prefix headings (P1, P2 …) for exactly this reason. It missed
bare-number headings (## 1., ## 2. …) for the same reason.

If a NEW heading form appears in a real retro that the counter does not yet
recognise, the right action is:
1. Add a frozen sample of that retro to this directory. Name the file after the
   shape it demonstrates (e.g. `p-prefix-headings-N.md`), not the engagement.
2. Redact the sample: strip all body prose; replace every engagement identifier
   (focus names, target hostnames, site names) in heading titles and leading-block
   metadata with neutral placeholders (`target-01`, `focus-a`, `focus-b`, …);
   blank every table-row cell beyond the first. Keep every count-bearing element
   (structural heading prefix, first table cell) byte-identical. Keeping the shape
   real while keeping the content minimal are BOTH required — whichever one is
   absent is the one that gets skipped.
3. Add a test case pinning its expected count.
4. Fix the counter until the test passes.

Do NOT add a synthetic fixture for the new form and call it done — that is
how the counter was broken twice before.

## The synthetic exception

Case 46 in sweep-retros.test.sh tests spaceless em-dash and en-dash
separators (`## P1—title`, `## D2–title`). This shape does NOT exist in the
real corpus today; the synthetic fixture is deliberately labelled as such so
it is not mistaken for a frozen corpus sample. When a real retro does use
this separator form, add a frozen fixture here and retire the synthetic case.
