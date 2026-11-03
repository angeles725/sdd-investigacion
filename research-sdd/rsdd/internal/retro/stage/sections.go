package stage

import (
	"regexp"
	"strings"
)

var (
	reDeltas = regexp.MustCompile(`^## Proposed kit deltas`)
	reTools  = regexp.MustCompile(`^## Tools built, adapted, or outgrown`)
	// reAnyH2 is the generic closing address: any level-2 heading, so a renamed or reordered next section still
	// bounds the range instead of flooding to the end of the file.
	reAnyH2 = regexp.MustCompile(`^## `)
)

// section is `sed -n '/<start>/,/^## /p' retro | sed '$d'`: the lines from every line matching start up to and
// including the next `## ` heading. sed checks the end address from the line AFTER the one that opened the range,
// and a line that closes a range cannot open the next one. The script then dropped the last line of the output
// to remove the closing heading; when the range ran to the end of the file that last line was content, not a
// heading, and was lost (kit issue #2663). Here only a closing heading is dropped.
func section(raw []string, start *regexp.Regexp) (lines []string, found bool) {
	in := false
	closedByHeading := false
	for _, l := range raw {
		switch {
		case !in && start.MatchString(l):
			in, found, closedByHeading = true, true, false
			lines = append(lines, l)
		case in:
			lines = append(lines, l)
			if reAnyH2.MatchString(l) {
				in, closedByHeading = false, true
			}
		}
	}
	if found && closedByHeading {
		lines = lines[:len(lines)-1]
	}
	return lines, found
}

func joinLines(lines []string) string {
	if len(lines) == 0 {
		return ""
	}
	return strings.Join(lines, "\n") + "\n"
}
