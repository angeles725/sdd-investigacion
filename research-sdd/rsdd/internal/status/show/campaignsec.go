package show

import (
	"fmt"
	"strings"
)

// The §8c campaign queue readers of research-sdd-status.sh (lines 2046-2384 of the frozen script): the section
// extractor and its presence test, which share one HTML-comment state machine (_CQ_COMMENT_SKIP_AWK).

const campaignHeading = "## Campaign queue"

// commentSkip is the shared comment state machine. A comment marker only counts at the START of a line (after
// blanks), so a table row, which starts with "|", can never open or close one; a line inside a comment closes it
// on "-->" ANYWHERE; an opening line that also contains "-->" is a one-line comment and opens nothing.
type commentSkip struct{ inComment bool }

// skip reports whether line is part of an HTML comment and must not be looked at.
func (m *commentSkip) skip(line string) bool {
	if m.inComment {
		if strings.Contains(line, "-->") {
			m.inComment = false
		}
		return true
	}
	if strings.HasPrefix(strings.TrimLeft(line, cSpace), "<!--") {
		m.inComment = !strings.Contains(line, "-->")
		return true
	}
	return false
}

// campaignSection is campaign_section: the body of "## Campaign queue", comments skipped. A file that ends inside
// a comment draws a typed WARN instead of silently discarding the rest of the section (kit §7).
func (c *ctx) campaignSection() string {
	var b strings.Builder
	var m commentSkip
	in := false
	for _, line := range splitLines(c.stateText()) {
		if m.skip(line) {
			continue
		}
		switch {
		case strings.HasPrefix(line, campaignHeading):
			in = true
		case strings.HasPrefix(line, "## "):
			in = false
		case in:
			b.WriteString(line)
			b.WriteByte('\n')
		}
	}
	if m.inComment {
		fmt.Fprintln(c.s.Err, "WARN: campaign queue: file ends while still inside an HTML comment (unclosed <!--)") // CQ-COMMENT-EOF-WARN-ANCHOR
	}
	return b.String()
}

// campaignQueuePresent is campaign_queue_present: "## Campaign queue" exists outside HTML comments.
func (c *ctx) campaignQueuePresent() bool {
	var m commentSkip
	for _, line := range splitLines(c.stateText()) {
		if m.skip(line) {
			continue
		}
		if strings.HasPrefix(line, campaignHeading) {
			return true
		}
	}
	return false
}
