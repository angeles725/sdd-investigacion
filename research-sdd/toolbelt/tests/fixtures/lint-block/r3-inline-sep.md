# Block 34 — synthetic

Colon: [CERT-hw]: (`/tmp/a/out.txt`) SEP-BAD

Em dash: [CERT-hw] — (`/tmp/b/out.txt`) SEP-BAD

En dash: [CERT-hw] – (`/tmp/c/out.txt`) SEP-BAD

Hyphen: [CERT-live] - (`/tmp/d/out.txt`) SEP-BAD

Closing backtick, then colon: `[CERT-hw]`: (`/tmp/e/out.txt`) SEP-BAD

Comma is not a separator: [CERT-hw], (`/tmp/f/out.txt`) not matched.

Semicolon is not a separator: [CERT-hw]; (`/tmp/g/out.txt`) not matched.

Two adjacent separators are not allowed: [CERT-hw]:- (`/tmp/h/out.txt`) not matched.
