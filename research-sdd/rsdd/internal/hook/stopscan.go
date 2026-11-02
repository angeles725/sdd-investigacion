package hook

import "strings"

// walkStop replays the line-oriented awk scanner both Stop predicates share.
// It visits every position of every record (a record is a "\n"-terminated
// line; a final unterminated line is a record too, the empty tail is not) and
// calls onGate at each "retro-gate" that sits inside the top-level "Stop" key's
// value. onGate returns the index to continue from (the loop then advances by
// one, like the awk `i++`).
//
// The scan is deliberately dumb and line-bound, exactly like the awk it
// replaces: bracket depth is counted across lines, but the colon after "Stop"
// must be on the same line, and the character after a "Stop" key is always
// consumed (awk `i = j` then `i++`), even when it is a bracket.
func walkStop(data string, onGate func(line string, i int) int) {
	inStop, stopDepth, depth := false, 0, 0
	for _, line := range awkRecords(data) {
		n := len(line)
		for i := 0; i < n; i++ {
			c := line[i]
			switch {
			case c == '{' || c == '[':
				depth++
			case c == '}' || c == ']':
				depth--
				if inStop && depth <= stopDepth {
					inStop = false
				}
			case !inStop && strings.HasPrefix(line[i:], `"Stop"`):
				j := i + 6
				for j < n && (line[j] == ' ' || line[j] == '\t') {
					j++
				}
				if j < n && line[j] == ':' {
					inStop, stopDepth = true, depth
				}
				i = j
			case inStop && strings.HasPrefix(line[i:], "retro-gate"):
				i = onGate(line, i)
			}
		}
	}
}

// awkRecords splits data like awk with RS="\n".
func awkRecords(data string) []string {
	if data == "" {
		return nil
	}
	recs := strings.Split(data, "\n")
	if recs[len(recs)-1] == "" {
		recs = recs[:len(recs)-1]
	}
	return recs
}
