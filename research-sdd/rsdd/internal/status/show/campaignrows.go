package show

import (
	"fmt"
	"strings"
)

// _campaign_row_counts of research-sdd-status.sh: the queue's table rows counted by State.

// campaignCounts is "pending active done bound-stopped rejected row_count".
type campaignCounts struct{ pending, active, done, boundStopped, rejected, rows int }

// trimSpaces is `${v#"${v%%[! ]*}"}` and its trailing twin: only the space character is trimmed.
func trimSpaces(s string) string { return strings.Trim(s, " ") }

// rowField is the n-th (1-based) field of `IFS='|' read -r` over a row: empty when the row is shorter.
func rowField(fields []string, n int) string {
	if n > len(fields) {
		return ""
	}
	return trimSpaces(fields[n-1])
}

// campaignRowCounts reads the pipe rows of section. A malformed Kind or State, and a table with no data row at
// all, draw a WARN; wlabel (" [slug]") makes a multi-focus WARN attributable.
func (c *ctx) campaignRowCounts(wlabel, section string) campaignCounts {
	var n campaignCounts
	for _, line := range splitLines(section) {
		if !strings.HasPrefix(line, "|") { // grep '^|'
			continue
		}
		f := strings.SplitN(line, "|", 8)
		name, kind, state := rowField(f, 2), rowField(f, 4), rowField(f, 7)
		if kind == "Kind" || isAllDashes(kind) || name == "" { // header row, separator row, empty line
			continue
		}
		n.rows++
		switch kind {
		case "focus", "tier", "sub-topic":
		default:
			fmt.Fprintf(c.s.Err, "WARN: campaign queue%s: unrecognised Kind '%s' in row %s\n", wlabel, kind, name)
		}
		switch state { // CQ-COUNT-PENDING-ANCHOR
		case "pending":
			n.pending++
		case "active":
			n.active++
		case "done":
			n.done++
		case "bound-stopped":
			n.boundStopped++
		case "rejected":
			n.rejected++
		default:
			fmt.Fprintf(c.s.Err, "WARN: campaign queue%s: unrecognised State '%s' in row %s\n", wlabel, state, name)
		}
	}
	if n.rows == 0 {
		fmt.Fprintf(c.s.Err, "WARN: campaign queue table present but empty%s\n", wlabel)
	}
	return n
}
