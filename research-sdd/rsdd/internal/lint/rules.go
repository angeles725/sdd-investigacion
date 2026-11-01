package lint

import (
	"strings"
	"unicode/utf8"
)

// ---- R3: ephemeral evidence ---------------------------------------------------------------------------------

// Hyphen variants seen in real blocks: U+2010..U+2013, plain `-`, a space, or nothing.
const hy = "[-\u2010\u2011\u2012\u2013 ]"

var (
	r3MarkerRE    = re(`(?i)\[CERT` + hy + `?(?:hw|live)\]`)
	r3SectionRE   = re(`(?i)self` + hy + `?verif`)
	r3EphemeralRE = re(`(?i)/tmp/|/var/tmp/|/private/tmp/|/dev/shm/|\$\{?TMPDIR\}?|scratchpad`)
	r3TokenRE     = re("[^" + wsClass + "`\"'()]+")
	r3ExtRE       = re(`\.[A-Za-z0-9]{0,5}[A-Za-z][A-Za-z0-9]{0,5}(?::\p{Nd}+(?:-\p{Nd}+)?)?$`)
	// Inline evidence group, anchored where the marker ends (`^` on the tail replaces Python's match(text, pos)).
	r3InlineGroupRE = re("^`?" + ws + `*[:\x{2014}\x{2013}-]?` + ws + `*\(((?:[^()|]|\([^()|]*\)){0,400})\)`)
	// R3_BLOCKFILE ends in `\.md\b`: the match consumes the one non-word rune after `md` (or the end), which is
	// equivalent for a pure existence test.
	r3BlockfileRE = re(`[` + wordClass + `.+-]+-(?:block|bloque)\p{Nd}+(?:-[` + wordClass + `-]+)?\.md(?:$|[^` + wordClass + `])`)
)

func isDurableToken(tok string) bool {
	tok = strings.TrimRight(tok, ".,;:")
	if r3EphemeralRE.MatchString(tok) {
		return false
	}
	if r3BlockfileRE.MatchString(tok) {
		return true
	}
	var segs []string
	for _, x := range strings.Split(tok, "/") {
		if x != "" {
			segs = append(segs, x)
		}
	}
	if strings.HasSuffix(tok, "/") && len(segs) > 0 {
		return true
	}
	if len(segs) < 2 {
		return false
	}
	for _, x := range segs {
		if r3ExtRE.MatchString(x) {
			return true
		}
	}
	return false
}

func anyDurable(evidence string) bool {
	for _, t := range r3TokenRE.FindAllString(evidence, -1) {
		if isDurableToken(t) {
			return true
		}
	}
	return false
}

func ruleR3(d *doc) []finding {
	sv, nsec := linesInSections(d.secs, r3SectionRE)
	d.cov.selfverifySections = nsec
	var out []finding
	for _, u := range d.units {
		if (u.kind != "row" && u.kind != "item") || !sv[u.line] {
			continue
		}
		var evidence string
		if u.kind == "row" {
			cells := splitRowCells(u.text)
			idx := -1
			for k, c := range cells {
				if r3MarkerRE.MatchString(c) {
					idx = k
					break
				}
			}
			if idx < 0 {
				continue
			}
			evidence = strings.Join(cells[idx+1:], " ")
		} else {
			loc := r3MarkerRE.FindStringIndex(u.text)
			if loc == nil {
				continue
			}
			evidence = u.text[loc[1]:]
		}
		d.cov.certHwLive++
		if !r3EphemeralRE.MatchString(evidence) || anyDurable(evidence) || d.waived("R3", u) {
			continue
		}
		out = append(out, finding{u.line, "R3", "[CERT-hw]/[CERT-live] evidence cites only an ephemeral path: " + pyExcerpt(evidence, 100)})
	}
	for _, u := range d.units {
		if (u.kind != "row" && u.kind != "item" && u.kind != "para") || sv[u.line] {
			continue
		}
		for _, loc := range r3MarkerRE.FindAllStringIndex(u.text, -1) {
			gm := r3InlineGroupRE.FindStringSubmatch(u.text[loc[1]:])
			if gm == nil {
				continue
			}
			d.cov.certInline++
			evidence := gm[1]
			if !r3EphemeralRE.MatchString(evidence) || anyDurable(evidence) || d.waived("R3", u) {
				continue
			}
			out = append(out, finding{u.line, "R3", "inline [CERT-hw]/[CERT-live] evidence cites only an ephemeral path: " + pyExcerpt(evidence, 100)})
			break
		}
	}
	return out
}

