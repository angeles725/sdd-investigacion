package lint

// Port of lint-block-packs/child-gap.py: R4, the open-time `coverage-check:` / `measured-by:` grammar of a child-gap
// bullet (METHODOLOGY section 8b). The section model, the clause grammar and the typed findings (ABSENT, MALFORMED, MEASURE)
// are the Python's; its lookarounds are rewritten as code (cgExcludedTitle, cgSentenceEnd, cgStatedNumber, ...).

import (
	"fmt"
	"sort"
	"strings"
	"unicode"
	"unicode/utf8"
)

var (
	cgSectionRE = reCI(`child[- ]gaps?`)
	// EXCLUDED_TITLE_RE `^[\W\d]*(?:no\s+child[- ]gaps?|closed|resolved)\b|(?<!not )(?<!not yet )\b(?:closed|resolved)\W*$`;
	// the second alternative is cgExcludedTitle's code.
	cgExcludedLeadRE = reCI(`^(?:` + nonWord + `|\p{Nd})*(?:no` + ws + `+child[- ]gaps?|closed|resolved)` + rb)
	cgClosedWordRE   = reCI(`closed|resolved`)
	cgSetextRE       = re(`^` + ws + `*(?:=+|-{2,})` + ws + `*$`)
	cgLabelRE        = reCI(`^` + ws + `*(?:[-*+]` + ws + `+)?(?:open` + ws + `+)?child[- ]gaps?(?:` + ws + `+(?:opened|surfaced|named))?` + ws + `*:?` + ws + `*$`)
	cgBulletRE       = re(`^(` + ws + `*)[-*+]` + ws + `+\(?(B\p{Nd}+-G\p{Nd}+)` + rb)
	cgAnyItemRE      = re(`^(` + ws + `*)(?:\p{Nd}+\.|[-*+])` + ws + `+`)
	cgCoverageRE     = reCI("`?coverage-check:`?")
	cgMeasuredRE     = reCI("`?measured-by:`?")
	cgResultSepRE    = re(`->|\x{2192}`)
	cgCodeStartRE    = re("^`([^`]+)`")
	cgPlaceholderRE  = reCI(`^(?:todo|tbd|tba|tbc|xxx|n/?a|none|nil|null|unknown|unresolved|pending|missing|fixme|wip|\?+)` + nonWord + `*$`)
	// A RESULT may legitimately be "none" (the query found no hit: that IS the finding).
	cgResultPlaceholderRE = reCI(`^(?:todo|tbd|tba|tbc|xxx|n/?a|nil|null|unknown|unresolved|pending|missing|fixme|wip|\?+)` + nonWord + `*$`)
	// PROSE_PLACEHOLDER_RE `(?<![\w/])(?:...)(?![\w/])`: a placeholder word anywhere in a prose-only clause.
	cgProsePlaceholderRE = reCI(`(?:^|[^` + wcls + `/])(?:todo|tbd|tba|tbc|xxx|n/a|fixme|wip|unknown|unresolved)(?:$|[^` + wcls + `/])`)
	cgCodeSpanRE         = re("`[^`]*`")
	cgRefBlockRE         = reCI(`^\[Block` + ws + `*\p{Nd}+`)
	cgRefSectionRE       = re(`^\x{a7}` + ws + `*\p{Nd}[\p{Nd}.]*`)
	cgLeadingParenRE     = re(`^` + ws + `*\([^)]*\)`)
	cgVersion3RE         = re(`\p{Nd}+(?:\.\p{Nd}+){2,}`)
	cgDateRE             = re(`\p{Nd}{4}-\p{Nd}{2}(?:-\p{Nd}{2})?`)
	cgBulletPrefixRE     = re(`^` + ws + `*[-*+]` + ws + `+\(?B\p{Nd}+-G\p{Nd}+\)?`)
	cgAlnum2RE           = re(`[A-Za-z0-9]{2,}`)
)

func cgSection(title string) bool       { return cgSectionRE.MatchString(title) }
func cgPlaceholder(s string) bool       { return cgPlaceholderRE.MatchString(s) }
func cgResultPlaceholder(s string) bool { return cgResultPlaceholderRE.MatchString(s) }
func cgProsePlaceholder(s string) bool  { return cgProsePlaceholderRE.MatchString(s) }
func cgLabel(s string) bool             { return cgLabelRE.MatchString(s) }

