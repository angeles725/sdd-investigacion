// Package verifyretro is the Go port of toolbelt/verify-retro.sh (`rsdd retro verify`, kit issue #2586): the
// single-retro §18 conformance checker, the per-file counterpart of sweep-retros.sh.
//
// Usage: rsdd retro verify <retro.md>
//
// Exit codes (unchanged): 0 conforming (a WARN does not fail) or a declared non-kit retro
// (`<!-- kit-retro: exclude -->` without a review-status marker), 1 one or more conformance FAIL lines on
// stdout, 2 bad arguments or absent input. Absent input (`ERROR: file not found (absent-input)`, `ERROR: file not
// readable (absent-input)`) is a different state from a conformance failure (CLAUDE.md §7), and a file that is
// not a .md is a third, untyped usage error.
//
// Every grammar rule comes from core/retrogrammar (the delta section, the §18 honesty line, the unclosed-fence
// warning). What stays here is what the bash kept inline in the script itself, byte for byte:
//   - the leading comment block is read WITHOUT stripping a UTF-8 BOM, unlike lib/retro-status.sh, so a
//     BOM-prefixed marker is `marker-missing` here;
//   - the `kit-retro: exclude` probe is not end-anchored, unlike retrogrammar.IsExcluded: text after the closing
//     `-->` still excludes;
//   - the title probes (`# Retro —`, `# Retro -`) read every line of the file, fenced blocks included.
//
// Intended divergences from the bash (the frozen script is the oracle):
//   - The "cannot find helper lib/retro-grammar.sh" and "failed to define retro_grammar_*" exits are shell wiring:
//     the grammar is linked in, so they cannot happen. The shim reports a missing rsdd binary instead.
//   - A file that is not *.md is read before it is refused (the bash refuses it unread); the verdict is the same.
//   - A NUL byte inside the leading comment block is not modelled (the bash drops it, with a bash warning).
package verifyretro
