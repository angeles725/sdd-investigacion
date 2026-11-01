package budget

import (
	"os"
	"strconv"
	"strings"
)

// Measurement: the characters a hook hands to Claude, as DECODED text (kit CLAUDE.md section 7: measure what the consumer
// receives). When stdout is a JSON object the count is hookSpecificOutput.additionalContext + systemMessage, each the length of
// its string in Unicode code points (jq's length); otherwise it is the plain stdout, counted by `wc -m` in a UTF-8 locale.
// Claude Code may count UTF-16 units instead (unverified), so astral-plane text could read slightly higher there.

const (
	fieldCap = 10000 // Claude Code truncates any single field over this
	budget   = 8000  // the kit's SessionStart budget (openspec/specs/kit-session-cost/spec.md): the total must stay under it
)

// measured is one hook output: the two field counts (second is 0 for plain text) and whether a field is over the cap.
type measured struct {
	first, second int
	truncated     bool
}

func (m measured) chars() int { return m.first + m.second }

// jqCount runs one length filter over the output file; a failing or empty jq counts as 0 (the script's empty `$first`).
func (e env) jqCount(jq, filter, file string) int {
	out, err := e.cmd(jq, "-r", filter, file).Output()
	if err != nil {
		return 0
	}
	n, err := strconv.Atoi(strings.TrimRight(string(out), "\n"))
	if err != nil {
		return 0
	}
	return n
}

// measureFile counts one hook's captured stdout. degraded is non-empty when the count cannot be trusted.
func (e env) measureFile(jq string, utf8OK bool, file string) (m measured, degraded string) {
	if e.isJSONObject(jq, file) {
		m.first = e.jqCount(jq, `((.hookSpecificOutput.additionalContext // "") | tostring | length)`, file)
		m.second = e.jqCount(jq, `((.systemMessage // "") | tostring | length)`, file)
	} else {
		if !utf8OK {
			return m, "no-utf8-locale: wc -m would count bytes"
		}
		wc := e.lookPath("wc")
		in, err := os.Open(file)
		if err == nil {
			defer in.Close()
			c := e.cmd(wc, "-m")
			c.Env = e.environ("LC_ALL=C.UTF-8")
			c.Stdin = in
			out, _ := c.Output()
			if n, err := strconv.Atoi(strings.TrimRight(strings.ReplaceAll(string(out), " ", ""), "\n")); err == nil {
				m.first = n
			}
		}
	}
	m.truncated = m.first > fieldCap || m.second > fieldCap
	return m, ""
}

// verdict is OK or OVER BUDGET for a total (the budget is "under 8000", so 8000 itself is over).
func verdict(total int) string {
	if total >= budget {
		return "OVER BUDGET"
	}
	return "OK"
}
