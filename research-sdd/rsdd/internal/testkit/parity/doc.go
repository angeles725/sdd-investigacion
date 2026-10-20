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
