package show

import (
	"fmt"
	"os"
	"strings"
)

// Port of blocked_open_count (lib/blocked-rows.sh, kit #923 and #913): the derived blocked_open of one state
// file. It counts the needs:-carrying bullets of the standard blocked sections (plus the bold prose form) and the
// open multi-line entries of `## Child gaps surfaced at close`.

const childGapsHeading = "## Child gaps surfaced at close"

// blockedOpen is `blocked_open_count "$state"`: the count and the script's rc. An unreadable file is rc 2 with
// the typed line on stderr (absent-input is never a silent 0). The bash rc 3 (an awk or grep that could not run)
// has no counterpart here: nothing in this port can fail to run.
func (c *ctx) blockedOpen() (n, rc int) {
	b, err := os.ReadFile(c.abs(c.state))
	if err != nil {
		path := c.state
		if path == "" {
			path = "<empty path>"
		}
		fmt.Fprintf(c.s.Err, "blocked-rows: state file absent or unreadable: %s\n", path)
		return 0, 2
	}
	text := string(b)
	return blockedOpenCount(text), 0
}

// blockedOpenCount is the count of the two derivations added together.
func blockedOpenCount(text string) int {
	n := 0
	for _, line := range splitLines(blockedBody(text)) {
		if isNeedsBullet(line) || strings.Contains(lowerASCII(line), "**needs:**") {
			n++
		}
	}
	return n + childGapCount(splitLines(sectionBody(text, childGapsHeading)))
}

// isNeedsBullet is `grep -iE '^[[:space:]]*-[[:space:]].*needs:'`: a bullet (a dash followed by a blank) with
// needs: anywhere after that blank.
func isNeedsBullet(line string) bool {
	rest, ok := strings.CutPrefix(strings.TrimLeft(line, cSpace), "-")
	if !ok || rest == "" || !strings.Contains(cSpace, rest[:1]) {
		return false
	}
	return indexNeeds(rest[1:]) >= 0
}

// childGapCount is the awk over the child-gaps section: an entry counts once when `needs:` is on its bullet line or
// on a continuation line before the next blank line or bullet, unless its bullet line carries a closed marker.
func childGapCount(lines []string) int {
	n, inBullet, done, closed := 0, false, false, false
	for _, line := range lines {
		hasNeeds := strings.Contains(lowerASCII(line), "needs:")
		switch {
		case strings.TrimLeft(line, cSpace) == "":
			inBullet, done, closed = false, false, false
		case isBulletLine(line):
			inBullet, done, closed = true, false, childClosed(line)
			if !closed && hasNeeds {
				n++
				done = true
			}
		case inBullet && !done && !closed && hasNeeds:
			n++
			done = true
		}
	}
	return n
}

// isBulletLine is `/^[[:space:]]*-[[:space:]]/`.
func isBulletLine(line string) bool {
	rest, ok := strings.CutPrefix(strings.TrimLeft(line, cSpace), "-")
	return ok && rest != "" && strings.Contains(cSpace, rest[:1])
}

// childClosed is is_closed (CHILD-CLOSED-MARKER, #913): a struck-through entry (the strike opens the bullet content,
// after an optional bold), a tick, the uppercase whole words CERRADO / CLOSED not negated just before, or a
// bracketed [closed] / [cerrado] in any case.
func childClosed(line string) bool {
	if rest, ok := strings.CutPrefix(strings.TrimLeft(line, cSpace), "-"); ok {
		if content := strings.TrimLeft(rest, cSpace); len(content) < len(rest) &&
			(strings.HasPrefix(content, "~~") || strings.HasPrefix(content, "**~~")) {
			return true
		}
	}
	if strings.Contains(line, "✅") || hasWord(line, "CERRADO") || hasWord(line, "CLOSED") {
		return true
	}
	low := lowerASCII(line)
	return strings.Contains(low, "[closed]") || strings.Contains(low, "[cerrado]")
}

// hasWord is has_word: a whole-word occurrence of w (no [A-Za-z0-9_-] byte on either side) that is not negated by
// the words before it. A rejected occurrence does not stop the scan: the next one after it is tried.
func hasWord(s, w string) bool {
	for off := 0; ; {
		i := strings.Index(s[off:], w)
		if i < 0 {
			return false
		}
		pos := off + i
		end := pos + len(w)
		if (pos == 0 || !isWordByte(s[pos-1])) && (end == len(s) || !isWordByte(s[end])) && !negated(s[:pos]) {
			return true
		}
		off = end
	}
}

// negated is the NEGATION-WINDOW: NOT / NO / NEVER among the two words before the marker. A word is a run of
// [A-Za-z0-9_-]; a run of only dashes and underscores is punctuation and uses no slot. The negation matches in any
// case only while every word between it and the marker is a filler (YET / LONGER); further back, only upper case.
func negated(pre string) bool {
	fill := true
	for k := 0; k < 2; {
		end := len(pre)
		for end > 0 && !isWordByte(pre[end-1]) {
			end--
		}
		start := end
		for start > 0 && isWordByte(pre[start-1]) {
			start--
		}
		if start == end {
			return false
		}
		w := pre[start:end]
		pre = pre[:start]
		if strings.Trim(w, "-_") == "" {
			continue
		}
		switch u := strings.ToUpper(w); u {
		case "NOT", "NO", "NEVER":
			if fill || w == u {
				return true
			}
			fill = false
		case "YET", "LONGER":
		default:
			fill = false
		}
		k++
	}
	return false
}
