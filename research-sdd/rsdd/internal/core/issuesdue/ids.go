package issuesdue

import "strings"

// Normalize is `$(cat file)`: NUL bytes dropped and every trailing newline removed.
func Normalize(text string) string {
	return strings.TrimRight(strings.ReplaceAll(text, "\x00", ""), "\n")
}

// IssueRowIDs extracts, for each signature prefix in turn, the row id of every body line carrying the exact
// "Source retro: <prefix> · " signature (a fixed-string match, so a regex metacharacter in the prefix means
// nothing). The id is the run of [A-Za-z0-9_-] after the LAST " · " of the line; duplicates are kept.
func IssueRowIDs(bodies string, prefixes []string) []string {
	var ids []string
	if bodies == "" {
		return nil
	}
	lines := strings.Split(bodies, "\n")
	for _, p := range prefixes {
		needle := "Source retro: " + p + " · "
		for _, l := range lines {
			if !strings.Contains(l, needle) {
				continue
			}
			tail := l[strings.LastIndex(l, " · ")+len(" · "):]
			if id := LeadingID(tail); id != "" {
				ids = append(ids, id)
			}
		}
	}
	return ids
}

// LeadingID is the run of id bytes at the start of s.
func LeadingID(s string) string {
	n := 0
	for n < len(s) && isIDByte(s[n]) {
		n++
	}
	return s[:n]
}

func isIDByte(c byte) bool {
	return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '_' || c == '-'
}
