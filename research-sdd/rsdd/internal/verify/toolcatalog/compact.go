package toolcatalog

import (
	"fmt"
	"regexp"
	"strings"
)

// reToolWarn is the not-cataloged WARN line and the name it quotes (up to the first closing quote).
var reToolWarn = regexp.MustCompile(`^WARN  installed-but-not-cataloged: '([^']*)'`)

// compactWarns is the COMPACT form of the WARN lines (kit issue #1816, SessionStart output budget): the per-tool
// not-cataloged lines share one long remediation sentence, so they collapse into ONE line naming every tool (the
// count is the number of such lines). Any other WARN line passes through cut to compactWarnBytes bytes, never dropped.
func compactWarns(warns string) string {
	var names, other []string
	count := 0
	for _, l := range strings.Split(warns, "\n") {
		if !strings.HasPrefix(l, notCatalogedWarn) {
			other = append(other, cutBytes(l, compactWarnBytes))
			continue
		}
		count++
		if m := reToolWarn.FindStringSubmatch(l); m != nil {
			names = append(names, m[1])
		}
	}
	// a blank line the pipeline would have kept, then dropped with the trailing newlines, is not a line here either
	kept := strings.TrimRight(strings.Join(other, "\n"), "\n")
	if count == 0 {
		return kept
	}
	collapsed := fmt.Sprintf(hookCollapsedFmt, count, strings.ReplaceAll(strings.Join(names, ","), ",", ", "))
	if kept == "" {
		return collapsed
	}
	return kept + "\n" + collapsed
}