// hasSuffixFold is the fixed-width lookbehind `(?<!lit)` (compared case-insensitively, rune by rune) as a suffix test.
func hasSuffixFold(s, lit string) bool {
	n := utf8.RuneCountInString(lit)
	r := []rune(s)
	return len(r) >= n && strings.EqualFold(string(r[len(r)-n:]), lit)
}

// cgExcludedTitle is EXCLUDED_TITLE_RE.search(title): a title that starts with "no child gaps" / closed / resolved
// (after optional non-word and digit runes), or that ENDS in closed / resolved ("Child gaps (all closed)") but not in
// "not (yet) closed".
func cgExcludedTitle(title string) bool {
	if cgExcludedLeadRE.MatchString(title) {
		return true
	}
	for _, loc := range cgClosedWordRE.FindAllStringIndex(title, -1) {
		s, e := loc[0], loc[1]
		if wordBefore(title, s) || hasSuffixFold(title[:s], "not ") || hasSuffixFold(title[:s], "not yet ") {
			continue
		}
		rest := true // \W*$
		for _, r := range title[e:] {
			if isPyWord(r) {
				rest = false
				break
			}
		}
		if rest {
			return true
		}
	}
	return false
}

// cgSentenceEnd is SENTENCE_END_RE.search(masked, start, end) for `[.!?](?=\s+[A-Z`\[(0-9]|\s*$)|;`, returning the
// byte index of the match or -1. `end` acts as the end of the string (so `\s*$` holds there and no lookahead sees past
// it), exactly as the pos/endpos arguments of Pattern.search; start > end finds nothing.
func cgSentenceEnd(masked string, start, end int) int {
	if end > len(masked) {
		end = len(masked)
	}
	if start < 0 || start > end {
		return -1
	}
	s := masked[:end]
	for i := start; i < len(s); {
		r, n := utf8.DecodeRuneInString(s[i:])
		switch r {
		case ';':
			return i
		case '.', '!', '?':
			j := skipSpace(s, i+n)
			if j == len(s) { // \s*$
				return i
			}
			if j > i+n && strings.IndexByte("ABCDEFGHIJKLMNOPQRSTUVWXYZ`[(0123456789", s[j]) >= 0 {
				return i
			}
		}
		i += n
	}
	return -1
}

func cgMaskCode(text string) string {
	return cgCodeSpanRE.ReplaceAllStringFunc(text, func(m string) string { return strings.Repeat("x", len(m)) })
}

// ---- stated numbers ---------------------------------------------------------------------------------------------

// cgRefMask is REF_RE.sub(" ", prose) for `\[Block\s*\d+|\bB\d+(?:-G\d+)?\b|\xa7\s*\d[\d.]*` (ignore case), scanned left
// to right like re.sub, the alternatives tried in order at each position.
func cgRefMask(prose string) string {
	var b strings.Builder
	for p := 0; p < len(prose); {
		end := -1
		switch c := prose[p]; {
		case c == '[':
			if loc := cgRefBlockRE.FindStringIndex(prose[p:]); loc != nil {
				end = p + loc[1]
			}
		case c == 'B' || c == 'b':
			end = cgRefB(prose, p)
		case strings.HasPrefix(prose[p:], "\u00a7"):
			if loc := cgRefSectionRE.FindStringIndex(prose[p:]); loc != nil {
				end = p + loc[1]
			}
		}
		if end > p {
			b.WriteByte(' ')
			p = end
			continue
		}
		_, n := utf8.DecodeRuneInString(prose[p:])
		b.WriteString(prose[p : p+n])
		p += n
	}
	return b.String()
}

func isNd(r rune) bool { return unicode.Is(unicode.Nd, r) }

// ndRun returns the end of the run of decimal digits that starts at i (i itself when there is none).
func ndRun(s string, i int) int {
	for i < len(s) {
		r, n := utf8.DecodeRuneInString(s[i:])
		if !isNd(r) {
			break
		}
		i += n
	}
	return i
}

