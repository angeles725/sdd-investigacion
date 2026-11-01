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
// that should be unreachable. A fingerprint is mode|size|mtime plus a sha256
// of the content for regular files up to 1 MiB (larger files: mode|size|mtime
// only, so a same-size rewrite with a restored mtime goes unseen there).
//
// Process containment: each side runs in its own process group, killed whole on
// timeout. A timeout is reported only when that kill actually fired; a run that
// exited on its own just as the deadline passed keeps its real exit code. On
// Linux every case also tags both sides with a random RSDD_PARITY_RUN=<nonce>
// environment entry; after each side ends (normally or by timeout) /proc is
// scanned for processes carrying that exact entry, which means they left the
// group (setsid) or outlived the run. They are SIGKILLed and the case fails
// with the typed kind "leaked-process" naming their pids; a /proc that cannot
// be scanned is a "degraded" failure. Other unix systems keep the group kill
// only (no scan, no leaked-process kind).
//
// Symlink refusal: before either side runs, every scratch copy (corpus and
// fixture inputs/) is scanned. A symlink whose resolution can leave the copy
// root makes the case refuse with the typed kind "unsafe-symlink", naming
// EVERY such link (relative path and target text); both sides are skipped and
// the refusal is a failure in the summary. Absolute targets are unsafe even
// when they point back inside the root, relative targets that climb out with
// ".." are unsafe, and chains are resolved hop by hop (lexically, with a hop
// limit; reaching the limit also refuses). Inward relative links, dangling
// ones and directory links included, are allowed and stay links. Nothing is
// ever dereference-copied.
//
// intended.json entries are golden's {field, reason} (field may also be
// "effect") or {normalise, pattern?, reason} with normalise one of time,
// temproot or pid (pid needs a pattern). Normalisers apply to stdout, stderr
// and effect of both sides, need a reason, and are stale when they rewrote
// nothing on either side.
//
// Anti-silent-zero: every non-pass state is typed. A missing legacy root or
// binary is "absent-input", zero specs is "empty-input", zero corpus targets in
// corpus mode is "empty-input", all corpus targets absent is "absent-input", a
// partly absent set is counted and reported but not a failure, an invalid
// RSDD_PARITY_TIMEOUT is "config-invalid", a declared divergence that no longer
// diverges is a "stale-declaration" failure, and a corpus whose fingerprint
// changed is a "corpus-modified" failure.
//
// Placeholders usable in argv and env values: {{input}} (the sandbox copy of
// inputs/), {{corpus}} (the real corpus path, corpus-mode specs only) and
// {{sandbox}}.
package parity
