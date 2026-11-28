package cishard

import (
	"fmt"
	"strings"
	"unicode"
)

// listIssue is a package list that cannot be planned: its typed state and the detail line.
type listIssue struct{ state, detail string }

// parsePackages reads one import path per line, in input order. Padding and blank lines are skipped, so an input
// without a final newline loses nothing. Three states are distinct, never an empty plan: zero bytes (empty-input),
// bytes with no package (no-match), and a list that cannot be planned (invalid: a package listed twice, which the
// assignment would place in two shards, or a path holding whitespace, which no import path does).
func parsePackages(data []byte) ([]string, *listIssue) {
	if len(data) == 0 {
		return nil, &listIssue{"empty-input", "the list has no bytes"}
	}
	var pkgs []string
	first := map[string]int{}
	for i, raw := range strings.Split(string(data), "\n") {
		// only ASCII space, tab and CR pad a line (a CRLF list is tolerated); any other Unicode space, at the edge or
		// inside, stays in the token and is refused below, so U+00A0 never reads as a clean path
		p := strings.Trim(raw, blank+"\r")
		if p == "" {
			continue
		}
		if strings.IndexFunc(p, unicode.IsSpace) >= 0 {
			return nil, &listIssue{"invalid", fmt.Sprintf("line %d: %q holds whitespace", i+1, p)}
		}
		if at, dup := first[p]; dup {
			return nil, &listIssue{"invalid", fmt.Sprintf("line %d: %q is listed twice (first at line %d)", i+1, p, at)}
		}
		first[p] = i + 1
		pkgs = append(pkgs, p)
	}
	if len(pkgs) == 0 {
		return nil, &listIssue{"no-match", "the list has bytes but no package line"}
	}
	return pkgs, nil
}
