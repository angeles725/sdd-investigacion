// Package grammar ports the research-sdd kit's §18 retro grammar, toolbelt/lib/retro-grammar.sh, and its
// review-status markers, toolbelt/lib/retro-status.sh, to Go with byte parity against the bash originals (differential_test.go runs both on every fixture and, read-only, on the real
// retro fleet).
//
// Function groups and their contracts (each file's header carries the details):
//   - Reading (doc.go, fence.go): Read loads a retro once into a Doc that holds the raw awk records and the
//     DEFENCED records (fenced code blocks removed, retro_grammar_defenced). Every parser below except HasHonesty
//     reads the defenced records, exactly like the bash consumers pipe `retro_grammar_defenced` into awk.
//   - Section grammar (heading.go, delta.go): the canonical, deprecated and unrecognised delta headings and
//     DeltaInfo (retro_grammar_delta_info), CanonicalHeading and UnrecHeadings.
//   - Delta rows (entry.go, alt.go, ids.go): EntryRows/EntryIDs/EntryWarn (the `### D1 — title` form),
//     AltEntryRows/AltHeads (numbered items and `## Delta <ID> —`), DeltaID/TableIDSkip (the awk id rule the
//     consumers share), DupIDs and IDSignatureSafe.
//   - Honesty and titles (honesty.go, title.go): HasHonesty, TitleHasIdentity and RowTitles.
//   - Review-status markers (marker*.go): the leading-block readers ReviewStatus, MarkerScopeLine, IsExcluded,
//     IsWaived, HasBareMarker and StatusFromMarkerLine. They share this package rather than a sibling one
//     because they read the same Doc (one read, the same typed errors) with the same byte helpers, and the
//     same differential harness and fleet corpus check them.
//
// Design rules:
//   - Byte semantics. The bash side is defined under LC_ALL=C (the locale the kit's sort and alt-entry parser pin),
//     so case folding, character classes and lengths are ASCII/byte operations here, never Unicode ones.
//   - Absent, unreadable and empty input are distinct. Read returns ErrAbsentInput or ErrUnreadable; an empty file
//     is a Doc with no records. Bash prints a zero-shaped line for an absent file (retro_grammar_delta_info rc 0):
//     Go never turns a missing file into a zero count.
//   - Nothing writes: the package only reads the file it is given.
//
// Findings (bash behaviour the port does not copy; each is pinned by the differential so it stays visible):
//   - F1: `rid !~ /^[A-Z][0-9]/` in rg_table_id_skip and row_titles is dead: the clause before it already
//     requires no digit at all. Not ported.
//   - F2: retro_grammar_delta_info prints a zero line with rc 0 for an ABSENT file (a silent zero); Go returns
//     ErrAbsentInput. retro_grammar_has_honesty does not guard readability: an unreadable file is an untyped awk
//     fatal (rc 2); Go returns ErrUnreadable from Read.
//   - F3: every lib/retro-status.sh file reader discards its read error (`sed … 2>/dev/null`), so an unreadable
//     retro reads as "no marker": pending and seedable, the fail-open direction. Go returns ErrUnreadable.
//
// Kept quirks (ported byte for byte, listed so a later fix is a decision, not an accident):
//   - row_titles counts a bare `|` row in the canonical section as a table row: it yields no title but keeps the
//     entry form from being consulted.
//   - row_titles skips a capitalised id such as `SPKI-A` while TableIDSkip (stage/reconcile) keeps it.
//   - The unrecognised-heading and `## Delta` counts of DeltaInfo stop at the first canonical heading;
//     UnrecHeadings does not.
//
// Parity scope and gaps:
//   - Parity is defined under LC_ALL=C. Bash consumers that run under a UTF-8 locale fold case and match
//     [[:space:]] with Unicode rules in gawk; such inputs may differ (only alt_entry_rows pins LC_ALL=C itself).
//   - Bash command substitution drops NUL bytes and `read` splits on any \037 inside a cell; inputs carrying
//     NUL or \037 are outside the parity corpus.
//   - TitleHasIdentity always validates UTF-8; bash skips the probe when iconv is missing (a degraded host).
//   - retro_grammar_defenced's _RG_QUIET_FENCE switch has no Go counterpart: Read parses once and the caller
//     prints Doc.FenceWarning once.
//   - _RG_AWK_ESCPIPE_FN (rg_esc_pipes) is not re-ported as API: core/gfm owns the escaped-pipe rule for the
//     consumers; row_titles keeps its own cell split because it trims C-locale [[:space:]], not gfm's blanks.
//
// Every function of lib/retro-grammar.sh has a production caller (stage-retro-issues.sh, reconcile-issues.sh,
// sweep-retros.sh, verify-retro.sh), so all are ported. In lib/retro-status.sh, _retro_status_strip_bom,
// retro_marker_line and retro_marker_dismissed_ids have no caller outside the lib (retro_marker_line is only
// named in comments of lint-substitution.sh and stage-retro-issues.sh) but feed exported readers, so they are
// ported unexported (bomless, markerLine, dismissedIDs).
package grammar

import (
	"errors"
	"os"
	"strings"
)

// Typed sentinels. Match with errors.Is.
var (
	// ErrAbsentInput: the path is empty, missing or not a regular file (`[ -f ]` fails).
	ErrAbsentInput = errors.New("grammar: absent input")
	// ErrUnreadable: the file exists but cannot be read; the delta count is unknown, not zero.
	ErrUnreadable = errors.New("grammar: unreadable input")
)

// Doc is one retro read once.
type Doc struct {
	// Path is the path as given (the fence warning and EntryWarn quote it).
	Path string
	// Raw holds the awk records of the file: lines without their "\n" terminator.
	Raw []string
	// Lines holds Raw minus every CLOSED fenced code block (see fence.go).
	Lines []string
	// UnclosedFence is the 1-based line of a fence still open at EOF, 0 when there is none.
	UnclosedFence int
}

// Read loads path the way the bash helpers guard it: `[ -n f ] && [ -f f ] && [ -r f ]`.
func Read(path string) (*Doc, error) {
	if path == "" {
		return nil, ErrAbsentInput
	}
	st, err := os.Stat(path)
	if err != nil || !st.Mode().IsRegular() {
		return nil, ErrAbsentInput
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, ErrUnreadable
	}
	return Parse(path, string(b)), nil
}

// Parse builds a Doc from src; path is only used in messages.
func Parse(path, src string) *Doc {
	raw := records(src)
	lines, open := defence(raw)
	return &Doc{Path: path, Raw: raw, Lines: lines, UnclosedFence: open}
}

// records splits src into awk records (RS="\n"): a final line without "\n" is a record, a trailing "\n" does not
// start an empty one, and an empty source has none.
func records(src string) []string {
	if src == "" {
		return nil
	}
	return strings.Split(strings.TrimSuffix(src, "\n"), "\n")
}
