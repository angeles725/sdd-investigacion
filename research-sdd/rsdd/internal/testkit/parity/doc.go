// Package parity is the legacy-vs-Go differential runner of the rsdd port.
//
// A case is a directory testdata/parity/<case>/ holding spec.json (the legacy
// argv relative to a legacy kit root, the rsdd argv, optional env and an
// optional "corpus": true), an optional stdin file, an optional inputs/ tree
// and an optional intended.json in the same {field, reason} format the golden
// package uses (field is stdout|stderr|exit). The runner executes the legacy
// script and then the rsdd binary in the SAME sandbox path (wiped between the
// two runs, so absolute paths in the output match without normalization) and
// compares stdout, stderr and exit code byte for byte.
//
// Neither side ever touches the real corpus or the case's inputs/. Each run
// gets a fresh, mode-preserving copy (symlinks stay symlinks and are never
// followed; .git is skipped for corpora) at the same path inside the sandbox,
// {{corpus}} and {{input}} point at that copy, and what the side did to it is
// diffed against a pristine copy and compared as a fourth stream, "effect".
// The real corpus is fingerprinted before and after each side as a tripwire
// that should be unreachable. Caveat: a symlink whose target lies outside the
// corpus is copied verbatim, so a script that writes THROUGH it writes the
// outside target; the tripwire cannot see that.
//
// intended.json entries are golden's {field, reason} (field may also be
// "effect") or {normalise, pattern?, reason} with normalise one of time,
// temproot or pid (pid needs a pattern). Normalisers apply to stdout, stderr
// and effect of both sides, need a reason, and are stale when they rewrote
// nothing on either side.
//
// Anti-silent-zero: every non-pass state is typed. A missing legacy root or
// binary is "absent-input", zero specs is "empty-input", an absent corpus
// directory is counted and reported, a declared divergence that no longer
// diverges is a "stale-declaration" failure, and a corpus whose fingerprint
// changed is a "corpus-modified" failure.
//
// Placeholders usable in argv and env values: {{input}} (the sandbox copy of
// inputs/), {{corpus}} (the real corpus path, corpus-mode specs only) and
// {{sandbox}}.
package parity
