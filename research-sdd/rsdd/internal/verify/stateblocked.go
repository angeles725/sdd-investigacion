package verify

import (
	"regexp"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/kit"
)

// Ports of lib/blocked-rows.sh (blocked_rows_body, blocked_open_count) and of the blocked-section helpers of
// verify-state.sh (_blocked_names, derive_missing_tried, derive_missing_unblock, derive_missing_unblock_rows,
// derive_stretch_missing). Every awk, grep and sed of the originals is named at its Go counterpart.

// blockedBody is blocked_rows_body: the sections `## Blocked gaps`, `## Non-investigable gaps` and
// `## Blocked /` (in that order) as one text, trailing newlines removed like "$(...)".
func blockedBody(lines []string) string {
	var all []string
	for _, h := range []string{"## Blocked gaps", "## Non-investigable gaps", "## Blocked /"} {
		all = append(all, section(lines, h)...)
	}
	return cmdSubst(joinLines(all))
}

var (
	reBulletNeeds   = regexp.MustCompile(`(?i)^[ \t\n\v\f\r]*-[ \t\n\v\f\r].*needs:`)
	reNeedsEither   = regexp.MustCompile(`(?i)^[ \t\n\v\f\r]*-[ \t\n\v\f\r].*needs:|\*\*needs:\*\*`)
	reBulletStart   = regexp.MustCompile(`^[ \t\n\v\f\r]*-[ \t\n\v\f\r]`)
	reDashedNeeds   = regexp.MustCompile(`(?i)[ \t\n\v\f\r]*[-–—]+[ \t\n\v\f\r]*needs:.*$`)
	rePlainNeeds    = regexp.MustCompile(`(?i)[ \t\n\v\f\r]*needs:.*$`)
	reUnblockBullet = regexp.MustCompile(`^[ \t]*-[ \t]`)
	reBlank         = regexp.MustCompile(`^[ \t\n\v\f\r]*$`)
	reCloseBracket  = regexp.MustCompile(`\[(closed|cerrado)\]`)
	reStrike        = regexp.MustCompile(`^[ \t\n\v\f\r]*-[ \t\n\v\f\r]+(\*\*)?~~`)
	reWordTail      = regexp.MustCompile(`[A-Za-z0-9_-]+[^A-Za-z0-9_-]*$`)
	reDashesOnly    = regexp.MustCompile(`^[-_]+$`)
	reBoldNeeds     = regexp.MustCompile(`\*\*needs:\*\*`)
	reBoldTried     = regexp.MustCompile(`\*\*tried:\*\*`)
	reStretchReal   = regexp.MustCompile(`^[ \t\n\v\f\r]*(-[ \t\n\v\f\r]*)?realistic:`)
	reStretchStret  = regexp.MustCompile(`^[ \t\n\v\f\r]*(-[ \t\n\v\f\r]*)?stretch:`)
)

// bulletName is the shared sed pipeline of _blocked_names and derive_missing_unblock_rows for one body line: the
// `- ` marker removed (sed -n 's/^[[:space:]]*-[[:space:]]*//p'), then the `[ — ]needs: ...` tail
// (case-blind) cut, then the blanks trimmed. ok is false when the line is not a bullet at all.
func bulletName(line string) (string, bool) {
	rest := strings.TrimLeft(line, wsClass)
	if !strings.HasPrefix(rest, "-") {
		return "", false
	}
	return trimName(strings.TrimLeft(rest[1:], wsClass)), true
}

func trimName(s string) string {
	s = reDashedNeeds.ReplaceAllString(s, "")
	s = rePlainNeeds.ReplaceAllString(s, "")
	return strings.Trim(s, wsClass)
}

// blockedNames is _blocked_names: one blocked gap NAME per bullet of the body (empty names dropped).
func blockedNames(body string) []string {
	var out []string
	for _, l := range bodyLines(body) {
		if n, ok := bulletName(l); ok && n != "" {
			out = append(out, n)
		}
	}
	return out
}

