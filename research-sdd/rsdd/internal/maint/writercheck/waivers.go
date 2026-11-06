package writercheck

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

// waiverRel is the waiver list of the checked tree.
const waiverRel = "research-sdd/toolbelt/tests/writer-check-waivers.txt"

// waivers is the parsed list: suite -> reason (the first line naming a suite wins), plus a `bad-waiver` finding for
// each line with no reason.
type waivers struct {
	reasons  map[string]string
	findings []finding
}

// loadWaivers reads the list from the checked tree: the working file, or the head ref's blob. An absent list waives
// nothing and is not a degraded state.
func (c *ctx) loadWaivers(r rangeSpec) waivers {
	text := ""
	if r.worktree {
		if b, err := os.ReadFile(filepath.Join(c.repo, waiverRel)); err == nil {
			text = string(b)
		}
	} else if res := c.git("show", r.head+":"+waiverRel); res.OK() {
		text = res.Out
	}
	return parseWaivers(text)
}

const blanks = " \t\n\v\f\r"

// reWaiverLine splits a waiver line at its first blank run: the suite, then the reason (leading blanks dropped).
var reWaiverLine = regexp.MustCompile(`(?s)^([^ \t\n\v\f\r]*)[ \t\n\v\f\r]*(.*)$`)

// parseWaivers reads `<repo-relative suite> <reason>` per line. A blank line and a `#` comment (indented or not) are
// skipped; leading blanks are ignored; a line whose reason is empty is a bad-waiver finding, numbered from 1.
func parseWaivers(text string) waivers {
	w := waivers{reasons: map[string]string{}}
	lines := strings.Split(strings.TrimSuffix(text, "\n"), "\n")
	for i, raw := range lines {
		l := strings.TrimLeft(raw, blanks)
		if l == "" || l[0] == '#' {
			continue
		}
		m := reWaiverLine.FindStringSubmatch(l)
		suite, reason := m[1], m[2]
		if reason == "" {
			w.findings = append(w.findings, finding{"bad-waiver", fmt.Sprintf("%s:%d", filepath.Base(waiverRel), i+1), "no reason for " + suite})
			continue
		}
		if _, dup := w.reasons[suite]; !dup {
			w.reasons[suite] = reason
		}
	}
	return w
}
