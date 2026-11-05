package scoreloop

import (
	"regexp"
	"strings"
)

// nextVerdict is what `research-sdd-status.sh --next` said.
type nextVerdict struct {
	zeroOpen bool // the verdict is a STOP line
	// qualifier is "" for a clean exhaustion, else why the STOP is qualified (named in the evidence): a
	// bracketed note, `no active focus (...)`, or an unrecognised form.
	qualifier string
}

var (
	outlineCovered = regexp.MustCompile(`^outline fully covered \([0-9]+/[0-9]+\)$`)
	bracketNote    = regexp.MustCompile(`\[[^\]]*\]`)
)

const (
	stopPrefix        = "STOP | "
	stopCleanForm     = "read-only-investigable exhausted (0)"
	noActiveFocus     = "no active focus"
	unrecognizedLimit = 80
)

// classifyNext reads the first line of the --next output. Only the two clean terminal forms read as a zero-open
// exhaustion; anything else after `STOP | ` is qualified or unknown and is named, never scored as a pass.
func classifyNext(next string) nextVerdict {
	if !strings.HasPrefix(next, "STOP ") {
		return nextVerdict{}
	}
	line, _, _ := strings.Cut(next, "\n")
	rest := strings.TrimPrefix(line, stopPrefix)
	if rest == stopCleanForm || outlineCovered.MatchString(rest) {
		return nextVerdict{zeroOpen: true}
	}
	brackets := strings.Join(bracketNote.FindAllString(rest, -1), " ")
	switch {
	case strings.HasPrefix(rest, noActiveFocus):
		return nextVerdict{zeroOpen: true, qualifier: strings.TrimSpace(noActiveFocus + " " + brackets)}
	case brackets != "":
		return nextVerdict{zeroOpen: true, qualifier: brackets}
	}
	if len(rest) > unrecognizedLimit {
		rest = rest[:unrecognizedLimit]
	}
	return nextVerdict{zeroOpen: true, qualifier: "unrecognized STOP form: " + rest}
}