// needsNames is the _names pipeline of derive_missing_unblock_rows: only the bullets that carry `needs:`, empty
// names kept.
func needsNames(body string) []string {
	var out []string
	for _, l := range bodyLines(body) {
		if reBulletNeeds.MatchString(l) {
			n, _ := bulletName(l)
			out = append(out, n)
		}
	}
	return out
}

// blockedOpenCount is blocked_open_count: the standard sections' bullets carrying `needs:` (or the bold prose
// form) plus the open entries of `## Child gaps surfaced at close`.
func blockedOpenCount(lines []string) int {
	body := blockedBody(lines)
	d1 := 0
	for _, l := range bodyLines(body) {
		if reNeedsEither.MatchString(l) {
			d1++
		}
	}
	sec := cmdSubst(joinLines(section(lines, "## Child gaps surfaced at close")))
	return d1 + childGapCount(bodyLines(sec))
}

// childGapCount is the awk of blocked_open_count's second counter (CHILD-GAPS-ANCHOR).
func childGapCount(lines []string) int {
	n := 0
	ib, done, cl := false, false, false
	for _, l := range lines {
		switch {
		case reBlank.MatchString(l):
			ib, done, cl = false, false, false
		case reBulletStart.MatchString(l):
			ib, done = true, false
			cl = childClosed(l)
			if !cl && strings.Contains(asciiLower(l), "needs:") {
				n++
				done = true
			}
		default:
			if ib && !done && !cl && strings.Contains(asciiLower(l), "needs:") {
				n++
				done = true
			}
		}
	}
	return n
}

// childClosed is is_closed: a struck entry, a check mark, the whole words CERRADO / CLOSED (not negated), or a
// bracketed [closed] / [cerrado].
func childClosed(s string) bool {
	switch {
	case reStrike.MatchString(s):
		return true
	case strings.Contains(s, "✅"):
		return true
	case hasWord(s, "CERRADO"), hasWord(s, "CLOSED"):
		return true
	}
	return reCloseBracket.MatchString(asciiLower(s))
}

func isWordByte(c byte) bool {
	return c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '_' || c == '-'
}

// hasWord is has_word: w as a whole word (neighbours outside [A-Za-z0-9_-]) that no NOT/NO/NEVER negates.
func hasWord(s, w string) bool {
	off := 0
	for {
		i := strings.Index(s[off:], w)
		if i < 0 {
			return false
		}
		pos := off + i // 0-based start in s
		end := pos + len(w)
		befOK := pos == 0 || !isWordByte(s[pos-1])
		aftOK := end >= len(s) || !isWordByte(s[end])
		if befOK && aftOK && !negated(s[:pos]) {
			return true
		}
		off = end
	}
}

// negated is the NEGATION-WINDOW: NOT/NO/NEVER within the two words before the marker. A negation matches in any
// case only when adjacent to the marker or separated by the fillers YET/LONGER; elsewhere only upper case.
func negated(pre string) bool {
	p := pre
	fill := true
	for k := 0; k < 2; {
		loc := reWordTail.FindStringIndex(p)
		if loc == nil {
			return false
		}
		w := trailingNonWord(p[loc[0]:loc[1]])
		p = p[:loc[0]]
		if reDashesOnly.MatchString(w) {
			continue
		}
		u := asciiUpper(w)
		if u == "NOT" || u == "NO" || u == "NEVER" {
			if fill || w == u {
				return true
			}
		}
		if u != "YET" && u != "LONGER" {
			fill = false
		}
		k++
	}
	return false
}

// trailingNonWord removes the trailing run of characters outside [A-Za-z0-9_-].
func trailingNonWord(w string) string {
	i := len(w)
	for i > 0 && !isWordByte(w[i-1]) {
		i--
	}
	return w[:i]
}

// missingTried is derive_missing_tried: wall entries (bullet lines, or blank-delimited prose paragraphs) that
// carry `needs:` but no `tried:`.
func missingTried(body string) int {
	need, tried := false, false
	miss := 0
	for _, l := range bodyLines(body) {
		switch {
		case reBlank.MatchString(l):
			if need && !tried {
				miss++
			}
			need, tried = false, false
		case reBulletStart.MatchString(l):
			lo := asciiLower(l)
			if strings.Contains(lo, "needs:") && !strings.Contains(lo, "tried:") {
				miss++
			}
			need, tried = false, false
		default:
			if reBoldNeeds.MatchString(l) {
				need = true
			}
			if reBoldTried.MatchString(l) {
				tried = true
			}
		}
	}
	if need && !tried {
		miss++
	}
	return miss
}