// cgRefB is `\bB\d+(?:-G\d+)?\b` at p: the end of the match or -1. The digit runs are maximal (a shorter run is
// followed by a digit, which is never a boundary); the `-G<digits>` group is tried first and dropped when the
// boundary after it fails.
func cgRefB(s string, p int) int {
	if wordBefore(s, p) {
		return -1
	}
	d := ndRun(s, p+1)
	if d == p+1 {
		return -1
	}
	if d+1 < len(s) && s[d] == '-' && (s[d+1] == 'G' || s[d+1] == 'g') {
		if g := ndRun(s, d+2); g > d+2 && !wordAfter(s, g) {
			return g
		}
	}
	if !wordAfter(s, d) {
		return d
	}
	return -1
}

// numberTail tries `(%|[xXkKmM]|[kKmMgG][bB])?(?!\w)` at i, in the regex's preference order: the unit alternatives
// first, then no unit. It returns the end of the match and whether a unit was taken.
func numberTail(s string, i int) (end int, unit, ok bool) {
	if i < len(s) {
		c := s[i]
		if c == '%' && !wordAfter(s, i+1) {
			return i + 1, true, true
		}
		if strings.IndexByte("xXkKmM", c) >= 0 && !wordAfter(s, i+1) {
			return i + 1, true, true
		}
		if strings.IndexByte("kKmMgG", c) >= 0 && i+1 < len(s) && (s[i+1] == 'b' || s[i+1] == 'B') && !wordAfter(s, i+2) {
			return i + 2, true, true
		}
	}
	if !wordAfter(s, i) {
		return i, false, true
	}
	return 0, false, false
}

// numberAt is NUMBER_RE `(?<![\w.:])(\d[\d,]*)(\.\d+)?(%|[xXkKmM]|[kKmMgG][bB])?(?!\w)` at p (the caller has checked
// the lookbehind and that p holds a digit): the end of the match, and whether groups 2 (the decimals) and 3 (the unit)
// took part. Backtracking order: the longest digits-and-commas run first, with the decimals before without; then
// shorter runs, which can only end before a comma (the next rune must be non-word and the decimals / unit need a `.`
// or a letter).
func numberAt(s string, p int) (end int, g2, g3, ok bool) {
	var cuts []int // ends of each prefix of the run, longest last
	i := p
	for i < len(s) {
		r, n := utf8.DecodeRuneInString(s[i:])
		if !isNd(r) && r != ',' {
			break
		}
		i += n
		cuts = append(cuts, i)
	}
	aMax := cuts[len(cuts)-1]
	if aMax < len(s) && s[aMax] == '.' {
		if d := ndRun(s, aMax+1); d > aMax+1 {
			if e, unit, ok := numberTail(s, d); ok {
				return e, true, unit, true
			}
		}
	}
	if e, unit, ok := numberTail(s, aMax); ok {
		return e, false, unit, true
	}
	for k := len(cuts) - 2; k >= 0; k-- {
		if s[cuts[k]] == ',' {
			return cuts[k], false, false, true
		}
	}
	return 0, false, false, false
}

// cgStatedNumber is stated_number(prose): the first standalone number, other than a bare two-part dotted one (a
// version). Code spans, references, dates and three-part versions are blanked first.
func cgStatedNumber(prose string) (string, bool) {
	prose = cgCodeSpanRE.ReplaceAllString(prose, " ")
	prose = cgRefMask(prose)
	prose = cgDateRE.ReplaceAllString(prose, " ")
	prose = cgVersion3RE.ReplaceAllString(prose, " ")
	for p := 0; p < len(prose); {
		r, n := utf8.DecodeRuneInString(prose[p:])
		if isNd(r) {
			pr, pn := utf8.DecodeLastRuneInString(prose[:p]) // (?<![\w.:])
			if !(pn > 0 && (isPyWord(pr) || pr == '.' || pr == ':')) {
				if end, g2, g3, ok := numberAt(prose, p); ok {
					if g2 && !g3 { // a bare two-part dotted number ("4.15") reads as a version
						p = end
						continue
					}
					return prose[p:end], true
				}
			}
		}
		p += n
	}
	return "", false
}

