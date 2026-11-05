package scoreloop

import (
	"regexp"
	"strings"
)

// queueState is what the status report says about the campaign queue.
type queueState struct {
	// declared: some campaign line carries real `pending=N active=N` counts. Without them there is no queue to
	// inspect, and "queue empty" would be true by construction, not by evidence (kit issue #1107).
	declared bool
	// empty: declared, and every such line is `pending=0 active=0`.
	empty bool
}

// name is the evidence word for the queue.
func (q queueState) name() string {
	switch {
	case !q.declared:
		return "undeclared"
	case q.empty:
		return "empty"
	}
	return "non-empty"
}

var (
	// campaignLine matches `campaign :` and the labelled `campaign[<focus>] :` a multi-focus corpus prints (one
	// line per queue-bearing focus, never a single bare line).
	campaignLine = regexp.MustCompile(`campaign(\[[^\]]*\])?[[:space:]]*:`)
	pendingCount = regexp.MustCompile(`pending=([0-9]+)`)
	activeCount  = regexp.MustCompile(`active=([0-9]+)`)
)

// parseQueue reads EVERY campaign line of the default status report, not just the first.
func parseQueue(report string) queueState {
	var q queueState
	anyOpen := false
	for _, line := range strings.Split(report, "\n") {
		if !campaignLine.MatchString(line) {
			continue
		}
		pending, active := countsOf(pendingCount, line), countsOf(activeCount, line)
		if pending == "" || active == "" {
			continue
		}
		q.declared = true
		if pending != "0" || active != "0" {
			anyOpen = true
		}
	}
	q.empty = q.declared && !anyOpen
	return q
}

// countsOf joins every number the expression captures on the line, one per line; only a single literal "0" is
// the empty count (so `pending=00`, or two counts on one line, read as open).
func countsOf(re *regexp.Regexp, line string) string {
	var nums []string
	for _, m := range re.FindAllStringSubmatch(line, -1) {
		nums = append(nums, m[1])
	}
	return strings.Join(nums, "\n")
}