// missingUnblock is derive_missing_unblock: (entries with `needs:` and no `unblock:`, entries whose `unblock:`
// precedes their `needs:`).
func missingUnblock(body string) (miss, ord int) {
	var (
		need, unb, open, pend, isb bool
		npos, upos, bi             int
	)
	flush := func() {
		if need && !unb {
			miss++
		} else if need && unb && upos < npos {
			ord++
		}
		need, unb, open, pend = false, false, false, false
		npos, upos = 0, 0
	}
	for nr, l := range bodyLines(body) {
		if reBlank.MatchString(l) {
			if open {
				if isb {
					pend = true
				} else {
					flush()
				}
			}
			continue
		}
		i := len(l) - len(strings.TrimLeft(l, " \t"))
		bul := reUnblockBullet.MatchString(l)
		if open && ((bul && i <= bi) || (pend && i <= bi)) {
			flush()
		}
		pend = false
		if !open {
			open, isb, bi = true, bul, i
		}
		lo := asciiLower(l)
		if k := strings.Index(lo, "needs:"); !need && k >= 0 {
			need = true
			npos = nr*100000 + k + 1
		}
		if k := strings.Index(lo, "unblock:"); !unb && k >= 0 {
			unb = true
			upos = nr*100000 + k + 1
		}
	}
	flush()
	return miss, ord
}

// missingUnblockRows is derive_missing_unblock_rows: open wall rows of the backlog (status leading token
// blocked-on-*, blocked, unavailable, refused, not-extracted, not-buildable) with no `unblock:` plan that no
// `## Blocked gaps` bullet carrying `needs:` already holds (by exact name or shared gap ID).
func (b backlogStream) missingUnblockRows(body string) int {
	names := needsNames(body)
	nameBlock := "\n" + strings.Join(names, "\n") + "\n"
	var ids []string
	for _, n := range names {
		if id, ok := kit.InplaceGapID(n); ok {
			ids = append(ids, id)
		}
	}
	idBlock := "\n" + strings.Join(ids, "\n") + "\n"
	n := 0
	b.each(func(gap, st string) {
		if gap == "" || strings.Contains(gap, "~~") || strings.Contains(st, "~~") || strings.Contains(st, "✅") {
			return
		}
		tok := firstWord(stripBold(st))
		tok, _, _ = strings.Cut(tok, ":")
		tok, _, _ = strings.Cut(tok, ",")
		switch {
		case strings.HasPrefix(tok, "blocked-on-"), tok == "blocked", tok == "unavailable", tok == "refused", tok == "not-extracted", tok == "not-buildable":
		default:
			return
		}
		if strings.Contains(st, "unblock:") || strings.Contains(nameBlock, "\n"+gap+"\n") {
			return
		}
		if id, ok := kit.InplaceGapID(gap); ok && strings.Contains(idBlock, "\n"+id+"\n") {
			return
		}
		n++
	})
	return n
}

// stretchMissing is derive_stretch_missing: "absent" without a `## Stretch goal` section, else the missing
// line names ("realistic:", "stretch:", both space-separated) or "".
func stretchMissing(lines []string) string {
	has := false
	for _, l := range lines {
		if strings.HasPrefix(l, "## Stretch goal") {
			has = true
			break
		}
	}
	if !has {
		return "absent"
	}
	r, s := false, false
	for _, l := range section(lines, "## Stretch goal") {
		lo := strings.ReplaceAll(asciiLower(l), "*", "")
		if reStretchReal.MatchString(lo) {
			r = true
		}
		if reStretchStret.MatchString(lo) {
			s = true
		}
	}
	out := ""
	if !r {
		out = "realistic:"
	}
	if !s {
		if out != "" {
			out += " "
		}
		out += "stretch:"
	}
	return out
}
