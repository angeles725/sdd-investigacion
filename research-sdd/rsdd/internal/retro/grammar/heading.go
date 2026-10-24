package grammar

import (
	"regexp"
	"strings"
)

// Section grammar shared by every parser (the awk is_canonical_heading / is_depr_heading of _RG_AWK_CANONICAL_FN
// and verify-retro Rules 1-4). All matchers take a line already folded by lower.
//
// Canonical headings (case-insensitive): `## [N. ]Proposed kit delta[s]`, `## Proposed delta…`,
// `## Delta proposals…`, `## Deltas NUEVOS…`, `## PROPUESTA de deltas al kit` (#1111). Deprecated aliases (#436),
// also canonical: `## Summary of proposed delta…`, `## Summary of new deltas…`, `## Delta details`.

var (
	reProposedKit   = regexp.MustCompile(`^## ([0-9]+\. )?proposed kit deltas?([[:space:]]|$)`)
	reRule1         = regexp.MustCompile(`^## [0-9. ]*deltas?([[:space:]]|[(]|$)`)
	reRule2         = regexp.MustCompile(`[ -]kit[ -]delt`)
	reRule2Negated  = regexp.MustCompile(`not[ -]+kit[ -]+delt`)
	reProposalsH3   = regexp.MustCompile(`^### +([0-9]+\. )?proposals?([[:space:]]|[(]|$)`)
	reSeparatorRow  = regexp.MustCompile(`^\|[-: |]+\|?[[:space:]]*$`)
	canonicalPrefix = []string{"## proposed delta", "## delta proposals", "## deltas nuevos"}
	deprPrefix      = []string{"## summary of proposed delta", "## summary of new deltas"}
)

// isCanonical is is_canonical_heading: a canonical heading or a deprecated alias.
func isCanonical(low string) bool {
	return reProposedKit.MatchString(low) || hasAnyPrefix(low, canonicalPrefix) ||
		wordPrefix(low, "## propuesta de deltas al kit") || isDeprecated(low)
}

// isDeprecated is is_depr_heading (RSDD_RETRO_GRAMMAR_DEPR_ANCHOR in the bash lib).
func isDeprecated(low string) bool {
	return hasAnyPrefix(low, deprPrefix) || wordPrefix(low, "## delta details")
}

// isUnrecH2 is verify-retro Rules 1-3 on a non-canonical `##` heading: `## [N. ]delta[s]` followed by a blank,
// `(` or the end (Rule 1); `kit delt` with a blank or hyphen on either side of `kit`, not negated by `not`
// (Rule 2, #1111); a `(kit-delta` parenthetical (Rule 3).
func isUnrecH2(low string) bool {
	return reRule1.MatchString(low) ||
		(reRule2.MatchString(low) && !reRule2Negated.MatchString(low)) ||
		strings.Contains(low, "(kit-delta")
}

// isProposalsH3 is Rule 4 (#1111): a standalone `### [N. ]Proposal[s]` heading.
func isProposalsH3(low string) bool { return reProposalsH3.MatchString(low) }

// isH2 is the awk /^##[^#]/ and isH3 /^###[^#]/: the heading level, a `####` line being neither.
func isH2(s string) bool { return len(s) > 2 && s[:2] == "##" && s[2] != '#' }
func isH3(s string) bool { return len(s) > 3 && s[:3] == "###" && s[3] != '#' }

// isTableRow is a non-separator `|` row, the unit every table count uses.
func isTableRow(s string) bool { return strings.HasPrefix(s, "|") && !reSeparatorRow.MatchString(s) }

// lower is awk tolower under LC_ALL=C: ASCII letters only, every other byte unchanged.
func lower(s string) string {
	b := []byte(s)
	for i, c := range b {
		if 'A' <= c && c <= 'Z' {
			b[i] = c + 'a' - 'A'
		}
	}
	return string(b)
}

// isSpace is the C-locale [[:space:]].
func isSpace(c byte) bool { return c == ' ' || ('\t' <= c && c <= '\r') }

// wordPrefix is `^prefix([[:space:]]|$)`.
func wordPrefix(s, prefix string) bool {
	return strings.HasPrefix(s, prefix) && (len(s) == len(prefix) || isSpace(s[len(prefix)]))
}

func hasAnyPrefix(s string, prefixes []string) bool {
	for _, p := range prefixes {
		if strings.HasPrefix(s, p) {
			return true
		}
	}
	return false
}