// ---- clause grammar ---------------------------------------------------------------------------------------------

// cgCoverageProblem is coverage_problem(body): "" when the clause body is a query plus a result, else what is wrong.
func cgCoverageProblem(body string) string {
	plain := strings.Trim(body, "` ")
	if plain == "" || cgPlaceholderRE.MatchString(plain) {
		return "is empty or a placeholder"
	}
	var query, result string
	if loc := cgResultSepRE.FindStringIndex(body); loc != nil {
		query, result = body[:loc[0]], body[loc[1]:]
	} else if m := cgCodeStartRE.FindStringSubmatch(body); m != nil {
		query, result = m[1], body[len(m[0]):]
	} else if cgProsePlaceholderRE.MatchString(plain) {
		return "is a placeholder padded with words"
	} else if len(pySplitFields(plain)) >= 4 {
		return ""
	} else {
		return "names no query and no result (expected `query -> result`)"
	}
	query, result = strings.Trim(query, "` "), strings.Trim(result, " `.;")
	if !cgAlnum2RE.MatchString(query) {
		return "names no query before the result"
	}
	if !cgAlnum2RE.MatchString(result) || cgResultPlaceholderRE.MatchString(result) {
		return "states no result for the query"
	}
	return ""
}

type cgFinding struct{ kind, detail string }

// pySlice is text[a:b] for byte offsets: empty when a >= b (Python never errors on a reversed slice).
func pySlice(s string, a, b int) string {
	if a < 0 {
		a = 0
	}
	if b > len(s) {
		b = len(s)
	}
	if a >= b {
		return ""
	}
	return s[a:b]
}

// cgJudgeBullet is judge_bullet(text): the findings for one bullet's joined text; empty when it conforms.
func cgJudgeBullet(text string) []cgFinding {
	text = strings.ReplaceAll(text, "**", "")
	type tok struct {
		s, e   int
		isCov  bool
		first  bool
		bodyTo int
	}
	var toks []tok
	cov := cgCoverageRE.FindAllStringIndex(text, -1)
	mea := cgMeasuredRE.FindAllStringIndex(text, -1)
	for i, l := range cov {
		toks = append(toks, tok{s: l[0], e: l[1], isCov: true, first: i == 0})
	}
	for i, l := range mea {
		toks = append(toks, tok{s: l[0], e: l[1], first: i == 0})
	}
	sort.SliceStable(toks, func(a, b int) bool { return toks[a].s < toks[b].s })
	// A clause body ends at the next clause token or at the end of its sentence (code-span interiors are inert).
	masked := cgMaskCode(text)
	for i := range toks {
		end := len(text)
		if i+1 < len(toks) {
			end = toks[i+1].s
		}
		if se := cgSentenceEnd(masked, toks[i].e, end); se >= 0 {
			end = se
		}
		toks[i].bodyTo = end
	}
	var out []cgFinding
	if len(cov) == 0 {
		out = append(out, cgFinding{"ABSENT", "no `coverage-check:` clause"})
	} else {
		for _, t := range toks {
			if t.isCov && t.first {
				if p := cgCoverageProblem(strings.Trim(pySlice(text, t.e, t.bodyTo), " \t.;,")); p != "" {
					out = append(out, cgFinding{"MALFORMED", "`coverage-check:` " + p})
				}
			}
		}
	}
	// Prose = the bullet without its clauses (token through sentence end).
	var pieces []string
	pos := 0
	for _, t := range toks {
		pieces = append(pieces, pySlice(text, pos, t.s))
		pos = t.bodyTo
	}
	pieces = append(pieces, pySlice(text, pos, len(text)))
	prose := strings.Join(pieces, " ")
	prose = cgBulletPrefixRE.ReplaceAllString(prose, "")
	prose = cgLeadingParenRE.ReplaceAllString(prose, "")
	if number, ok := cgStatedNumber(prose); ok {
		if len(mea) == 0 {
			out = append(out, cgFinding{"MEASURE", "states " + number + " but has no `measured-by:` clause"})
		} else {
			for _, t := range toks {
				if !t.isCov && t.first {
					body := strings.Trim(pySlice(text, t.e, t.bodyTo), " \t.;,`")
					if !cgAlnum2RE.MatchString(body) || cgPlaceholderRE.MatchString(body) {
						out = append(out, cgFinding{"MEASURE", "states " + number + " but `measured-by:` is empty or a placeholder"})
					}
				}
			}
		}
	}
	return out
}

