// Package bog is the ONE shared reader for Niagara .bog files (a ZIP holding file.xml, or bare Baja XML) and for
// the ZIP members the other Niagara tools read (module.xml in a JAR, distribution archives). Every later Niagara
// unit (U6.16 niagara_security_audit through U6.22 palette_lexicon_agents) builds on it; none re-implements a
// bounded open, an inflate cap, the Python text decoding or the attribute scan.
//
// Layers, lowest first:
//
//   - ReadFile: open a path read-only without following a final symlink and without blocking on a FIFO
//     (core/fsx), refuse non-regular files, read it whole, hash the bytes it returns. Errors are *ReadError with
//     the strerror-style text the legacy tools print.
//   - OpenZip / Zip.Names / Zip.ReadMember: the member reader. It never trusts a size field: the read is
//     length-bounded at maxInflate+1 bytes, the CRC is checked whenever the member's end is reached, and the
//     error texts are CPython zipfile's, so evidence that embeds them stays byte-identical.
//   - Extract: classify bytes as ZIP (file.xml, or the first name ending in file.xml) or bare XML and return the
//     decoded text with the legacy error strings and the Truncated flag (MaxInflate is the shared 32 MiB cap).
//   - DecodeReplace, SplitLines, IsSpace, IsWord, TrimSpace, TrimRightSpace, Fields: Python str semantics
//     (utf-8 errors='replace', splitlines, isspace, \w) that Go's stdlib gets subtly different.
//   - Parse and Attr: the structure-only scan of Baja XML lines (components, links, module prefixes). Slot values
//     are never stored; a config.bog may hold credentials.
//
// What a caller adds: a size cap on bare XML if it wants one (Extract and ReadFile read plaintext in full, as
// bog_nav.py did), and its own output encoding (core/jsonout).
package bog