// ---- R6: cross-block comparison -----------------------------------------------------------------------------

var (
	r6OpenRE    = re(`(?i)\[Block` + ws + `*\p{Nd}+\]`)
	r6VerdictRE = re(`^(?i:(?:(?:does|do|did)` + ws + `+not|doesn't|didn't|never)` + ws + `+(mention|show|contain|include|cite))`)
	r6RawPathRE = re(`evidence/|[` + wordClass + `./-]*/[` + wordClass + `.-]+\.[` + wordClass + `]{1,6}`)
)

var r6Suffixes = []string{"s", "ed", "d", ""}

// r6Filler is one step of `(?:[^.;—–\n]|\.(?=\S))`: how many bytes the filler rune at text[at:] consumes, or 0
// when it cannot be a filler. The lookahead `(?=\S)` becomes an explicit look at the next rune.
func r6Filler(text string, at int) int {
	r, n := utf8.DecodeRuneInString(text[at:])
	switch r {
	case ';', '\u2014', '\u2013', '\n':
		return 0
	case '.':
		nr, nn := utf8.DecodeRuneInString(text[at+n:])
		if nn == 0 || isPySpace(nr) {
			return 0
		}
	}
	return n
}

// r6Verdict tries `\b<verdict>(?:s|ed|d)?\b` at text[at:], returning the end of the match or -1. The leading `\b`
// holds when the rune before `at` is not a word rune (the verdict starts with a letter); the trailing one is
// checked per suffix option, in the regex's preference order.
func r6Verdict(text string, at int) int {
	if pr, n := utf8.DecodeLastRuneInString(text[:at]); n > 0 && isPyWord(pr) {
		return -1
	}
	m := r6VerdictRE.FindStringSubmatchIndex(text[at:])
	if m == nil {
		return -1
	}
	e := at + m[3]
	for _, suf := range r6Suffixes {
		end := e + len(suf)
		if len(suf) > 0 && !(end <= len(text) && strings.EqualFold(text[e:end], suf)) {
			continue
		}
		if nr, nn := utf8.DecodeRuneInString(text[end:]); nn == 0 || !isPyWord(nr) {
			return end
		}
	}
	return -1
}

// r6Claim is R6_CLAIM_RE.search(text).group(0): `[Block N]`, then at most 80 filler runes (lazy), then a verdict.
func r6Claim(text string) (string, bool) {
	for _, loc := range r6OpenRE.FindAllStringIndex(text, -1) {
		at := loc[1]
		for k := 0; ; k++ {
			if end := r6Verdict(text, at); end >= 0 {
				return text[loc[0]:end], true
			}
			if k == 80 || at >= len(text) {
				break
			}
			n := r6Filler(text, at)
			if n == 0 {
				break
			}
			at += n
		}
	}
	return "", false
}

func ruleR6(d *doc) []finding {
	var out []finding
	for _, u := range d.units {
		if u.kind != "para" && u.kind != "item" && u.kind != "row" {
			continue
		}
		hit, ok := r6Claim(u.text)
		if !ok {
			continue
		}
		d.cov.r6Triggers++
		if r6RawPathRE.MatchString(u.text) || d.waived("R6", u) {
			continue
		}
		out = append(out, finding{u.line, "R6", "comparison against another block without citing its raw artifact: " + pyExcerpt(hit, 100)})
	}
	return out
}