// ---- the rule ---------------------------------------------------------------------------------------------------

// cgBullet is BULLET_RE.match(line): the indent (in runes) and the id of a `- B<n>-G<m>` gap bullet.
func cgBullet(line string) (indent int, id string, ok bool) {
	m := cgBulletRE.FindStringSubmatch(line)
	if m == nil {
		return 0, "", false
	}
	return utf8.RuneCountInString(m[1]), m[2], true
}

type cgScope int

const (
	scopeNone cgScope = iota
	scopeHeading
	scopeLabel
)

func childGapRule(d *doc) []finding {
	d.bump("r4_triggers", 0) // register: the SUMMARY prints r4-triggers=0 when nothing was inspected
	d.bump("r4_unscoped", 0) // ... and r4-unscoped=0 when no gap bullet sat outside a judged section
	var out []finding
	scope, scopeLevel := scopeNone, 0
	excluded := -1 // level of an excluded sub-heading (closed / resolved) inside a judged section; -1 = none
	n := len(d.lines)
	for i := 1; i <= n; {
		raw := d.lines[i-1]
		if d.fenced[i] {
			i++
			continue
		}
		if hm := headingRE.FindStringSubmatch(raw); hm != nil {
			level, title := len(hm[1]), hm[2]
			if excluded >= 0 && level <= excluded {
				excluded = -1
			}
			if scope != scopeNone && (scope == scopeLabel || level <= scopeLevel) {
				scope = scopeNone
			}
			if scope == scopeNone && excluded < 0 && cgSection(title) && !cgExcludedTitle(title) {
				scope, scopeLevel = scopeHeading, level
			} else if scope != scopeNone && cgExcludedTitle(title) && excluded < 0 {
				excluded = level
			}
			i++
			continue
		}
		underlined := i < n && !d.fenced[i+1] && pyStrip(raw) != "" && !cgAnyItemRE.MatchString(raw) && cgSetextRE.MatchString(d.lines[i])
		if underlined && scope == scopeLabel {
			scope = scopeNone // a setext heading ends a label-started section
			i += 2
			continue
		}
		if scope == scopeNone && cgLabelRE.MatchString(raw) {
			if underlined {
				scope, scopeLevel = scopeHeading, 2
				if strings.HasPrefix(strings.TrimLeftFunc(d.lines[i], isPySpace), "=") {
					scopeLevel = 1
				}
				i += 2
			} else {
				scope = scopeLabel
				i++
			}
			continue
		}
		indent, gapID, isBullet := cgBullet(raw)
		if !isBullet {
			i++
			continue
		}
		last := i
		for j := i + 1; j <= n; j++ {
			nxt := d.lines[j-1]
			if d.fenced[j] || pyStrip(nxt) == "" || headingRE.MatchString(nxt) {
				break
			}
			if im := cgAnyItemRE.FindStringSubmatch(nxt); im != nil && utf8.RuneCountInString(im[1]) <= indent {
				break
			}
			last = j
		}
		if scope == scopeNone || excluded >= 0 {
			d.bump("r4_unscoped", 1)
		} else {
			parts := make([]string, 0, last-i+1)
			for k := i; k <= last; k++ {
				parts = append(parts, pyStrip(d.lines[k-1]))
			}
			d.bump("r4_triggers", 1)
			waived := false
			for _, w := range d.waivers {
				if w.rule == "R4" && i <= w.line && w.line <= last {
					waived = true
				}
			}
			if !waived {
				for _, f := range cgJudgeBullet(strings.Join(parts, " ")) {
					out = append(out, finding{i, "R4", fmt.Sprintf("child gap %s: %s - %s", gapID, f.kind, f.detail)})
				}
			}
		}
		i = last + 1
	}
	return out
}

func childGapRules() []packRule { return []packRule{{"R4", childGapRule}} }
