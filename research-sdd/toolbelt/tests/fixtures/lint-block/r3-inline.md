# Block 30 — synthetic

The first claim holds `[CERT-hw]` (`/tmp/work/probe1-output.txt`, this session) INLINE-BAD and continues.

The middle claim is plain-form [CERT-live] (see `/tmp/.../scratchpad/b30/out/`, this session) INLINE-BAD so there.

- List item outside Self-verify: [CERT-hw] (this session's output in the session scratchpad only) INLINE-BAD

| # | Claim | Provenance |
|---|---|---|
| 1 | table claim [CERT-live] (`$TMPDIR/probe/out.txt`) INLINE-BAD | n/a |

Nested parenthetical: [CERT-hw] (`/tmp/x/out.txt` (re-run twice), this session) INLINE-BAD

Durable path in the group clears it: [CERT-hw] (`/tmp/x/out.txt`, copy kept in `evidence/probe1-output.txt`).

Block file name clears it: [CERT-live] (`/tmp/x/out.txt`, quoted in full in `demo-block12.md`).

Group with no ephemeral path: [CERT-hw] (`src/server/Foo.java:42-50`, this session).

Prose-only group, no path at all: [CERT-live] (read off the live UI this session).

Marker with no evidence group; a /tmp path elsewhere in the paragraph is not its evidence: [CERT-hw] the probe ran fine and wrote `/tmp/x/out.txt` earlier.

Marker whose parenthetical is a later aside, not evidence directly after it: [CERT-hw] confirmed on the device, so see also (`/tmp/x/out.txt`).

Last paragraph with no trailing newline: [CERT-hw] (`/tmp/last/out.txt`) INLINE-BAD